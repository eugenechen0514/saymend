import Foundation

/// 單次 LLM 呼叫的意圖結果（規格 §3.3）
public enum IntentOutcome: Equatable, Sendable {
    case newContent(String)
    case editedSession(String)
    case undo
    case degraded(reason: String)
}

/// LLM 呼叫的目標與語境（M3 設計裁決 7）：
/// targetText＝可被 edit_command 修正的文字（session 全文或使用者選取）；
/// contextBefore/After＝游標（或選取）前後窗口，只作語境不作目標。
public struct IntentContext: Equatable, Sendable {
    public enum Target: Equatable, Sendable { case session, selection }
    public var targetKind: Target
    public var targetText: String
    public var contextBefore: String?
    public var contextAfter: String?
    /// 前景 App 名稱（第 7 層動態上下文，規格 §4.7 FrontAppInfo）
    public var frontAppName: String?
    /// OCR 螢幕參考文字（AX 讀不到前後文時的備援，規格 §4.7 OCRReader）
    public var ocrText: String?

    public init(targetKind: Target = .session, targetText: String = "",
                contextBefore: String? = nil, contextAfter: String? = nil,
                frontAppName: String? = nil, ocrText: String? = nil) {
        self.targetKind = targetKind
        self.targetText = targetText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.frontAppName = frontAppName
        self.ocrText = ocrText
    }

    public static func session(_ text: String) -> IntentContext {
        IntentContext(targetKind: .session, targetText: text)
    }
    public static func selection(_ text: String, before: String? = nil, after: String? = nil) -> IntentContext {
        IntentContext(targetKind: .selection, targetText: text, contextBefore: before, contextAfter: after)
    }
}

public protocol IntentServing {
    func process(utteranceRaw: String, context: IntentContext) async -> IntentOutcome
}

/// 意圖分類＋產文合併呼叫（規格 §3.3／§4.3）。任何失敗都回 degraded——使用者不能白說話。
public final class IntentService: IntentServing {
    /// 無既有內容＝純潤飾：3 秒；有既有內容＝可能是修正：6 秒（規格 §4.3）
    public static let polishTimeout: TimeInterval = 3.0
    public static let editTimeout: TimeInterval = 6.0

    private let provider: any LLMProvider
    private let language: () -> OutputLanguage
    private let traditionalize: TraditionalizeGuard?
    private let sources: () -> PromptLayerSources

    public init(provider: any LLMProvider,
                language: @escaping () -> OutputLanguage,
                traditionalize: TraditionalizeGuard?,
                sources: @escaping () -> PromptLayerSources = { PromptLayerSources() }) {
        self.provider = provider
        self.language = language
        self.traditionalize = traditionalize
        self.sources = sources
    }

    public func process(utteranceRaw: String, context: IntentContext) async -> IntentOutcome {
        let lang = language()
        let assembler = PromptAssembler(language: lang, sources: sources())
        let timeout = context.targetText.isEmpty ? Self.polishTimeout : Self.editTimeout
        do {
            let raw = try await provider.complete(
                system: assembler.systemPrompt(),
                user: assembler.userPayload(utteranceRaw: utteranceRaw, context: context),
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
                // 防禦：空目標不可能有修正對象；空全文視同格式不合法
                guard !context.targetText.isEmpty, !envelope.text.isEmpty else {
                    return .degraded(reason: "修正指令不成立")
                }
                return .editedSession(guarded(envelope.text))
            case "undo":
                guard !context.targetText.isEmpty else { return .degraded(reason: "無可復原內容") }
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
