import Foundation
import Testing
@testable import SpeeckinkCore

/// 本檔專用的腳本化 provider（PolishServiceTests 的 ScriptedProvider 將於 Task 8 隨檔刪除，名稱錯開避免重複宣告）
final class ScriptedIntentProvider: LLMProvider {
    enum Script { case reply(String), fail }
    var script: Script
    var lastSystem: String?
    var lastUser: String?
    var lastTimeout: TimeInterval?
    init(_ script: Script) { self.script = script }
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
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
                         traditionalize: TraditionalizeGuard? = nil) -> IntentService {
    IntentService(provider: provider, language: { language }, traditionalize: traditionalize)
}

@Test func newContentWithEmptySessionUsesPolishTimeout() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"你好。"}"#))
    let out = await makeService(p).process(utteranceRaw: "呃你好", context: .session(""))
    #expect(out == .newContent("你好。"))
    #expect(p.lastTimeout == IntentService.polishTimeout)   // 3 秒
    #expect(p.lastUser?.contains("目前沒有可修正的既有內容") == true)
}

@Test func nonEmptySessionUsesEditTimeoutAndCarriesSession() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"續句。"}"#))
    _ = await makeService(p).process(utteranceRaw: "續句", context: .session("首句。"))
    #expect(p.lastTimeout == IntentService.editTimeout)     // 6 秒
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

@Test func unknownIntentFallsBackToNewContent() async {
    // 意圖模糊／未知一律當新內容（規格 §3.3）
    let p = ScriptedIntentProvider(.reply(#"{"intent":"question","text":"嗨"}"#))
    let out = await makeService(p).process(utteranceRaw: "嗨", context: .session("前文"))
    #expect(out == .newContent("嗨"))
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
    #expect(p.lastTimeout == IntentService.editTimeout)   // 有目標文字＝可能修正＝6s
}

@Test func selectionEditCommandReturnsEditedSession() async {
    let p = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"正式版本"}"#))
    let outcome = await makeService(p).process(utteranceRaw: "改正式一點", context: .selection("嗨大家"))
    #expect(outcome == .editedSession("正式版本"))
}

@Test func traditionalizeGuardAppliesToBothTextOutcomes() async throws {
    let p1 = ScriptedIntentProvider(.reply(#"{"intent":"new_content","text":"干净"}"#))
    let o1 = await makeService(p1, language: .zhTW, traditionalize: try TraditionalizeGuard()).process(utteranceRaw: "x", context: .session(""))
    #expect(o1 == .newContent("乾淨"))
    let p2 = ScriptedIntentProvider(.reply(#"{"intent":"edit_command","text":"干净的字"}"#))
    let o2 = await makeService(p2, language: .zhTW, traditionalize: try TraditionalizeGuard()).process(utteranceRaw: "改", context: .session("髒的字"))
    #expect(o2 == .editedSession("乾淨的字"))
}
