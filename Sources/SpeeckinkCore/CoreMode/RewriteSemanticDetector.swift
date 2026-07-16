import Foundation

public enum RewriteSemanticDetector {
    /// 高 precision、低 recall：寧可漏掉委婉繞過，也不因單純提到技術名詞而阻擋。
    public static func detect(in s: String) -> [String] {
        var reasons: [String] = []
        let lowered = s.lowercased()

        // JSON 繞過
        if let _ = lowered.range(of: #"(不要|別|禁止|無須|改用|略過|do\s+not|don't|never).{0,16}(輸出|回傳|使用|output|return|use).{0,8}json"#, options: .regularExpression) {
            reasons.append("輸出非 JSON")
        }
        if let _ = lowered.range(of: #"(輸出|回傳|回應|output|return|respond).{0,8}(非|不是|不要|without|non[- ]?).{0,8}json"#, options: .regularExpression) {
            reasons.append("輸出非 JSON")
        }

        // intent 覆寫
        if let _ = lowered.range(of: #"(intent|new_content|edit_command|undo).{0,16}(一律|永遠|固定|都設為|always|never)"#, options: .regularExpression) {
            reasons.append("覆寫 intent 列舉")
        }
        if let _ = lowered.range(of: #"(不要判|禁止判|do\s+not\s+classify|never\s+classify).{0,16}(intent|new_content|edit_command|undo)"#, options: .regularExpression) {
            reasons.append("覆寫 intent 列舉")
        }

        // 反注入繞過
        if let _ = lowered.range(of: #"(ocr|上下文|選取|轉錄|session).{0,16}(當成|當作|當|視為|作為).{0,8}(指令|system\s+prompt)"#, options: .regularExpression) {
            reasons.append("把上下文當指令")
        }
        if let _ = lowered.range(of: #"(忽略|略過|ignore|bypass).{0,16}(機器契約|machine\s+contract|反注入|不可夾帶指令)"#, options: .regularExpression) {
            reasons.append("忽略機器契約")
        }

        return reasons
    }
}
