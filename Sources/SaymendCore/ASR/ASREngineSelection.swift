import Foundation

/// ASR 引擎選擇（spec §3）。加新引擎＝加一個 case ＋ router 一路。
public enum ASREngineKind: String, Codable, CaseIterable, Sendable {
    case speechAnalyzer
    case whisperRemote
    case whisperLocal

    /// 設定頁顯示字串。文案歸屬 Core，比照 HotkeyChoice.displayName 與
    /// OutputLanguage.displayName 的既有慣例，UI 端一律 ForEach(allCases) + tag。
    public var displayName: String {
        switch self {
        case .speechAnalyzer: return "系統內建（Apple SpeechAnalyzer）"
        case .whisperRemote:  return "Whisper 遠端"
        case .whisperLocal:   return "本機 WhisperKit（離線）"
        }
    }
}

/// Whisper 遠端設定（spec §3.2）
public struct WhisperRemoteConfig: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String?, model: String, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
    }
}

/// 本機 WhisperKit 設定（spec §5）。無 API key（本機）。
public struct WhisperLocalConfig: Equatable, Sendable {
    public var selectedModelPath: URL?
    public var extraScanRoots: [URL]
    /// 聽寫時等模型載入的上限（秒，issue #17）。
    ///
    /// **逾時只放棄這次聽寫，不中止載入**（也中止不了，見 `awaitBounded`）。
    /// 預設 15 秒的依據不是量測而是使用情境：使用者正按著熱鍵站在那裡，冷載入
    /// （實測 543～1297 秒）無論如何都不可能在他還記得要講什麼的時間內完成；
    /// 暖快取實測 2.26 秒，15 秒有充裕餘裕。
    public var modelWaitTimeout: TimeInterval

    public init(selectedModelPath: URL?, extraScanRoots: [URL],
                modelWaitTimeout: TimeInterval = 15) {
        self.selectedModelPath = selectedModelPath
        self.extraScanRoots = extraScanRoots
        self.modelWaitTimeout = modelWaitTimeout
    }
}
