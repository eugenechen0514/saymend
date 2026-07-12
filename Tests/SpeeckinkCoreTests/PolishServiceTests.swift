import Foundation
import Testing
@testable import SpeeckinkCore

final class ScriptedProvider: LLMProvider {
    enum Script { case reply(String), fail }
    var script: Script
    var lastSystem: String?
    var lastTimeout: TimeInterval?
    init(_ script: Script) { self.script = script }
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        lastSystem = system
        lastTimeout = timeout
        switch script {
        case .reply(let s): return s
        case .fail: throw LLMError.badStatus(500)
        }
    }
}

@Test func polishedHappyPath() async {
    let p = ScriptedProvider(.reply(#"{"intent":"new_content","text":"你好。"}"#))
    let svc = PolishService(provider: p, language: { .followSpeech }, traditionalize: nil)
    let out = await svc.polish(utteranceRaw: "呃你好")
    #expect(out == .polished("你好。"))
    #expect(p.lastTimeout == PolishService.timeout)
    #expect(p.lastSystem?.contains("只整理、不回答") == true)
}

@Test func providerFailureDegrades() async {
    let svc = PolishService(provider: ScriptedProvider(.fail), language: { .zhTW }, traditionalize: nil)
    let out = await svc.polish(utteranceRaw: "x")
    guard case .degraded = out else { Issue.record("應降級"); return }
}

@Test func garbageResponseDegrades() async {
    let svc = PolishService(provider: ScriptedProvider(.reply("not json")), language: { .zhTW }, traditionalize: nil)
    let out = await svc.polish(utteranceRaw: "x")
    guard case .degraded = out else { Issue.record("應降級"); return }
}

@Test func emptyTextDegrades() async {
    let svc = PolishService(provider: ScriptedProvider(.reply(#"{"intent":"new_content","text":""}"#)), language: { .zhTW }, traditionalize: nil)
    let out = await svc.polish(utteranceRaw: "x")
    guard case .degraded = out else { Issue.record("應降級"); return }
}

@Test func zhTWGetsTraditionalizeGuard() async throws {
    let p = ScriptedProvider(.reply(#"{"intent":"new_content","text":"干净"}"#))
    let svc = PolishService(provider: p, language: { .zhTW }, traditionalize: try TraditionalizeGuard())
    let out = await svc.polish(utteranceRaw: "x")
    #expect(out == .polished("乾淨"))
}
