import AVFoundation
import Foundation
import Testing
@testable import SaymendCore

/// 假辨識器：以旗標控制回傳／擲錯，並記錄引擎傳進來的參數。
private final class FakeTranscriber: WhisperTranscribing, @unchecked Sendable {
    let lock = NSLock()
    var result = "整段本機辨識結果"
    var loadError: WhisperLoadError?
    var transcribeError: Error?
    private(set) var seenPhrases: [String] = []
    private(set) var seenModelPath: URL?
    private(set) var seenLanguage: String?
    private(set) var preloadCount = 0
    private(set) var transcribeCount = 0

    func preload(modelPath: URL) async {
        lock.lock(); preloadCount += 1; lock.unlock()
    }

    func transcribe(modelPath: URL, samples: [Float], language: String,
                    promptPhrases: [String]) async throws -> String {
        lock.lock()
        seenPhrases = promptPhrases
        seenModelPath = modelPath
        seenLanguage = language
        transcribeCount += 1
        lock.unlock()
        if let loadError { throw loadError }
        if let transcribeError { throw transcribeError }
        return result
    }
}

/// 可控暫停的假辨識器：辨識進到中途發 entered 訊號、等 release 才回傳。
private final class GatedFake: WhisperTranscribing, @unchecked Sendable {
    let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    var onEntered: (@Sendable () -> Void)?
    /// 放行後改以擲錯收場（驗取消時不得吐 .failed）
    var errorAfterRelease: Error?

    func preload(modelPath: URL) async {}

    func transcribe(modelPath: URL, samples: [Float], language: String,
                    promptPhrases: [String]) async throws -> String {
        await withCheckedContinuation { c in
            lock.lock(); cont = c; lock.unlock()
            onEntered?()
        }
        if let errorAfterRelease { throw errorAfterRelease }
        return "遲到結果"
    }

    func release() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}

private func chunk16k(_ f: Int = 1600) -> AudioChunk {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                            channels: 1, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f))!
    b.frameLength = AVAudioFrameCount(f)
    for i in 0..<f { b.floatChannelData![0][i] = 0.1 }
    return AudioChunk(buffer: b)
}

/// 餵一段音訊、結束串流，收集引擎吐出的所有事件
private func drive(_ e: WhisperKitEngine) async -> [TranscriptEvent] {
    let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
    c.yield(chunk16k())
    c.finish()
    var evs: [TranscriptEvent] = []
    for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
    return evs
}

private func engine(_ f: any WhisperTranscribing,
                    path: URL? = URL(filePath: "/tmp/m")) -> WhisperKitEngine {
    WhisperKitEngine(transcriber: f,
                     configProvider: { WhisperLocalConfig(selectedModelPath: path, extraScanRoots: []) })
}

@Suite struct WhisperKitEngineTests {
    @Test func transcribingThenFinalized() async {
        let f = FakeTranscriber()
        let evs = await drive(engine(f))
        #expect(evs.contains(.transcribing))
        #expect(evs.last == .finalized("整段本機辨識結果"))
        #expect(f.seenModelPath == URL(filePath: "/tmp/m"))
    }

    @Test func failsWhenNoModel() async {
        #expect(await drive(engine(FakeTranscriber(), path: nil)).last == .failed(reason: "未選擇本機模型"))
    }

    @Test func failsOnLoadError() async {
        let f = FakeTranscriber()
        f.loadError = WhisperLoadError(message: "x")
        #expect(await drive(engine(f)).last == .failed(reason: "模型載入失敗"))
    }

    @Test func failsOnTranscribeError() async {
        let f = FakeTranscriber()
        f.transcribeError = NSError(domain: "x", code: 1)
        #expect(await drive(engine(f)).last == .failed(reason: "辨識失敗"))
    }

    @Test func failsOnEmpty() async {
        let f = FakeTranscriber()
        f.result = "   "
        #expect(await drive(engine(f)).last == .failed(reason: "辨識結果為空"))
    }

    @Test func passesBias() async {
        let f = FakeTranscriber()
        let e = engine(f)
        e.contextualStrings = { ["術語A", "術語B"] }
        _ = await drive(e)
        #expect(f.seenPhrases == ["術語A", "術語B"])
    }

    @Test func preloadForwards() async {
        let f = FakeTranscriber()
        await engine(f).preload()
        #expect(f.preloadCount == 1)
    }

    /// REV #3：偏置讀取（MainActor 往返）期間被取消 → 根本不該進辨識
    @Test func cancelBeforeTranscribeSkipsTranscriber() async {
        let f = FakeTranscriber()
        let e = engine(f)
        e.contextualStrings = { [weak e] in e?.cancel(); return [] }   // 讀偏置的當下取消
        let evs = await drive(e)
        #expect(f.transcribeCount == 0)
        #expect(!evs.contains { if case .finalized = $0 { return true }; return false })
    }

    /// REV #3：辨識中被取消，之後才擲錯 → 不得吐 .failed（取消不是失敗）
    @Test func cancelDuringTranscribeSuppressesFailure() async {
        let f = GatedFake()
        f.errorAfterRelease = NSError(domain: "x", code: 1)
        let e = engine(f)
        let (entered, enteredC) = AsyncStream.makeStream(of: Void.self)
        f.onEntered = { enteredC.yield(()) }
        let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
        c.yield(chunk16k())
        c.finish()
        let collector = Task {
            var evs: [TranscriptEvent] = []
            for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
            return evs
        }
        var it = entered.makeAsyncIterator()
        _ = await it.next()
        e.cancel()
        f.release()
        let evs = await collector.value
        #expect(!evs.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func cancelDuringTranscribeEmitsNoFinalized() async {
        let f = GatedFake()
        let e = engine(f)
        let (entered, enteredC) = AsyncStream.makeStream(of: Void.self)
        f.onEntered = { enteredC.yield(()) }
        let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
        c.yield(chunk16k())
        c.finish()
        let collector = Task {
            var evs: [TranscriptEvent] = []
            for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
            return evs
        }
        var it = entered.makeAsyncIterator()
        _ = await it.next()                   // 等 transcribe 進入
        e.cancel()
        f.release()
        let evs = await collector.value
        #expect(!evs.contains(.finalized("遲到結果")))
    }
}
