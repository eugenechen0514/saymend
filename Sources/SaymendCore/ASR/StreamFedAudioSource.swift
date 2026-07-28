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
/// 執行緒安全：寫入端是音訊管線的 pump、讀取端是串流轉錄器的隔離域，故以鎖保護。
/// 鎖的持有期間不含任何 await。
public final class StreamFedAudioSource: AudioProcessing, @unchecked Sendable {
    /// 串流轉錄器一律以 16kHz 單聲道解讀樣本
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var samples = ContiguousArray<Float>()
    private var energy: [Float] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    /// 安全網上限（秒）。超過只回報、不截斷——截斷會破壞「只增不減」而毀掉轉錄器的記帳。
    private let maxDuration: TimeInterval

    public var relativeEnergyWindow: Int = 20

    public init(maxDuration: TimeInterval = 30 * 60) {
        self.maxDuration = maxDuration
    }

    // MARK: - 本專案的入口

    /// 灌入一段麥克風音訊。逐 chunk 轉成 16kHz 單聲道 Float 後累積，
    /// 避免同時持有原始格式的全量資料造成記憶體尖峰（比照 WAVAccumulator）。
    public func append(_ chunk: AudioChunk) throws {
        let src = chunk.buffer
        guard src.frameLength > 0 else { return }
        let converted = try convert(src)
        guard !converted.isEmpty else { return }

        lock.lock()
        samples.append(contentsOf: converted)
        // 能量以「整段樣本」為輸入，與套件靜態函式的語意一致；只保留最近的窗口
        let snapshot = Array(samples)
        lock.unlock()

        let value = AudioProcessor.calculateRelativeEnergy(of: snapshot, relativeTo: nil)
        lock.lock()
        energy.append(value)
        if energy.count > relativeEnergyWindow {
            energy.removeFirst(energy.count - relativeEnergyWindow)
        }
        lock.unlock()
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

    private func convert(_ src: AVAudioPCMBuffer) throws -> [Float] {
        if converter == nil || outputFormat == nil {
            guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Self.sampleRate,
                                          channels: 1,
                                          interleaved: false),
                  let c = AVAudioConverter(from: src.format, to: out) else {
                throw StreamFedAudioSourceError.converterUnavailable
            }
            outputFormat = out
            converter = c
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

    // MARK: - AudioProcessing：串流轉錄器讀取的部分

    public var audioSamples: ContiguousArray<Float> {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    public var relativeEnergy: [Float] {
        lock.lock(); defer { lock.unlock() }
        return energy
    }

    /// **刻意無操作**（見型別說明）：串流轉錄器以絕對索引記帳，清理會讓它算出負的新增量、
    /// 並讓解碼起點指向錯誤的音訊位置。長度改由 `isOverCapacity` 把關。
    public func purgeAudioSamples(keepingLast keep: Int) {}

    // MARK: - AudioProcessing：錄音生命週期（麥克風由既有管線持有，一律無操作）

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
