import Foundation

/// 串流辨識的一次進度回報。
///
/// 兩段文字直接對應本專案的**定稿文字**與**暫時文字**（見 CONTEXT.md），
/// 也直接對應 WhisperKit 串流轉錄器的 confirmed／unconfirmed segments。
///
/// 命名刻意不叫 `TranscriptionProgress`——WhisperKit 已有同名型別，撞名會逼出
/// 到處寫模組前綴的醜態。
public struct WhisperStreamProgress: Equatable, Sendable {
    /// 已定稿：只增不減
    public let confirmed: String
    /// 尚未定稿：可能被後續解碼推翻
    public let unconfirmed: String

    public init(confirmed: String, unconfirmed: String) {
        self.confirmed = confirmed
        self.unconfirmed = unconfirmed
    }
}

/// 串流辨識的可調參數（issue #12）。預設值一律取自 WhisperKit 的套件預設，
/// 讓「沒調過」與「用套件原生行為」是同一件事。設定頁的暴露見 #15。
///
/// **不含無語音機率門檻**：WhisperKit 1.0.0 的 `noSpeechProb` 寫死為 0、
/// 其判斷式恆為假，該參數完全不作用。暴露一個調了沒反應的旋鈕比不給更糟。
public struct WhisperStreamingOptions: Equatable, Sendable {
    /// 幾段之後才把文字視為定稿。**即時感 vs 穩定度的主旋鈕**：
    /// 調小＝文字更快定稿但會反覆修改；調大＝穩定但延遲高。
    public var requiredSegmentsForConfirmation: Int
    /// 語音活動偵測的靜音能量門檻。環境吵調高、講話小聲調低。
    public var silenceThreshold: Float
    /// 語音活動偵測總開關。關掉＝連靜音都送去解碼。
    public var useVAD: Bool
    /// 能量取樣窗口。影響靜音判定的反應速度。
    public var relativeEnergyWindow: Int
    /// 壓縮比檢查窗口。偵測重複退化的輸出。
    public var compressionCheckWindow: Int
    /// 平均對數機率下限，低於視為失敗。nil＝用套件預設。
    public var logProbThreshold: Float?
    /// 壓縮比上限，高於視為重複退化。nil＝用套件預設。
    public var compressionRatioThreshold: Float?

    public init(requiredSegmentsForConfirmation: Int = 2,
                silenceThreshold: Float = 0.3,
                useVAD: Bool = true,
                relativeEnergyWindow: Int = 20,
                compressionCheckWindow: Int = 60,
                logProbThreshold: Float? = nil,
                compressionRatioThreshold: Float? = nil) {
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
        self.silenceThreshold = silenceThreshold
        self.useVAD = useVAD
        self.relativeEnergyWindow = relativeEnergyWindow
        self.compressionCheckWindow = compressionCheckWindow
        self.logProbThreshold = logProbThreshold
        self.compressionRatioThreshold = compressionRatioThreshold
    }
}

/// 串流辨識期間的失敗。載入失敗仍用 `WhisperLoadError`，兩者的失敗語彙不同。
public enum WhisperStreamError: Error, Equatable {
    /// 超過安全網長度上限（防止鎖定聽寫忘了關而吃光記憶體）
    case overCapacity(minutes: Int)
    /// 麥克風音訊轉不成 16k 單聲道
    case audioConversionFailed
}
