/// 把字串切成 UTF-16 長度 ≤ maxUTF16 的片段，且不切斷 grapheme cluster。
/// CGEvent keyboardSetUnicodeString 單事件上限 20 個 UTF-16 unit（Task 12 使用）。
public enum TypingChunker {
    public static func chunks(of text: String, maxUTF16: Int = 20) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for ch in text {
            let units = String(ch).utf16.count
            if currentUnits + units > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(ch)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
