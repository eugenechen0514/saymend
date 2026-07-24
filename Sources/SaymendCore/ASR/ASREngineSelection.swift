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
    public init(selectedModelPath: URL?, extraScanRoots: [URL]) {
        self.selectedModelPath = selectedModelPath
        self.extraScanRoots = extraScanRoots
    }
}
