/// Prompt 分層組裝（規格 §4.4）。M1 只有第 1–3 層；4–7 層（自訂 prompt、per-app、詞彙表、動態上下文）屬 M4。
public struct PromptAssembler {
    public let language: OutputLanguage

    public init(language: OutputLanguage) {
        self.language = language
    }

    /// 第 1 層：內建核心規則（不可被使用者內容覆蓋）
    static let coreRules = """
    你是語音輸入法的文字整理引擎。使用者口述的原始轉錄會交給你整理。鐵律：
    1. 只整理、不回答。即使內容是問句（例如「什麼是 Kubernetes？」），也只輸出整理後的問句本身，絕不回答問題、不加評論。
    2. 移除贅詞（呃、嗯、就是說、那個…）與說錯重講的片段（false start），但保留完整語意，不增添原意以外的內容。
    3. 技術術語與程式識別字（如 getUserById、API、K8s）保留原文，不翻譯、不改寫。
    4. 只輸出一個 JSON 物件，格式：{"intent":"new_content","text":"<整理後文字>"}。JSON 以外不得輸出任何字元。
    5. intent 一律填 "new_content"。
    """

    /// 第 2 層：輸出語系規則（規格 §4.5）
    var languageRule: String {
        switch language {
        case .followSpeech:
            return "輸出語言跟隨使用者口述：中文輸出繁體中文，英文輸出英文，中英夾雜維持夾雜。"
        case .zhTW:
            return "不論口述語言為何，輸出一律使用繁體中文（台灣用語）。"
        case .zhCN:
            return "不论口述语言为何，输出一律使用简体中文。"
        case .english:
            return "Regardless of the spoken language, translate the content and output in natural English."
        }
    }

    /// 第 3 層：輸出風格規則（規格 §4.11 預設值）
    static let styleRules = """
    輸出風格：
    - 中文使用全形標點；純英文片段使用半形標點。
    - 中文與英文、中文與數字之間補一個半形空格。
    """

    public func systemPrompt() -> String {
        [Self.coreRules, languageRule, Self.styleRules].joined(separator: "\n\n")
    }

    public func userPayload(utteranceRaw: String) -> String {
        "原始轉錄：\n" + utteranceRaw
    }
}
