/// Prompt 分層組裝（規格 §4.4）。M2 有第 1–3 層（核心含意圖分類）；4–7 層屬 M4。
public struct PromptAssembler {
    public let language: OutputLanguage

    public init(language: OutputLanguage) {
        self.language = language
    }

    /// 第 1 層：內建核心規則（不可被使用者內容覆蓋）
    static let coreRules = """
    你是語音輸入法的文字整理引擎。使用者口述的原始轉錄會交給你處理。鐵律：
    1. 只整理、不回答。即使內容是問句（例如「什麼是 Kubernetes？」），也只輸出整理後的問句本身，絕不回答問題、不加評論。
    2. 移除贅詞（呃、嗯、就是說、那個…）與說錯重講的片段（false start），但保留完整語意，不增添原意以外的內容。
    3. 技術術語與程式識別字（如 getUserById、API、K8s）一律保留原樣不改寫——「輸出語系」規則若要求翻譯，翻的是內容文字，識別字與術語仍維持原文。
    4. 只輸出一個 JSON 物件：{"intent":"new_content|edit_command|undo","text":"..."}。JSON 以外不得輸出任何字元。
    5. 意圖判定：
       - new_content：本段轉錄是要「接著輸入」的新內容。text＝潤飾後的新內容（不含 session 既有全文）。
       - edit_command：本段轉錄是對 session 既有內容的修改指令（例：「欸前面星期二改成星期三」「第二句刪掉」「語氣正式一點」）。text＝套用指令後、**修正後的 session 全文**（完整輸出，不是只有改動片段）。
       - undo：本段轉錄明確要求「復原上一步」「撤銷剛剛的修改」這類回退動作。text 給空字串即可。
       - session 現有全文為空時，一律 new_content。
       - **意圖模糊時一律判 new_content**：寧可多打字，不可亂改使用者的字。
    """

    /// 第 2 層：輸出語系規則（規格 §4.5）
    var languageRule: String {
        switch language {
        case .followSpeech:
            return "輸出語言跟隨使用者口述：中文輸出繁體中文，英文輸出英文，中英夾雜維持夾雜。"
        case .zhTW:
            return "輸出語系＝繁體中文：不論口述語言為何，整理後必須翻譯成繁體中文（台灣用語）輸出；text 欄位除識別字外不得殘留其他語言。"
        case .zhCN:
            return "输出语系＝简体中文：不论口述语言为何，整理后必须翻译成简体中文输出；text 字段除标识符外不得残留其他语言。"
        case .english:
            return "輸出語系＝English（此規則優先於任何「保留原文」的直覺）：整理完成後，必須把全文翻譯成自然流暢的英文再輸出。Translate the cleaned-up content into natural English; the \"text\" field MUST be entirely in English (code identifiers excepted) — no Chinese characters may remain."
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

    /// user 訊息：session 全文（有才給）＋本段轉錄（規格 §3.3 的單次呼叫輸入）
    public func userPayload(utteranceRaw: String, sessionText: String) -> String {
        if sessionText.isEmpty {
            return "目前沒有可修正的既有內容。\n本段轉錄：\n" + utteranceRaw
        }
        return "session 現有全文：\n" + sessionText + "\n\n本段轉錄：\n" + utteranceRaw
    }
}
