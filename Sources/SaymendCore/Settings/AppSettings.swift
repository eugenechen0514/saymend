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
///
/// `@unchecked Sendable`（三件事誠實揭露，勿以「stored 全 let」誤讀）：
/// ① `defaults`（UserDefaults）與 `secrets`（SecretStore）皆為 `let`、底層 thread-safe。
/// ② `sessionLanguageOverride`／`sessionCoreModeID` 是兩個純記憶體 stored `var`，MainActor-by-convention
///    （非編譯器強制）；本標記**不**為其提供跨執行緒安全，僅約定由 MainActor 存取，標記前後風險不變。
/// ③ 本標記只是把既有 de facto 契約顯式化：M1 起 `OpenAICompatProvider.complete()` 已在背景 executor
///    呼叫 `configProvider()`（即 defaults/secrets-backed 存取早已跨執行緒），非新開風險。
public final class AppSettings: @unchecked Sendable {
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
        static let defaultCoreModeID = "defaultCoreModeID"
        static let providerKind = "providerKind"
        static let cliPathOverride = "claudeCLIPathOverride"
        static let cliModel = "claudeCLIModel"
        static let oaiPolishTimeout = "oaiPolishTimeout"
        static let oaiEditTimeout = "oaiEditTimeout"
        static let cliPolishTimeout = "cliPolishTimeout"
        static let cliEditTimeout = "cliEditTimeout"
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

    /// 全域預設核心模式（規格 §3.2）。nil＝未設定，解析式落到內建預設。
    public var defaultCoreModeID: String? {
        get { defaults.string(forKey: K.defaultCoreModeID) }
        set {
            if let v = newValue { defaults.set(v, forKey: K.defaultCoreModeID) }
            else { defaults.removeObject(forKey: K.defaultCoreModeID) }
        }
    }

    /// per-session 臨時核心模式覆蓋（規格 §3.2）。純記憶體、不寫 UserDefaults。
    /// Session 封存時由 DictationController.archiveSession 清除。
    public var sessionCoreModeID: String?

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

    // MARK: - Provider 選擇與 per-provider timeout（spec §5/§6）

    /// 使用者設定值合法範圍（configured deadline；runner 收到的剩餘 budget 不在此限——spec §5）
    public static let timeoutRange: ClosedRange<TimeInterval> = 1...120

    public var providerKind: ProviderKind {
        get { defaults.string(forKey: K.providerKind).flatMap(ProviderKind.init(rawValue:)) ?? .openAICompat }
        set { defaults.set(newValue.rawValue, forKey: K.providerKind) }
    }

    public var claudeCLIPathOverride: String? {
        get {
            let v = defaults.string(forKey: K.cliPathOverride)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: K.cliPathOverride) }
    }

    public var claudeCLIModel: String {
        get { defaults.string(forKey: K.cliModel) ?? "sonnet" }   // spike 定案
        set { defaults.set(newValue, forKey: K.cliModel) }
    }

    /// 讀取防線（spec §5）：缺失／非數值／NaN／Inf／超出 [1,120] 一律回該 provider 預設值。
    private func readTimeout(_ key: String, default def: TimeInterval) -> TimeInterval {
        guard let v = defaults.object(forKey: key) as? Double, v.isFinite,
              Self.timeoutRange.contains(v) else { return def }
        return v
    }

    public var oaiPolishTimeout: TimeInterval {
        get { readTimeout(K.oaiPolishTimeout, default: 3.0) }
        set { defaults.set(newValue, forKey: K.oaiPolishTimeout) }
    }
    public var oaiEditTimeout: TimeInterval {
        get { readTimeout(K.oaiEditTimeout, default: 6.0) }
        set { defaults.set(newValue, forKey: K.oaiEditTimeout) }
    }
    public var cliPolishTimeout: TimeInterval {
        get { readTimeout(K.cliPolishTimeout, default: 20.0) }     // spike 定案（單句 ~5s、並行近序列 14.6s）
        set { defaults.set(newValue, forKey: K.cliPolishTimeout) }
    }
    public var cliEditTimeout: TimeInterval {
        get { readTimeout(K.cliEditTimeout, default: 20.0) }
        set { defaults.set(newValue, forKey: K.cliEditTimeout) }
    }

    public func providerTimeouts(for kind: ProviderKind) -> (polish: TimeInterval, edit: TimeInterval) {
        switch kind {
        case .openAICompat: return (oaiPolishTimeout, oaiEditTimeout)
        case .claudeCLI: return (cliPolishTimeout, cliEditTimeout)
        }
    }

    public func claudeCLIConfig() -> ClaudeCLIConfig {
        ClaudeCLIConfig(cliPathOverride: claudeCLIPathOverride, model: claudeCLIModel)
    }
}
