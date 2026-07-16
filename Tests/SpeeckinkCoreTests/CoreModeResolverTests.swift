import Testing
@testable import SpeeckinkCore

private let builtins = PromptAssembler.builtinCoreModes
private let pureID = PromptAssembler.pureDictationMode.id
private let verbatimID = PromptAssembler.verbatimTranscriptMode.id

@Test func sessionOverrideBeatsPerApp() {
    let r = CoreModeResolver()
    let resolved = r.resolve(
        sessionModeID: verbatimID,
        appModeID: pureID,
        defaultModeID: pureID,
        availableModes: builtins)
    #expect(resolved.id == verbatimID)
}

@Test func perAppBeatsGlobal() {
    let r = CoreModeResolver()
    let resolved = r.resolve(
        sessionModeID: nil,
        appModeID: verbatimID,
        defaultModeID: pureID,
        availableModes: builtins)
    #expect(resolved.id == verbatimID)
}

@Test func globalFallsBackToBuiltInDefault() {
    let r = CoreModeResolver()
    let resolved = r.resolve(
        sessionModeID: nil,
        appModeID: nil,
        defaultModeID: nil,
        availableModes: builtins)
    #expect(resolved.id == PromptAssembler.builtinDefaultModeID)
}

@Test func unknownIDsFallBackToDefault() {
    let r = CoreModeResolver()
    let resolved = r.resolve(
        sessionModeID: "ghost-1",
        appModeID: "ghost-2",
        defaultModeID: "ghost-3",
        availableModes: builtins)
    #expect(resolved.id == PromptAssembler.builtinDefaultModeID)
}
