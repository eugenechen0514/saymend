import Foundation

public enum PolishOutcome: Equatable, Sendable {
    case polished(String)
    case degraded(reason: String)
}

public protocol PolishServing {
    func polish(utteranceRaw: String) async -> PolishOutcome
}

/// 潤飾管線（規格 §3.2 階段二）：組 prompt → LLM（3 秒硬逾時）→ 信封解析 → 簡繁保險絲。
/// 任何失敗都回 degraded，呼叫端保留原文（使用者不能白說話）。
public final class PolishService: PolishServing {
    public static let timeout: TimeInterval = 3.0

    private let provider: any LLMProvider
    private let language: () -> OutputLanguage
    private let traditionalize: TraditionalizeGuard?

    public init(provider: any LLMProvider,
                language: @escaping () -> OutputLanguage,
                traditionalize: TraditionalizeGuard?) {
        self.provider = provider
        self.language = language
        self.traditionalize = traditionalize
    }

    public func polish(utteranceRaw: String) async -> PolishOutcome {
        let lang = language()
        let assembler = PromptAssembler(language: lang)
        do {
            let raw = try await provider.complete(
                system: assembler.systemPrompt(),
                user: assembler.userPayload(utteranceRaw: utteranceRaw),
                timeout: Self.timeout
            )
            guard let envelope = EnvelopeParser.parse(raw), !envelope.text.isEmpty else {
                return .degraded(reason: "回應格式不合法")
            }
            var text = envelope.text
            if let guardConverter = traditionalize {
                text = guardConverter.apply(text, language: lang)
            }
            return .polished(text)
        } catch {
            return .degraded(reason: "LLM 呼叫失敗或逾時")
        }
    }
}
