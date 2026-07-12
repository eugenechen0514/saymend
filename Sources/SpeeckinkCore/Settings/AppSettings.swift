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
