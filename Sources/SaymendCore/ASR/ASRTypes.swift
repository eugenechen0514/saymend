import AVFoundation

/// 一段定稿文字的辨識品質摘要（issue #10）。
///
/// 兩個數字都是 Whisper 解碼器對**單一片段**給的自評，本型別是「這段定稿文字涵蓋的
/// 全部片段」的**最壞值**摘要。取最壞值而非平均，是因為 WhisperKit 的門檻本來就是
/// 逐片段套用的（`DecodingOptions.logProbThreshold`／`compressionRatioThreshold`）——
/// 最壞值才回答得了「若門檻設在 X，這段文字會不會被擋下」，平均會把一個爛片段稀釋掉。
///
/// **這是診斷資料，不是判決。** 目前沒有任何程式碼依這兩個數字做取捨；先累積幾筆
/// 幻覺與正常語句的對照，有依據之後才決定要調門檻還是做輸出過濾。只有一筆樣本時
/// 訂出來的門檻，擋掉的會是使用者真的講的話。
public struct TranscriptQuality: Equatable, Sendable {
    /// 平均對數機率的最小值。恆為負，愈低＝解碼器對自己愈沒把握。
    public let minAvgLogprob: Float
    /// 壓縮比的最大值。愈高＝文字愈重複，Whisper 用它偵測退化成複讀的輸出。
    public let maxCompressionRatio: Float
    /// 摘要涵蓋幾個片段。少了它，回查時無法分辨極值是來自一個片段還是二十個。
    public let segmentCount: Int

    public init(minAvgLogprob: Float, maxCompressionRatio: Float, segmentCount: Int) {
        self.minAvgLogprob = minAvgLogprob
        self.maxCompressionRatio = maxCompressionRatio
        self.segmentCount = segmentCount
    }

    /// 從逐片段的自評聚合。空陣列回 nil——「沒有片段」與「有片段但品質是 0」是兩件事，
    /// 用零值假裝有資料會在統計時混進假樣本。
    public init?(segments: [TranscriptSegmentQuality]) {
        guard let first = segments.first else { return nil }
        var minLogprob = first.avgLogprob
        var maxRatio = first.compressionRatio
        for s in segments.dropFirst() {
            minLogprob = min(minLogprob, s.avgLogprob)
            maxRatio = max(maxRatio, s.compressionRatio)
        }
        self.init(minAvgLogprob: minLogprob, maxCompressionRatio: maxRatio,
                  segmentCount: segments.count)
    }
}

/// 單一片段的辨識品質自評（issue #10）。聚合成 `TranscriptQuality` 之前的原始形狀。
public struct TranscriptSegmentQuality: Equatable, Sendable {
    public let avgLogprob: Float
    public let compressionRatio: Float

    public init(avgLogprob: Float, compressionRatio: Float) {
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
    }
}

/// ASR 事件（規格 §4.2）：volatile 只進 HUD；finalized 才上屏。
public enum TranscriptEvent: Equatable, Sendable {
    case volatile(String)
    /// 定稿文字。`quality` 是**選配診斷資料**（issue #10）：只有本機 Whisper 串流引擎
    /// 給得出來，其他引擎一律 nil。它不影響任何上屏決策，純粹寫進歷史供回查。
    case finalized(String, quality: TranscriptQuality?)
    /// M8：批次引擎已收完音訊、等待辨識結果（僅 WhisperRemoteEngine 會吐）
    case transcribing
    /// M9：本機引擎正在載入模型（首次含 ANE 編譯，實測 large-v3-turbo 可達數分鐘）。
    /// 不折進 .transcribing——折了會讓使用者以為「辨識中…」卡死。
    case loadingModel
    /// M8：辨識失敗，不上屏、不入帳本（僅 WhisperRemoteEngine 會吐）
    case failed(reason: String)
    /// issue #18：整段音訊都沒有任何一格超過靜音門檻——使用者可能講了話但麥克風太遠。
    ///
    /// **一個 session 最多一次**（邊緣觸發）。持續判否時底層每 0.5 秒就有一筆音訊統計進來，
    /// 若照單全發，斷句器的靜音計時會被打爆、話語永不閉合（同 `WhisperKitEngine.pump`
    /// 對套件回呼的去重紀律）。故本事件**不進斷句器**，由控制器單獨處理。
    ///
    /// 目前僅本機串流引擎會發；其他引擎不發，對它們是可選資訊。
    case noSpeechDetected

    /// 不帶診斷資料的定稿文字。**這是與 case 同名的靜態便利方法，不是另一個 case。**
    /// Swift 的 enum case 不能有預設值，而 `quality` 對三個引擎中的兩個永遠是 nil；
    /// 少了這個重載，每一處既有的 `.finalized("…")` 都得改寫成 `.finalized("…", quality: nil)`
    /// ——光測試就有 144 處，全是與本票無關的雜訊。回傳值與 `quality: nil` 完全相等，
    /// 故 Equatable 比對、模式比對都不受影響。
    public static func finalized(_ text: String) -> TranscriptEvent {
        .finalized(text, quality: nil)
    }
}

/// AVAudioPCMBuffer 的 Sendable 包裝（單一生產者、單一消費者，不共享可變狀態）
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// ASR 引擎介面（規格 §4.2）。audio 串流 finish＝正常收尾：實作須排空剩餘 finalized 再結束事件串流。
public protocol ASREngine: AnyObject {
    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent>
    /// 立即取消（Esc）：事件串流盡快結束，可不排空。
    func cancel()
}

/// 麥克風擷取介面
public protocol AudioCaptureService: AnyObject {
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
    /// 音量位準（0...1），供 HUD 波形顯示
    var levelHandler: ((Float) -> Void)? { get set }
}
