import Foundation
import Testing
@testable import SaymendCore

/// 可辨識身分的假引擎
final class SpyASREngine: ASREngine, ContextBiasable, @unchecked Sendable {
    let name: String
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var lastLocale: String?
    var contextualStrings: (@MainActor () -> [String])?
    init(name: String) { self.name = name }
    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        startCount += 1
        lastLocale = localeIdentifier
        return AsyncStream { c in c.yield(.finalized(name)); c.finish() }
    }
    func cancel() { cancelCount += 1 }
}

private func drain(_ stream: AsyncStream<TranscriptEvent>) async -> [TranscriptEvent] {
    var out: [TranscriptEvent] = []
    for await e in stream { out.append(e) }
    return out
}

@Test func routerDispatchesToSelectedEngine() async {
    let sa = SpyASREngine(name: "speechAnalyzer")
    let wr = SpyASREngine(name: "whisperRemote")
    let wl = SpyASREngine(name: "whisperLocal")
    var kind = ASREngineKind.speechAnalyzer
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { kind })

    let (a1, c1) = AsyncStream.makeStream(of: AudioChunk.self); c1.finish()
    #expect(await drain(router.start(audio: a1, localeIdentifier: "zh-TW")) == [.finalized("speechAnalyzer")])
    #expect(sa.startCount == 1 && wr.startCount == 0)

    kind = .whisperRemote
    let (a2, c2) = AsyncStream.makeStream(of: AudioChunk.self); c2.finish()
    #expect(await drain(router.start(audio: a2, localeIdentifier: "zh-TW")) == [.finalized("whisperRemote")])
    #expect(wr.startCount == 1)
}

@Test func routerCancelOnlyHitsActiveEngine() async {
    let sa = SpyASREngine(name: "sa")
    let wr = SpyASREngine(name: "wr")
    let wl = SpyASREngine(name: "wl")
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { .whisperRemote })
    let (a, c) = AsyncStream.makeStream(of: AudioChunk.self); c.finish()
    _ = await drain(router.start(audio: a, localeIdentifier: "zh-TW"))
    router.cancel()
    #expect(wr.cancelCount == 1)
    #expect(sa.cancelCount == 0)          // 未選定的引擎不受影響
}

@Test func routerCancelBeforeAnyStartIsNoOp() {
    let sa = SpyASREngine(name: "sa")
    let wr = SpyASREngine(name: "wr")
    let wl = SpyASREngine(name: "wl")
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { .speechAnalyzer })
    router.cancel()                        // 尚未 start：不得 crash、不得誤打任一引擎
    #expect(sa.cancelCount == 0 && wr.cancelCount == 0)
}

@Test func routerSnapshotsKindAtStartNotAtCancel() async {
    let sa = SpyASREngine(name: "sa")
    let wr = SpyASREngine(name: "wr")
    let wl = SpyASREngine(name: "wl")
    var kind = ASREngineKind.whisperRemote
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { kind })
    let (a, c) = AsyncStream.makeStream(of: AudioChunk.self); c.finish()
    _ = await drain(router.start(audio: a, localeIdentifier: "zh-TW"))
    kind = .speechAnalyzer                 // session 進行中改設定
    router.cancel()
    #expect(wr.cancelCount == 1)           // cancel 仍打到 start 當下選定的引擎
    #expect(sa.cancelCount == 0)
}

@MainActor
@Test func routerForwardsContextualStringsToActiveEngine() async {
    let sa = SpyASREngine(name: "sa")
    let wr = SpyASREngine(name: "wr")
    let wl = SpyASREngine(name: "wl")
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { .whisperRemote })
    router.contextualStrings = { ["術語"] }
    let (a, c) = AsyncStream.makeStream(of: AudioChunk.self); c.finish()
    _ = await drain(router.start(audio: a, localeIdentifier: "zh-TW"))
    #expect(wr.contextualStrings?() == ["術語"])   // 轉發到選定引擎
    #expect(sa.contextualStrings == nil)
}

@Test func routerPassesLocaleThrough() async {
    let sa = SpyASREngine(name: "sa")
    let wr = SpyASREngine(name: "wr")
    let wl = SpyASREngine(name: "wl")
    let router = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                                kindProvider: { .speechAnalyzer })
    let (a, c) = AsyncStream.makeStream(of: AudioChunk.self); c.finish()
    _ = await drain(router.start(audio: a, localeIdentifier: "en-US"))
    #expect(sa.lastLocale == "en-US")
}

@Test func routesWhisperLocal() async {
    let sa = SpyASREngine(name: "speechAnalyzer")
    let wr = SpyASREngine(name: "whisperRemote")
    let wl = SpyASREngine(name: "whisperLocal")
    let r = ASREngineRouter(speechAnalyzer: sa, whisperRemote: wr, whisperLocal: wl,
                            kindProvider: { .whisperLocal })
    let (st, c) = AsyncStream.makeStream(of: AudioChunk.self); c.finish()
    _ = await drain(r.start(audio: st, localeIdentifier: "zh-TW"))
    #expect(wl.startCount == 1)
    #expect(sa.startCount == 0 && wr.startCount == 0)
}
