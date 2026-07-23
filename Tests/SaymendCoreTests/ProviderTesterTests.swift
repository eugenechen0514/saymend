import Foundation
import Testing
@testable import SaymendCore

/// 腳本化 routed provider：可回應、可拋錯、可注入延遲
final class ScriptedTesterProvider: RoutedLLMProvider, @unchecked Sendable {
    enum Script { case reply(String), failWith(any Error) }
    var script: Script
    var delay: Duration = .zero
    private(set) var lastSystem: String?
    private(set) var lastUser: String?
    private(set) var lastTimeout: TimeInterval?
    init(_ script: Script) { self.script = script }
    func complete(kind: ProviderKind, system: String, user: String,
                  timeout: TimeInterval) async throws -> String {
        lastSystem = system; lastUser = user; lastTimeout = timeout
        if delay > .zero { try? await Task.sleep(for: delay) }
        switch script {
        case .reply(let s): return s
        case .failWith(let e): throw e
        }
    }
}

@Test func healthyProviderYieldsOKWithLatency() async {
    let p = ScriptedTesterProvider(.reply(#"{"intent":"new_content","text":"今天天氣很好，我想去公園走走。"}"#))
    let report = await ProviderTester(provider: p).run(kind: .openAICompat, polishTimeout: 3)
    #expect(report.verdict == .ok)
    #expect(report.latency != nil)
    #expect(report.exceedsPolishTimeout == false)
    #expect(p.lastTimeout == ProviderTester.testTimeout)          // 測試上限 120s、非 polishTimeout
    #expect(p.lastUser?.contains(ProviderTester.sampleUtterance) == true)   // 真實 PromptAssembler 組裝
    #expect(p.lastSystem?.isEmpty == false)
}

@Test func slowProviderTriggersTimeoutWarning() async {
    let p = ScriptedTesterProvider(.reply(#"{"intent":"new_content","text":"好。"}"#))
    p.delay = .milliseconds(80)
    let report = await ProviderTester(provider: p).run(kind: .openAICompat, polishTimeout: 0.05)
    #expect(report.verdict == .ok)
    #expect(report.exceedsPolishTimeout == true)                  // 延遲 > polishTimeout → 警告
}

@Test func emptyShellProviderFailsEnvelopeVerdict() async {
    let p = ScriptedTesterProvider(.reply("好的，這是回應"))          // 非 JSON 信封（1min-openai 空殼型）
    let report = await ProviderTester(provider: p).run(kind: .openAICompat, polishTimeout: 3)
    guard case .badEnvelope = report.verdict else { Issue.record("應為 badEnvelope"); return }
    #expect(report.latency != nil)                                // 連上了、量得到延遲
}

@Test func invalidIntentFailsEnvelopeVerdict() async {
    let p = ScriptedTesterProvider(.reply(#"{"intent":"answer","text":"42"}"#))
    let report = await ProviderTester(provider: p).run(kind: .openAICompat, polishTimeout: 3)
    #expect(report.verdict == .badEnvelope("意圖非合約列舉值"))
}

@Test func transportFailureUsesSharedReasonVocabulary() async {
    let p = ScriptedTesterProvider(.failWith(LLMError.badStatus(401)))
    let report = await ProviderTester(provider: p).run(kind: .openAICompat, polishTimeout: 3)
    #expect(report.verdict == .failed("HTTP 401"))                // 與 §3.3 同語彙（共用 helper）
    #expect(report.latency == nil)
}
