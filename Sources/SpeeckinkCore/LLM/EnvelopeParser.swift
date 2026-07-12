import Foundation

/// LLM 回應的 JSON 信封（規格 §3.3）。M1 只用 text；intent 供 M2 意圖分流。
public struct LLMEnvelope: Decodable, Equatable, Sendable {
    public let intent: String
    public let text: String

    public init(intent: String, text: String) {
        self.intent = intent
        self.text = text
    }
}

public enum EnvelopeParser {
    /// 從 LLM 原始回應抽出 JSON 信封：取第一個 `{` 到最後一個 `}`，
    /// 自然容忍 ```json 圍欄與前後贅語。解析失敗回 nil（上游降級，規格 §4.3）。
    public static func parse(_ raw: String) -> LLMEnvelope? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let data = Data(String(raw[start...end]).utf8)
        return try? JSONDecoder().decode(LLMEnvelope.self, from: data)
    }
}
