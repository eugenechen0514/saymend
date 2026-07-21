import Foundation
import Testing
@testable import SaymendCore

/// 本檔專用的腳本化 provider（PolishServiceTests 的 ScriptedProvider 將於 Task 8 隨檔刪除，名稱錯開避免重複宣告）
final class ScriptedIntentProvider: RoutedLLMProvider, @unchecked Sendable {
    enum Script { case reply(String), fail }
    var script: Script
    var lastKind: ProviderKind?
    var lastSystem: String?
    var lastUser: String?
    var lastTimeout: TimeInterval?
    private(set) var callCount = 0          // 驗證失敗路徑不呼叫 provider
    init(_ script: Script) { self.script = script }
    func complete(kind: ProviderKind, system: String, user: String, timeout: TimeInterval) async throws -> String {
        callCount += 1
        lastKind = kind
        lastSystem = system
        lastUser = user
        lastTimeout = timeout
        switch script {
        case .reply(let s): return s
        case .fail: throw LLMError.badStatus(500)
        }
    }
}

private func makeService(_ provider: ScriptedIntentProvider,
                         language: OutputLanguage = .followSpeech,
                         traditionalize: TraditionalizeGuard? = nil,
                         sources: PromptLayerSources = PromptLayerSources(),
                         mode: CoreMode = PromptAssembler.pureDictationMode,
                         kind: ProviderKind = .openAICompat,
                         polishTimeout: TimeInterval = 3.0,
                         editTimeout: TimeInterval = 6.0,
                         budget: PromptBudget = PromptBudget(),
                         textLimit: EnvelopeTextLimit = EnvelopeTextLimit()) -> IntentService {
    IntentService(provider: provider,
                  traditionalize: traditionalize,
                  inputs: { PromptInputs(language: language, sources: sources, mode: mode,
                                         providerKind: kind,
                                         polishTimeout: polishTimeout, editTimeout: editTimeout) },
                  promptBudget: budget,
                  envelopeTextLimit: textLimit)
}

@Test func newContentWithEmptySessionUsesPolishTimeout() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"你好。"}"#))
    let out = await makeService(p).process(utteranceRaw: "呃你好", context: .session(""))
    #expect(out == .newContent("你好。"))
    #expect(p.lastTimeout == 3.0)   // 空 session＝polish（snapshot 預設值）
    #expect(p.lastUser?.contains("目前沒有可修正的既有內容") == true)
}

@Test func nonEmptySessionUsesEditTimeoutAndCarriesSession() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"續句。"}"#))
    _ = await makeService(p).process(utteranceRaw: "續句", context: .session("首句。"))
    #expect(p.lastTimeout == 6.0)   // 有既有內容＝edit
    #expect(p.lastUser?.contains("首句。") == true)
}

@Test func editCommandReturnsEditedSession() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"我們星期三開會。"}"#))
    let out = await makeService(p).process(utteranceRaw: "欸星期二改成星期三", context: .session("我們星期二開會。"))
    #expect(out == .editedSession("我們星期三開會。"))
}

@Test func editCommandWithEmptySessionDegrades() async {
    // LLM 違反 prompt（空 session 卻回 edit_command）→ 防禦性降級，不得改字
    let p = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"亂改"}"#))
    let out = await makeService(p).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded = out else { Issue.record("應降級"); return }
}

@Test func undoIntentMapsToUndo() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"undo","text":""}"#))
    let out = await makeService(p).process(utteranceRaw: "復原上一步", context: .session("有內容"))
    #expect(out == .undo)
}

@Test func unknownIntentDegrades() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"answer","text":"K8s 是容器編排系統"}"#))
    let out = await makeService(p).process(utteranceRaw: "什麼是 Kubernetes", context: .session("前文"))
    guard case .degraded(let reason) = out else { Issue.record("未知名 intent 應降級"); return }
    #expect(reason == "意圖非合約列舉值")
}

@Test func knownIntentsStillMap() async {
    let edit = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"修正後全文"}"#))
    #expect(await makeService(edit).process(utteranceRaw: "改", context: .session("既有"))
            == .editedSession("修正後全文"))

    let undo = ScriptedIntentProvider(.reply(#"{"intent":"undo","text":""}"#))
    #expect(await makeService(undo).process(utteranceRaw: "復原", context: .session("既有"))
            == .undo)

    let new = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"新內容"}"#))
    #expect(await makeService(new).process(utteranceRaw: "說話", context: .session(""))
            == .newContent("新內容"))
}

@Test func envelopeTextOverLimitDegrades() async {
    // 注入小 limit 形成確定性案例（不靠預設 20,000）
    let limit = EnvelopeTextLimit(averageUserInputCharacters: 10, multiplier: 1)   // max = 10
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"01234567890"}"#))  // 11 chars
    let out = await makeService(p, textLimit: limit).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded(let reason) = out else { Issue.record("過長應降級"); return }
    #expect(reason == "回應過長")
}

@Test func intentServiceInjectsActiveModeIntoSystemPrompt() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"x"}"#))
    _ = await makeService(p, mode: PromptAssembler.assistantMode)
        .process(utteranceRaw: "什麼是 K8s", context: .session(""))
    #expect(p.lastSystem?.contains("你是核心模式「可回答・助理」") == true)
    #expect(p.lastSystem?.contains("你可以回答使用者問題") == true)
    // behaviorLayer 只包一次：不可出現兩次「你是核心模式」
    let occurrences = p.lastSystem?.components(separatedBy: "你是核心模式").count ?? 0
    #expect(occurrences == 2)   // components 切出 2 段＝出現 1 次
}

