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
