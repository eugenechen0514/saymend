import Foundation

/// CLI 聽寫不潤飾時的**本機確定性後處理**：簡繁轉換＋詞彙表誤轉寫替換。不碰網路、不碰語言模型，
/// 同樣的輸入永遠得到同樣的輸出。
///
/// 只用在 CLI 聽寫：熱鍵聽寫的原文直接上屏、由潤飾整理，那條路徑的行為不動。
///
/// - **簡繁**：輸出語系是 zh-TW 才轉（與潤飾後的保險絲 `TraditionalizeGuard` 同一個轉換器、同一個條件）。
///   CLI 聽寫沒有目標 App，所以不看 per-app 的固定語系，也不看熱鍵 session 的臨時覆蓋，只看全域設定。
/// - **詞彙表**：把使用者登記的「常見誤轉寫」換成正確詞彙。先轉簡繁再替換——使用者用繁體登記的誤轉寫
///   才對得上 Whisper 吐出來的簡體。英數開頭／結尾的誤轉寫要求字邊界（`ai` 不得吃掉 `said` 裡的字），
///   不分大小寫；中文沒有字邊界的概念，照字面比對。
public struct TranscriptPostProcessor {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let traditionalize: ((String) -> String)?
    private let rules: [Rule]

    public init(vocab: [VocabEntry], traditionalize: ((String) -> String)?) {
        self.traditionalize = traditionalize
        // 長的先換：避免短的誤轉寫先吃掉長的那個的一部分（「歐噴」vs「歐噴佩茲」）
        let pairs = vocab.flatMap { entry in
            entry.mishearings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != entry.phrase }   // 只差大小寫的照換（ai → AI 是合法的校正）
                .map { (mishearing: $0, phrase: entry.phrase) }
        }.sorted { $0.mishearing.count > $1.mishearing.count }
        rules = pairs.compactMap { pair in
            var pattern = NSRegularExpression.escapedPattern(for: pair.mishearing)
            if let first = pair.mishearing.unicodeScalars.first, Self.isASCIIWordChar(first) {
                pattern = "(?<![A-Za-z0-9_])" + pattern
            }
            if let last = pair.mishearing.unicodeScalars.last, Self.isASCIIWordChar(last) {
                pattern += "(?![A-Za-z0-9_])"
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Rule(regex: regex, replacement: NSRegularExpression.escapedTemplate(for: pair.phrase))
        }
    }

    public func apply(_ text: String) -> String {
        var out = traditionalize?(text) ?? text
        for rule in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = rule.regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: rule.replacement)
        }
        return out
    }

    private static func isASCIIWordChar(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_")
    }
}
