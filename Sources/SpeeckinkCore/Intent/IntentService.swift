import Foundation

/// 單次 LLM 呼叫的意圖結果（規格 §3.3）
public enum IntentOutcome: Equatable, Sendable {
    case newContent(String)
    case editedSession(String)
    case undo
    case degraded(reason: String)
}

public protocol IntentServing {
    func process(utteranceRaw: String, sessionText: String) async -> IntentOutcome
}

/// 意圖分類＋產文合併呼叫（規格 §3.3／§4.3）。任何失敗都回 degraded——使用者不能白說話。
public final class IntentService: IntentServing {
    /// 無既有內容＝純潤飾：3 秒；有既有內容＝可能是修正：6 秒（規格 §4.3）
    public static let polishTimeout: TimeInterval = 3.0
    public static let editTimeout: TimeInterval = 6.0

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

    public func process(utteranceRaw: String, sessionText: String) async -> IntentOutcome {
        let lang = language()
        let assembler = PromptAssembler(language: lang)
        let timeout = sessionText.isEmpty ? Self.polishTimeout : Self.editTimeout
        do {
            let raw = try await provider.complete(
                system: assembler.systemPrompt(),
                user: assembler.userPayload(utteranceRaw: utteranceRaw, sessionText: sessionText),
                timeout: timeout
            )
            guard let envelope = EnvelopeParser.parse(raw) else {
                return .degraded(reason: "回應格式不合法")
            }
            let guarded: (String) -> String = { [traditionalize] text in
                traditionalize?.apply(text, language: lang) ?? text
            }
            switch envelope.intent {
            case "edit_command":
                // 防禦：空 session 不可能有修正對象；空全文視同格式不合法
                guard !sessionText.isEmpty, !envelope.text.isEmpty else {
                    return .degraded(reason: "修正指令不成立")
                }
                return .editedSession(guarded(envelope.text))
            case "undo":
                guard !sessionText.isEmpty else { return .degraded(reason: "無可復原內容") }
                return .undo
            default:
                // new_content 與未知意圖一律走新內容（意圖模糊→new_content，規格 §3.3）
                guard !envelope.text.isEmpty else { return .degraded(reason: "回應內容為空") }
                return .newContent(guarded(envelope.text))
            }
        } catch {
            return .degraded(reason: "LLM 呼叫失敗或逾時")
        }
    }
}
