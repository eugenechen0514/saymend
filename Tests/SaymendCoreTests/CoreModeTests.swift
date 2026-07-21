import Foundation
import Testing
@testable import SaymendCore

@Test func coreModeInitializerAndEquality() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let m = CoreMode(id: "abc", name: "我的模式", systemRules: "請回答問題",
                     updatedAt: now, isBuiltin: false)
    #expect(m.id == "abc")
    #expect(m.name == "我的模式")
    #expect(m.systemRules == "請回答問題")
    #expect(m.updatedAt == now)
    #expect(m.isBuiltin == false)
}

@Test func coreModeUUIDIsStable() {
    let a = PromptAssembler.pureDictationMode
    let b = PromptAssembler.pureDictationMode
    #expect(a.id == b.id)
    #expect(a.id == "00000000-0000-4000-8000-000000000001")
}

@Test func builtinModesAreFlaggedAsBuiltin() {
    for m in PromptAssembler.builtinCoreModes {
        #expect(m.isBuiltin == true)
    }
}

@Test func builtinDefaultModeIDPointsToPureDictation() {
    #expect(PromptAssembler.builtinDefaultModeID == PromptAssembler.pureDictationMode.id)
}

@Test func enforcesNoAnswerCustomGuardMatchesM4Stance() {
    #expect(PromptAssembler.pureDictationMode.enforcesNoAnswerCustomGuard == true)
    #expect(PromptAssembler.verbatimTranscriptMode.enforcesNoAnswerCustomGuard == true)
    #expect(PromptAssembler.conciseFormalRewriteMode.enforcesNoAnswerCustomGuard == true)
    #expect(PromptAssembler.assistantMode.enforcesNoAnswerCustomGuard == false)
}

@Test func goldenFixtureLoadsAllFourLanguages() {
    #expect(GoldenDefaultFixture.all.count == 4)
}

@Test(arguments: GoldenDefaultFixture.all)
func goldenBaselineMatchesDefaultBuiltInMode(fixture: GoldenDefaultFixture) {
    #expect(PromptAssembler.pureDictationMode.systemRules == fixture.legacyCoreRules)
}
