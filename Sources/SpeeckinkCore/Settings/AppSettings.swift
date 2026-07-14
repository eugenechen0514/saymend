import CoreGraphics
import Foundation

/// 熱鍵選項（規格 §3.1；修飾鍵需走 CGEventTap）
public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case rightCommand
    case rightOption
    case rightControl

    public var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    public var flagMask: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: return "右 Command"
        case .rightOption: return "右 Option"
        case .rightControl: return "右 Control"
        }
    }
}

/// App 設定（規格 §4.9）。一般值進 UserDefaults；API key 進 SecretStore。
public final class AppSettings {
    public static let apiKeyKey = "openaiCompatAPIKey"

    private enum K {
        static let hotkey = "hotkey"
        static let outputLanguage = "outputLanguage"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let asrLocale = "asrLocaleIdentifier"
        static let customSystemPrompt = "customSystemPrompt"
        static let styleRulesOverride = "styleRulesOverride"
        static let historyEnabled = "historyEnabled"
        static let historyRetentionDays = "historyRetentionDays"
        static let ocrContextEnabled = "ocrContextEnabled"
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var hotkey: HotkeyChoice {
        get { defaults.string(forKey: K.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: K.hotkey) }
    }

    public var outputLanguage: OutputLanguage {
        get { defaults.string(forKey: K.outputLanguage).flatMap(OutputLanguage.init(rawValue:)) ?? .followSpeech }
        set { defaults.set(newValue.rawValue, forKey: K.outputLanguage) }
    }

    public var llmBaseURLString: String {
        get { defaults.string(forKey: K.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: K.llmBaseURL) }
    }

    public var llmModel: String {
        get { defaults.string(forKey: K.llmModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: K.llmModel) }
    }

    public var asrLocaleIdentifier: String {
        get { defaults.string(forKey: K.asrLocale) ?? "zh-TW" }
        set { defaults.set(newValue, forKey: K.asrLocale) }
    }

    /// prompt 第 4 層：使用者全域自訂 system prompt（規格 §4.4；空字串＝未設定）
    public var customSystemPrompt: String {
        get { defaults.string(forKey: K.customSystemPrompt) ?? "" }
        set { defaults.set(newValue, forKey: K.customSystemPrompt) }
    }

    /// prompt 第 3 層覆寫：nil＝用內建預設（規格 §4.11「做成可編輯的輸出風格設定」）
    public var styleRulesOverride: String? {
        get {
            let v = defaults.string(forKey: K.styleRulesOverride)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: K.styleRulesOverride) }
    }

    /// 聽寫歷史開關（規格 §4.9；預設開，供回查除錯）
    public var historyEnabled: Bool {
        get { defaults.object(forKey: K.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: K.historyEnabled) }
    }

    /// OCR 螢幕語境備援開關（規格 §4.7）。預設關（opt-in）：螢幕擷取最具侵入性，
    /// 由使用者明確開啟才動用。開啟後仍受既有降級序節制——僅在 AX 讀不到前後文、
    /// 非安全欄位、且螢幕錄製權限已授權時才實際截圖。
    public var ocrContextEnabled: Bool {
        get { defaults.object(forKey: K.ocrContextEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: K.ocrContextEnabled) }
    }

    /// 歷史保留天數（規格 §4.9「可設保留天數」；啟動時清除過期）
    public var historyRetentionDays: Int {
        get {
            let v = defaults.integer(forKey: K.historyRetentionDays)
            return v > 0 ? v : 30
        }
        set { defaults.set(newValue, forKey: K.historyRetentionDays) }
    }

    /// per-session 臨時語系覆蓋（規格 §4.5 快速切換）。純記憶體：不持久化，
    /// session 封存時由 DictationController 清除。解析序：本值 > profile 固定語系 > outputLanguage。
    public var sessionLanguageOverride: OutputLanguage?

    public var llmAPIKey: String? {
        get { try? secrets.get(forKey: Self.apiKeyKey) }
        set {
            if let v = newValue, !v.isEmpty {
                try? secrets.set(v, forKey: Self.apiKeyKey)
            } else {
                try? secrets.delete(forKey: Self.apiKeyKey)
            }
        }
    }

    public func openAIConfig() -> OpenAICompatConfig {
        let url = URL(string: llmBaseURLString) ?? URL(string: "https://api.openai.com/v1")!
        return OpenAICompatConfig(baseURL: url, apiKey: llmAPIKey, model: llmModel)
    }
}