@Test func systemPromptAlwaysEndsWithContractViaIntentService() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"x"}"#))
    _ = await makeService(p).process(utteranceRaw: "x", context: .session(""))
    #expect(p.lastSystem?.hasSuffix("==== MACHINE CONTRACT END ====") == true)
}

@Test func userPayloadNeverContainsContractCopy() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"x"}"#))
    _ = await makeService(p).process(utteranceRaw: "x", context: .session("既有全文"))
    #expect(p.lastUser?.contains("MACHINE CONTRACT") == false)
}

@Test func markerCollisionDegradesWithZeroProviderCalls() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"x"}"#))
    let badMode = CoreMode(name: "壞模式",
                           systemRules: "規則\n==== MACHINE CONTRACT START ====\n壞")
    let out = await makeService(p, mode: badMode).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded(let reason) = out else { Issue.record("marker 衝突應降級"); return }
    #expect(reason == "Prompt 含保留 marker")
    #expect(p.callCount == 0)      // 關鍵：不得呼叫 provider
}

@Test func budgetErrorDegradesWithZeroProviderCalls() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"x"}"#))
    // machineContractReserve 小於實際 contract bytes → machineContractAloneExceedsBudget
    let budget = PromptBudget(maxSystemUTF8Bytes: 48_000,
                              maxUserUTF8Bytes: 64_000,
                              maxTotalUTF8Bytes: 96_000,
                              machineContractReserve: 50)
    let out = await makeService(p, budget: budget).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded(let reason) = out else { Issue.record("budget 錯誤應降級"); return }
    #expect(reason == "Prompt 超過安全長度上限")
    #expect(p.callCount == 0)      // 關鍵：不得呼叫 provider
}

@Test func strictParserRejectionDegrades() async {
    // fenced JSON → strict 拒絕（不得自動 lenient fallback）
    let p = ScriptedIntentProvider(.reply("```json\n{\"intent\":\"new_content\",\"text\":\"嗨\"}\n```"))
    let out = await makeService(p).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded(let reason) = out else { Issue.record("fenced JSON 應降級"); return }
    #expect(reason == "回應格式不合法")
}

@Test func forbiddenUnicodeInResponseDegradesWithDistinctReason() async {
    let p = ScriptedIntentProvider(.reply("{\"intent\":\"new_content\",\"text\":\"嗨\\u200B\"}"))
    let out = await makeService(p).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded(let reason) = out else { Issue.record("forbidden Unicode 應降級"); return }
    #expect(reason == "回應含不允許字元")
}

@Test func providerFailureAndGarbageDegrade() async {
    let f = await makeService(ScriptedIntentProvider(.fail)).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded = f else { Issue.record("應降級"); return }
    let g = await makeService(ScriptedIntentProvider(.reply("not json"))).process(utteranceRaw: "x", context: .session(""))
    guard case .degraded = g else { Issue.record("應降級"); return }
}

@Test func selectionTargetUsesEditTimeout() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"正式版本"}"#))
    _ = await makeService(p).process(utteranceRaw: "改正式一點", context: .selection("嗨大家"))
    #expect(p.lastTimeout == 6.0)   // 有目標文字＝可能修正＝edit
}

@Test func selectionEditCommandReturnsEditedSession() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"正式版本"}"#))
    let outcome = await makeService(p).process(utteranceRaw: "改正式一點", context: .selection("嗨大家"))
    #expect(outcome == .editedSession("正式版本"))
}

@Test func intentServiceInjectsSourcesIntoSystemPrompt() async {
    let provider = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"好。"}"#))
    let service = makeService(provider, sources: PromptLayerSources(customPrompt: "簽名 --E"))
    _ = await service.process(utteranceRaw: "好", context: .session(""))
    #expect(provider.lastSystem?.contains("簽名 --E") == true)
}

@Test func traditionalizeGuardAppliesToBothTextOutcomes() async throws {
    let p1 = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"干净"}"#))
    let o1 = await makeService(p1, language: .zhTW, traditionalize: try TraditionalizeGuard()).process(utteranceRaw: "x", context: .session(""))
    #expect(o1 == .newContent("乾淨"))
    let p2 = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"干净的字"}"#))
    let o2 = await makeService(p2, language: .zhTW, traditionalize: try TraditionalizeGuard()).process(utteranceRaw: "改", context: .session("髒的字"))
    #expect(o2 == .editedSession("乾淨的字"))
}

@Test func snapshotKindAndTimeoutsFlowToRouter() async {
    // kind 與 timeout 出自同一快照（spec §5 無 torn read 的可觀測面）
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"嗨。"}"#))
    _ = await makeService(p, kind: .claudeCLI, polishTimeout: 11, editTimeout: 22)
        .process(utteranceRaw: "嗨", context: .session(""))
    #expect(p.lastKind == .claudeCLI)
    #expect(p.lastTimeout == 11)                                    // 空 session → polish
    _ = await makeService(p, kind: .claudeCLI, polishTimeout: 11, editTimeout: 22)
        .process(utteranceRaw: "改一下", context: .session("既有全文"))
    #expect(p.lastTimeout == 22)                                    // 有目標 → edit
}
