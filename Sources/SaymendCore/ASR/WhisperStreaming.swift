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

public extension WhisperStreamingOptions {
    /// 套件預設值的單一出處：設定頁的「套件預設」標示與「還原預設」都取這裡，
    /// 不各自再寫一份字面值。
    static let packageDefault = WhisperStreamingOptions()

    /// 兩個解碼門檻的**套件預設具體值**。本型別自身以 nil 表示「不覆寫」，但設定頁
    /// 得顯示得出「套件預設是多少」才有得比較，故在此抄一份 WhisperKit `DecodingOptions`
    /// 的預設。抄來的常數會過期——`packageThresholdConstantsMatchWhisperKit` 釘住它們，
    /// 套件改預設時該測試會當場失敗。
    static let packageLogProbThreshold: Float = -1.0
    static let packageCompressionRatioThreshold: Float = 2.4

    // MARK: - 合理範圍
    //
    // 超出範圍的持久化值＝設定損毀（手改 plist、舊版遺留），一律回落套件預設，
    // 比照 `AppSettings.timeoutRange` 的做法。UI 的 Stepper 另外把使用者輸入
    // 限制在同一組範圍內，兩道防線各守一端。

    /// 下界為 1：0 表示連正在講的那一段都立刻定稿，等於把必然會被改寫的文字直接上屏。
    static let requiredSegmentsRange: ClosedRange<Int> = 1...10
    /// 相對能量本身就被套件夾在 0…1，門檻超出此區間即恆真或恆假。
    static let silenceThresholdRange: ClosedRange<Float> = 0...1
    /// 一格 100ms：1 格＝只看前一格、200 格＝往回看 20 秒。
    static let relativeEnergyWindowRange: ClosedRange<Int> = 1...200
    static let compressionCheckWindowRange: ClosedRange<Int> = 1...500
    /// 對數機率恆為負；上界 0 等於「任何結果都不夠好」，下界 -10 已形同不設限。
    static let logProbThresholdRange: ClosedRange<Float> = -10...0
    /// 壓縮比下界 1（無法壓縮）；低於 1 不可能發生，設了等於全部判定為重複退化。
    static let compressionRatioThresholdRange: ClosedRange<Float> = 1...10
}

/// 串流辨識期間的失敗。載入失敗仍用 `WhisperLoadError`，兩者的失敗語彙不同。
public enum WhisperStreamError: Error, Equatable {
    /// 超過安全網長度上限（防止鎖定聽寫忘了關而吃光記憶體）
    case overCapacity(minutes: Int)
    /// 麥克風音訊轉不成 16k 單聲道
    case audioConversionFailed
}
