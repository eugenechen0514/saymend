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
        // 4. 必須是單一 JSON 物件：前後不得有任何贅字，且只能有一組大括號
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else {
            return .failure(.malformedEnvelope)
        }
        let openCount = trimmed.filter { $0 == "{" }.count
        let closeCount = trimmed.filter { $0 == "}" }.count
        guard openCount == 1, closeCount == 1 else {
            return .failure(.malformedEnvelope)
        }
        // 5. 不可含 fenced JSON 圍欄
        guard !trimmed.contains("```") else {
            return .failure(.malformedEnvelope)
        }

        // 6. 嚴格解碼：JSONDecoder 會忽略多餘欄位，所以自己驗 top-level key set
        guard let topKeys = topLevelKeys(in: trimmed), topKeys == Set(["intent", "text"]) else {
            return .failure(.missingOrExtraFields)
        }

        let data = Data(trimmed.utf8)
        do {
            let env = try JSONDecoder().decode(LLMEnvelope.self, from: data)
            // 7. 二次掃描 decoded 值內的 forbidden（防 JSON escape，如 ​ 繞過 raw 掃描）
            if env.intent.unicodeScalars.contains(where: { reservedScalars.contains($0) })
                || env.text.unicodeScalars.contains(where: { reservedScalars.contains($0) }) {
                return .failure(.forbiddenUnicode)
            }
            return .success(env)
        } catch {
            return .failure(.malformedEnvelope)
        }
    }

    /// top-level key set：交給 JSONSerialization 解析後直接取 dictionary keys，
    /// 避免手寫 tokenizer 重造 JSON 解析容易出的 depth 追蹤錯誤。
    private static func topLevelKeys(in json: String) -> Set<String>? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else { return nil }
        return Set(dict.keys)
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
