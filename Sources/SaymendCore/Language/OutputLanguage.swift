public enum Saymend {
    public static let version = "0.1.0"
}

/// 輸出語系（規格 §4.5）。rawValue 存進 UserDefaults，不得改動。
public enum OutputLanguage: String, CaseIterable, Codable, Sendable {
    case followSpeech
    case zhTW
    case zhCN
    case english

    public var displayName: String {
        switch self {
        case .followSpeech: return "跟隨語音"
        case .zhTW: return "繁體中文（zh-TW）"
        case .zhCN: return "简体中文（zh-CN）"
        case .english: return "English"
        }
    }
}
