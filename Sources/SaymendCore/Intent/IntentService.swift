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

/// envelope.text 上限（規格 §6.4）：預設 20,000 個 Swift Character。可注入供測試構造確定性案例。
public struct EnvelopeTextLimit: Equatable, Sendable {
    public var averageUserInputCharacters: Int
    public var multiplier: Int

    public init(averageUserInputCharacters: Int = 2_000, multiplier: Int = 10) {
        self.averageUserInputCharacters = averageUserInputCharacters
        self.multiplier = multiplier
    }

    /// production 預設 20,000 個 Swift Character（2,000 × 10）
    public var maxCharacters: Int { averageUserInputCharacters * multiplier }
}

/// 一次取齊的 prompt 輸入快照。App 層負責在同一次 MainActor run、
/// 用同一個 bundleID + profile 產生衍生值——torn read 在構造上不可能發生。
/// providerKind/timeout 同屬本快照（spec §5）：路由與 timeout 出自同一次讀取。
/// 三個 provider 欄位刻意**無預設值**（M5 教訓：預設值＝靜默 footgun）。
public struct PromptInputs: Sendable {
    public let language: OutputLanguage
    public let sources: PromptLayerSources
    public let mode: CoreMode
    public let providerKind: ProviderKind
    public let polishTimeout: TimeInterval
    public let editTimeout: TimeInterval

    public init(language: OutputLanguage, sources: PromptLayerSources, mode: CoreMode,
                providerKind: ProviderKind, polishTimeout: TimeInterval, editTimeout: TimeInterval) {
        self.language = language
        self.sources = sources
        self.mode = mode
        self.providerKind = providerKind
        self.polishTimeout = polishTimeout
        self.editTimeout = editTimeout
    }
}

/// 意圖分類＋產文合併呼叫（規格 §3.3／§4.3）。任何失敗都回 degraded——使用者不能白說話。
public final class IntentService: IntentServing {
    /// timeout 值已遷入 AppSettings per-provider 設定（spec §5）；polish/edit 語意（§4.3）
    /// 仍由本類依 context.targetText.isEmpty 決定，值取自快照。

    private let provider: any RoutedLLMProvider
    private let traditionalize: TraditionalizeGuard?
    /// 單一 prompt 輸入解析器（App 端組裝）。標 @MainActor：closure 內部會讀取
    /// App 層 store（詞彙表／profile／sessionLanguageOverride／CoreModeStore）與
    /// NSWorkspace 前景 App，這些都是 MainActor 專屬可變狀態；process() 為
    /// nonisolated async（跑並行 executor），必須跳回 MainActor 才能安全讀取。
    /// 語系／來源／模式三值合併成單一 closure，由同一個 bundleID+profile 衍生，
    /// torn read 在構造上不可能發生（規格 §3.5）。
    private let inputs: @MainActor () -> PromptInputs
    private let promptBudget: PromptBudget
    private let envelopeTextLimit: EnvelopeTextLimit

    public init(provider: any RoutedLLMProvider,
                traditionalize: TraditionalizeGuard?,
                inputs: @escaping @MainActor () -> PromptInputs,
                promptBudget: PromptBudget = PromptBudget(),
                envelopeTextLimit: EnvelopeTextLimit = EnvelopeTextLimit()) {
        self.provider = provider
        self.traditionalize = traditionalize
        self.inputs = inputs
        self.promptBudget = promptBudget
        self.envelopeTextLimit = envelopeTextLimit
    }

    public func process(utteranceRaw: String, context: IntentContext) async -> IntentOutcome {
        let resolveInputs = inputs
        let snapshot: PromptInputs = await MainActor.run { resolveInputs() }

        let assembler = PromptAssembler(language: snapshot.language,
                                        sources: snapshot.sources,
                                        mode: snapshot.mode)

        // provider-bound 唯一入口：任何失敗都在呼叫 provider 之前降級（marker 檢查 →
        // system trim → user trim → total bytes，provider call count 必為 0）。
        let prompt: (system: String, user: String)
        do {
            prompt = try assembler.validatedPrompt(utteranceRaw: utteranceRaw,
                                                   context: context,
                                                   budget: promptBudget)
        } catch is PromptAssemblyError {
            return .degraded(reason: "Prompt 含保留 marker")
        } catch is PromptTooLongError {
            return .degraded(reason: "Prompt 超過安全長度上限")
        } catch {
            return .degraded(reason: "Prompt 組裝失敗")
        }

        let timeout = context.targetText.isEmpty ? snapshot.polishTimeout : snapshot.editTimeout
        let raw: String
        do {
            raw = try await provider.complete(kind: snapshot.providerKind,
                                              system: prompt.system,
                                              user: prompt.user,
                                              timeout: timeout)
        } catch {
            return .degraded(reason: "LLM 呼叫失敗或逾時")
        }

        // strict parser（不得自動 lenient fallback）
        let envelope: LLMEnvelope
        switch EnvelopeParser.parse(raw, mode: .strict) {
        case .success(let e):
            envelope = e
        case .failure(.forbiddenUnicode), .failure(.forbiddenBOM), .failure(.structuralHomoglyph):
            return .degraded(reason: "回應含不允許字元")
        case .failure:
            return .degraded(reason: "回應格式不合法")
        }

        // envelope.text 長度上限（先於 intent mapping；截斷後 JSON 語意與 edit 全文可能不完整，故不截斷）
        guard envelope.text.count <= envelopeTextLimit.maxCharacters else {
            return .degraded(reason: "回應過長")
        }

        let guarded: (String) -> String = { [traditionalize] text in
            traditionalize?.apply(text, language: snapshot.language) ?? text
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
        case "new_content":
            guard !envelope.text.isEmpty else { return .degraded(reason: "回應內容為空") }
            return .newContent(guarded(envelope.text))
        default:
            // M4 漏洞修：未知名 intent 不再吃成 new_content（規格 §3.3 fail-closed）
            return .degraded(reason: "意圖非合約列舉值")
        }
    }
}
