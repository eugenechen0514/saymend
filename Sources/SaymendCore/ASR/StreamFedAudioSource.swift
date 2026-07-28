import AVFoundation
import CoreML
import WhisperKit

public enum StreamFedAudioSourceError: Error, Equatable {
    case converterUnavailable
    case conversionFailed
}

/// 把本專案的音訊管線接上 WhisperKit 串流轉錄器所需的音訊來源介面。
///
/// **為什麼要轉接而不讓套件自己抓麥克風**：套件的串流轉錄器預期呼叫 `startRecordingLive`
/// 自行開啟錄音，但本專案的 `ASREngine` 契約是「由呼叫端餵音訊進來」，而同一條音訊流
/// 還同時驅動 HUD 音量指示、並為其他引擎共用。兩者搶同一支麥克風會壞事，故錄音生命週期
/// 方法一律無操作，資料由 `append(_:)` 灌入。
///
/// **為什麼不清理樣本**：`purgeAudioSamples` 在整個套件裡沒有任何呼叫者，而串流轉錄器
/// 假設樣本陣列只增不減——它以絕對索引算「這一輪新增多少」（`目前長度 - 上次長度`），
/// 並以從串流起點算起的絕對秒數決定解碼起點。在它背後清理會讓兩個記帳同時失效。
/// 因此本型別的清理方法是**刻意的無操作**，改以 `maxDuration` 當失控 session 的安全網。
///
/// **能量計算逐條照抄套件的 `AudioProcessor.processBuffer`**（見 `appendEnergy`）：
/// 對「新到的這一塊」而非整段歷史計算、參考值取最近 N 格的最小平均能量（滾動噪音基準）。
/// 對整段歷史算會讓數值隨 session 拉長收斂成常數，VAD 從此無法區分講話與停頓；
/// 用固定參考值則丟掉套件對環境噪音的自適應。兩種偏差在單次呼叫的測試下都看不出來。
///
/// **唯一刻意的偏離：回看格數 N 可調**（issue #15）。套件把它寫死成 20，而它的
/// `relativeEnergyWindow` 只用來對除錯日誌取模節流、對辨識毫無作用。我們把這個名字
/// 接到真正有意義的地方：N 預設 20＝與套件逐位元一致，調過才偏離。
/// 窗口小＝噪音基準跟著環境快速調整，窗口大＝基準穩定不被短暫安靜帶偏。
///
/// 執行緒安全：寫入端是音訊管線的 pump、讀取端是串流轉錄器的隔離域。**所有**可變狀態
/// （含轉換器與其來源格式）都在同一把鎖內，鎖的持有期間不含任何 await。
public final class StreamFedAudioSource: AudioProcessing, @unchecked Sendable {
    /// 串流轉錄器一律以 16kHz 單聲道解讀樣本
    public static let sampleRate: Double = 16_000
    /// 一格能量對應的音訊長度。套件的 `isVoiceDetected` 以 `nextBufferInSeconds / 0.1`
    /// 換算「要看幾格」，故一格必須恰好是 100ms，否則格數與時間的對應會系統性偏掉。
    /// （本專案的 tap 是 4096 frames ≒ 85ms，與此不同，因此必須自行重新分桶。）
    static let energyBufferLength = Int(sampleRate * 0.1)

    private let lock = NSLock()
    private var samples = ContiguousArray<Float>()
    /// 比照套件的 `audioEnergy`：一格一個 100ms 音訊桶。rel 供 VAD 判斷、avg 供滾動噪音基準。
    /// **不裁剪**——套件的 `relativeEnergy` 是 `audioEnergy.map { $0.rel }`，從不裁剪；
    /// 而 `isVoiceDetected` 會依「距上次辨識多久」取 suffix，裁短了它就讀到不足的窗口。
    private var audioEnergy: [(rel: Float, avg: Float)] = []
    /// 不足一格（100ms）的殘量，留到下次 append 湊滿
    private var pendingEnergySamples: [Float] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var sourceFormat: AVAudioFormat?
    private var energyWindow = 20

