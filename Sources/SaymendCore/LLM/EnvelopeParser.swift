import Foundation

/// LLM 回應的 JSON 信封（規格 §3.3）。
public struct LLMEnvelope: Decodable, Equatable, Sendable {
    public let intent: String
    public let text: String

    public init(intent: String, text: String) {
        self.intent = intent
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case intent, text }

    /// 寬容解碼：長尾模型常省略空欄位（undo 的 text、甚至 intent）。
    /// 缺 intent 依「意圖模糊→new_content」原則補預設；缺 text 補空字串（下游對空文另有防護）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decodeIfPresent(String.self, forKey: .intent) ?? "new_content"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

public enum EnvelopeParseMode: Sendable {
    case strict
    case lenient
}

public enum EnvelopeParseError: Error, Equatable, Sendable {
    case malformedEnvelope
    case forbiddenUnicode
    case forbiddenBOM
    case structuralHomoglyph
    case missingOrExtraFields
}

public enum EnvelopeParser {
    /// control/zero-width/bidi 等禁止字元（規格 §3.3；與 CoreModeStore 的 forbiddenScalars 同一類邊界，
    /// 但排除 \t\n\r——這三個是合法 JSON whitespace，pretty-printed JSON 與 fenced 圍欄前後都會用到，
    /// 誤擋會讓 envelopeParserStrictAcceptsWhitespaceNewline 這類合法輸入被錯判為 forbiddenUnicode）。
    private static let reservedScalars: Set<Unicode.Scalar> = {
        var s: Set<Unicode.Scalar> = []
        let allowedWhitespace: Set<UInt32> = [0x09, 0x0A, 0x0D]  // \t \n \r
        for u: UInt32 in 0x0000...0x001F where !allowedWhitespace.contains(u) {
            if let sc = Unicode.Scalar(u) { s.insert(sc) }
        }
        for u: UInt32 in 0x007F...0x009F { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        s.insert(Unicode.Scalar(0x200B)!); s.insert(Unicode.Scalar(0x200C)!)
        s.insert(Unicode.Scalar(0x200D)!); s.insert(Unicode.Scalar(0x2060)!); s.insert(Unicode.Scalar(0xFEFF)!)
        s.insert(Unicode.Scalar(0x061C)!); s.insert(Unicode.Scalar(0x200E)!); s.insert(Unicode.Scalar(0x200F)!)
        for u: UInt32 in 0x202A...0x202E { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        for u: UInt32 in 0x2066...0x2069 { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        return s
    }()

    /// JSON 結構性同形字（規格 §3.3 rule 4 逐字列舉：｛｝＂：，）。
    /// 只在「JSON 字串以外」的位置檢查——text／intent 值裡的正常全形標點不算。
    private static let structuralHomoglyphs: Set<Character> = [
        "\u{FF5B}", "\u{FF5D}",  // ｛ ｝
        "\u{FF02}",              // ＂
        "\u{FF1A}",              // ：
        "\u{FF0C}",              // ，
    ]

    /// tokenizer-aware 掃描：只在字串字面「以外」的位置比對 structuralHomoglyphs，
    /// 避免誤殺 text 值內的正常中文標點（規格 §3.3 rule 4 明文要求）。
    private static func containsStructuralHomoglyphOutsideStrings(_ raw: String) -> Bool {
        var inString = false
        var escape = false
        for c in raw {
            if escape { escape = false; continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; continue }
            if structuralHomoglyphs.contains(c) { return true }
        }
        return false
    }

    public static func parse(_ raw: String,
                             mode: EnvelopeParseMode = .strict) -> Result<LLMEnvelope, EnvelopeParseError> {
        switch mode {
        case .strict: return parseStrict(raw)
        case .lenient: return parseLenient(raw)
        }
    }

    private static func parseStrict(_ raw: String) -> Result<LLMEnvelope, EnvelopeParseError> {
        // 1. BOM 必須不存在
        if raw.hasPrefix("\u{FEFF}") {
            return .failure(.forbiddenBOM)
        }
        // 2. 整體掃 forbidden（control/zero-width/bidi）
        if raw.unicodeScalars.contains(where: { reservedScalars.contains($0) }) {
            return .failure(.forbiddenUnicode)
        }
        // 3. structural homoglyph：只擋 JSON 字串以外的全形結構符號
        if containsStructuralHomoglyphOutsideStrings(raw) {
            return .failure(.structuralHomoglyph)
        }
        // 4. 必須是單一 JSON 物件：前後不得有任何贅字
        //    （原本這裡還有一段對 trimmed 全字串數 { } 的 guard，用來擋多個物件；
        //    但那段計數沒有排除字串字面內部，導致 text 值裡含 { 或 }（例如口述程式碼、
        //    或提到「設定 {name} 欄位」）就會被誤判為多物件而拒絕——VSCode profile 明文
        //    要求「識別字與程式碼片段原樣保留」，這條路徑上講出 { 就必掛。這段 guard 本身
        //    也是多餘的：多物件 {...}{...} 交給 JSONSerialization 解析就會自然失敗，
        //    不需要自己數大括號。已移除。）
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else {
            return .failure(.malformedEnvelope)
        }
        // 5. 不可含 fenced JSON 圍欄
        guard !trimmed.contains("```") else {
            return .failure(.malformedEnvelope)
        }

        // 6. 嚴格解碼：JSONDecoder 會忽略多餘欄位，所以自己驗 top-level key set，
        //    且自己驗型別——不可沿用 LLMEnvelope 的寬容 decodeIfPresent 語意：
        //    JSON null 會讓 decodeIfPresent 回 nil 而套用預設值（intent 靜默變成
        //    "new_content"），等同「LLM 回 null intent 就被當成新內容插入」，
        //    直接違反 SPEC §6.1（缺欄位／型別錯誤一律拒絕，寬容補值只屬於 lenient）。
        guard let dict = topLevelObject(in: trimmed),
              Set(dict.keys) == Set(["intent", "text"]) else {
            return .failure(.missingOrExtraFields)
        }
        guard let intentValue = dict["intent"] as? String,
              let textValue = dict["text"] as? String else {
            return .failure(.missingOrExtraFields)
        }

        // 7. 二次掃描 decoded 值內的 forbidden（防 JSON escape，如 ​ 繞過 raw 掃描）
        if intentValue.unicodeScalars.contains(where: { reservedScalars.contains($0) })
            || textValue.unicodeScalars.contains(where: { reservedScalars.contains($0) }) {
            return .failure(.forbiddenUnicode)
        }
        return .success(LLMEnvelope(intent: intentValue, text: textValue))
    }

    /// top-level JSON 物件：交給 JSONSerialization 解析後直接取 dictionary，
    /// 避免手寫 tokenizer 重造 JSON 解析容易出的 depth 追蹤錯誤。
    private static func topLevelObject(in json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func parseLenient(_ raw: String) -> Result<LLMEnvelope, EnvelopeParseError> {
        var s = raw
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        // lenient 仍拒絕 forbidden Unicode（診斷用途，不代表可放行注入字元）
        if s.unicodeScalars.contains(where: { reservedScalars.contains($0) }) {
            return .failure(.forbiddenUnicode)
        }
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}"),
              start < end else {
            return .failure(.malformedEnvelope)
        }
        let data = Data(String(s[start...end]).utf8)
        let env = (try? JSONDecoder().decode(LLMEnvelope.self, from: data))
            ?? LLMEnvelope(intent: "new_content", text: "")
        return .success(env)
    }
}
