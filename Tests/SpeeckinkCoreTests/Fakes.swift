import Foundation
@testable import SpeeckinkCore

final class FakeAudio: AudioCaptureService {
    var levelHandler: ((Float) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var continuation: AsyncStream<AudioChunk>.Continuation?
    func start() throws -> AsyncStream<AudioChunk> {
        startCount += 1
        let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation = cont
        return stream
    }
    func stop() {
        stopCount += 1
        continuation?.finish()
    }
}

final class FakeASR: ASREngine {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var continuation: AsyncStream<TranscriptEvent>.Continuation?
    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        startCount += 1
        let (stream, cont) = AsyncStream.makeStream(of: TranscriptEvent.self)
        continuation = cont
        return stream
    }
    func cancel() {
        cancelCount += 1
        continuation?.finish()
    }
}

/// 可手動放行的假潤飾服務
final class GatedPolisher: PolishServing, @unchecked Sendable {
    var outcome: PolishOutcome = .polished("（潤飾）")
    private(set) var calls: [String] = []
    /// 若設為 false，polish 立即回傳；true 時等 release() 才回
    var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func polish(utteranceRaw: String) async -> PolishOutcome {
        calls.append(utteranceRaw)
        if gated {
            await withCheckedContinuation { waiters.append($0) }
        }
        return outcome
    }
    func release() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class FakeHUD: HUDPresenting {
    private(set) var states: [HUDState] = []
    func present(_ state: HUDState) { states.append(state) }
}

@MainActor
func makeController(
    polisher: GatedPolisher = GatedPolisher(),
    pasteThreshold: Int = 100
) -> (DictationController, FakeAudio, FakeASR, RecordingInserter, GatedPolisher, FakeHUD) {
    let audio = FakeAudio()
    let asr = FakeASR()
    let key = RecordingInserter()
    let paste = RecordingInserter()
    let coordinator = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: pasteThreshold)
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        polisher: polisher, hud: hud, settings: settings
    )
    return (controller, audio, asr, key, polisher, hud)
}
