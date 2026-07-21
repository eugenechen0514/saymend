import OpenCC

/// 簡繁保險絲（規格 §4.5）：僅 zh-TW 模式時，把 LLM 偶爾漏出的簡體字確定性轉繁。
public struct TraditionalizeGuard {
    private let converter: ChineseConverter

    public init() throws {
        converter = try ChineseConverter(options: [.traditionalize, .twStandard, .twIdiom])
    }

    public func apply(_ text: String, language: OutputLanguage) -> String {
        guard language == .zhTW else { return text }
        return converter.convert(text)
    }
}