    /// 安全網上限（秒）。超過只回報、不截斷——截斷會破壞「只增不減」而毀掉轉錄器的記帳。
    /// 由呼叫端（引擎）檢查 `isOverCapacity` 並結束 session。
    private let maxDuration: TimeInterval

    /// 回看格數由 init 傳入而非事後指派：餵音訊的 Task 一建好就開始 `append`，
    /// 而串流轉錄器要等模型載完（large 首次可達數分鐘）才碰得到這個物件——
    /// 在那裡才設，整段開頭的能量都會用到舊值。
    public init(maxDuration: TimeInterval = 30 * 60, relativeEnergyWindow: Int = 20) {
        self.maxDuration = maxDuration
        self.energyWindow = relativeEnergyWindow
    }

    // MARK: - 本專案的入口

    /// 灌入一段麥克風音訊。逐 chunk 轉成 16kHz 單聲道 Float 後累積，
    /// 避免同時持有原始格式的全量資料造成記憶體尖峰（比照 WAVAccumulator）。
    public func append(_ chunk: AudioChunk) throws {
        let src = chunk.buffer
        guard src.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let converted = try convertLocked(src)
        guard !converted.isEmpty else { return }
        samples.append(contentsOf: converted)
        pendingEnergySamples.append(contentsOf: converted)
        while pendingEnergySamples.count >= Self.energyBufferLength {
            let bucket = Array(pendingEnergySamples.prefix(Self.energyBufferLength))
            pendingEnergySamples.removeFirst(Self.energyBufferLength)
            appendEnergyLocked(for: bucket)
        }
    }

    /// 音訊串流結束：排出轉換器內部殘留的樣本，並把不足一格的殘量結算成最後一格能量。
    /// 不呼叫的話，每次聽寫的尾端會有一小段音訊永遠留在轉換器裡進不了 `audioSamples`。
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        if let drained = try? drainConverterLocked(), !drained.isEmpty {
            samples.append(contentsOf: drained)
            pendingEnergySamples.append(contentsOf: drained)
        }
        while pendingEnergySamples.count >= Self.energyBufferLength {
            let bucket = Array(pendingEnergySamples.prefix(Self.energyBufferLength))
            pendingEnergySamples.removeFirst(Self.energyBufferLength)
            appendEnergyLocked(for: bucket)
        }
        // 最後不足 100ms 的殘量也結算一格（時間對應略短，但總比整段遺漏好）
        if !pendingEnergySamples.isEmpty {
            appendEnergyLocked(for: pendingEnergySamples)
            pendingEnergySamples.removeAll()
        }
    }

    /// 已累積音訊是否超過安全網上限。呼叫端據此結束 session，不由本型別自行截斷。
    public var isOverCapacity: Bool {
        lock.lock(); defer { lock.unlock() }
        return TimeInterval(samples.count) / Self.sampleRate > maxDuration
    }

    /// 已累積音訊時長（秒）
    public var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return TimeInterval(samples.count) / Self.sampleRate
    }

    /// 逐條照抄套件 `AudioProcessor.processBuffer` 的能量算法：
    /// 參考值＝最近 `energyWindow` 格的最小平均能量（滾動噪音基準；空陣列時為 `.infinity`，
    /// 與套件同）。套件寫死 20，本型別讓它可調（見型別說明）。
    ///
    /// `max(1,)` 不是形式檢查：協定要求 `relativeEnergyWindow` 是公開可寫的 Int，擋不住 0；
    /// 而 `suffix(0)` 的參考值恆為 `.infinity`，算出的 NaN 會被套件末尾的
    /// `max(0, min(NaN, 1))` 夾成 **0**（Swift 的 max/min 遇 NaN 回傳另一個運算元）。
    /// 於是每一格都是 0、永遠衝不過靜音門檻，VAD 判定「永遠沒人講話」
    /// ——離線聽寫會靜默失效而不報任何錯。
    private func appendEnergyLocked(for bucket: [Float]) {
        let minAvgEnergy = audioEnergy.suffix(max(1, energyWindow))
            .reduce(Float.infinity) { min($0, $1.avg) }
        let rel = AudioProcessor.calculateRelativeEnergy(of: bucket, relativeTo: minAvgEnergy)
        let avg = AudioProcessor.calculateEnergy(of: bucket).avg
        audioEnergy.append((rel: rel, avg: avg))
    }

    private func convertLocked(_ src: AVAudioPCMBuffer) throws -> [Float] {
        // 來源格式中途改變（換音訊裝置）必須重建轉換器，否則會拿舊格式的轉換器餵新格式的 buffer
        if converter == nil || outputFormat == nil || sourceFormat != src.format {
            guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Self.sampleRate,
                                          channels: 1,
                                          interleaved: false),
                  let c = AVAudioConverter(from: src.format, to: out) else {
                throw StreamFedAudioSourceError.converterUnavailable
            }
            outputFormat = out
            converter = c
            sourceFormat = src.format
        }
        guard let converter, let outputFormat else { throw StreamFedAudioSourceError.converterUnavailable }

        let ratio = outputFormat.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StreamFedAudioSourceError.converterUnavailable
        }

        // 一次只餵一個來源 buffer：第二次索取回 .noDataNow 讓轉換器收工（比照 WAVAccumulator）
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return src
        }
        guard status != .error, convError == nil else { throw StreamFedAudioSourceError.conversionFailed }
        guard let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// 以 `.endOfStream` 排出重取樣器內部殘留的樣本
    private func drainConverterLocked() throws -> [Float] {
        guard let converter, let outputFormat else { return [] }
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return [] }
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, convError == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    // MARK: - AudioProcessing：串流轉錄器讀取的部分

    public var audioSamples: ContiguousArray<Float> {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// **不裁剪**：套件的同名屬性是 `audioEnergy.map { $0.rel }`，長度隨 session 成長；
    /// `isVoiceDetected` 依「距上次辨識多久」取 suffix，裁短了會讀到不足的窗口而誤判。
    public var relativeEnergy: [Float] {
        lock.lock(); defer { lock.unlock() }
        return audioEnergy.map(\.rel)
    }

    /// 協定要求的可寫屬性。套件只把它用在 debug log 的節流，對辨識沒有任何作用；
    /// 本型別把它接到滾動噪音基準的回看格數（見型別說明），**但仍不以它裁剪能量陣列**
    /// ——裁剪會讓 `isVoiceDetected` 讀到不足的窗口而誤判。
    /// 正常路徑由 init 設定；此 setter 留給協定與測試。以鎖保護是為了與其餘可變狀態的同步紀律一致。
    public var relativeEnergyWindow: Int {
        get { lock.lock(); defer { lock.unlock() }; return energyWindow }
        set { lock.lock(); defer { lock.unlock() }; energyWindow = newValue }
    }

    /// **刻意無操作**（見型別說明）：串流轉錄器以絕對索引記帳，清理會讓它算出負的新增量、
    /// 並讓解碼起點指向錯誤的音訊位置。長度改由 `isOverCapacity` 把關。
    public func purgeAudioSamples(keepingLast keep: Int) {}

    // MARK: - AudioProcessing：錄音生命週期（麥克風由既有管線持有，一律無操作）
    // 注意：排空轉換器是由本專案的 `finish()` 負責，不掛在 stopRecording 上——
    // 套件可能在 session 中途呼叫 stopRecording，屆時排空會把尾端樣本提前結算。

    public func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}
    public func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}
    public func pauseRecording() {}
    public func stopRecording() {}

    public func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        // 本專案不走這條路（音訊由 append 灌入）；回傳一個立即結束的空串流。
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        continuation.finish()
        return (stream, continuation)
    }

    // MARK: - AudioProcessing：檔案工具（本用法用不到，轉呼叫套件實作）

    public static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode,
                                 startTime: Double?, endTime: Double?,
                                 maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode,
                                     startTime: startTime, endTime: endTime,
                                     maxReadFrameSize: maxReadFrameSize)
    }

    public static func loadAudio(at audioPaths: [String],
                                 channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    public static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int,
                                      toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex,
                                      toLength: frameLength, saveSegment: saveSegment)
    }

    public func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int,
                          toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        Self.padOrTrimAudio(fromArray: audioArray, startAt: startIndex,
                            toLength: frameLength, saveSegment: false)
    }
}
