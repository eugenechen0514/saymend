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

/// 可手動放行的假意圖服務
///
/// release() 與 process() 的登記順序無關（order-independent latch）：因 process 以
/// fire-and-forget Task 派發，其任務體要等主 actor 讓出才起跑，呼叫端（測試）可能在
/// 任務登記 gate *之前* 就呼叫 release()。此時把 release 記入 pendingReleases，待 process
/// 起跑看到額度即直接放行，避免因純值 continuation 尚未登記而永久卡死。
final class GatedIntentService: IntentServing, @unchecked Sendable {
    var outcome: IntentOutcome = .newContent("（潤飾）")
    private(set) var calls: [(raw: String, session: String)] = []
    /// 若設為 false，process 立即回傳；true 時等 release() 才回
    var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReleases = 0
    func process(utteranceRaw: String, sessionText: String) async -> IntentOutcome {
        calls.append((utteranceRaw, sessionText))
        if gated {
            if pendingReleases > 0 {
                pendingReleases -= 1
            } else {
                await withCheckedContinuation { waiters.append($0) }
            }
        }
        return outcome
    }
    func release() {
        if waiters.isEmpty {
            pendingReleases += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 剪貼簿急救 spy（InserterError.lostText 的最後手段）
final class ClipboardSpy {
    private(set) var texts: [String] = []
    func rescue(_ text: String) { texts.append(text) }
}

final class FakeHUD: HUDPresenting {
    private(set) var states: [HUDState] = []
    func present(_ state: HUDState) { states.append(state) }
}

final class FakeFieldReader: FieldContextProviding {
    var context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: nil)
    func snapshot() -> FieldContext { context }
}

@MainActor
func makeController(
    polisher: GatedIntentService = GatedIntentService(),
    pasteThreshold: Int = 100,
    pasteInserter: RecordingInserter = RecordingInserter(),
    rangeReplacer: FakeRangeReplacer? = nil,
    clipboard: ClipboardSpy? = nil,
    fieldReader: FakeFieldReader? = nil
) -> (DictationController, FakeAudio, FakeASR, RecordingInserter, GatedIntentService, FakeHUD) {
    let audio = FakeAudio()
    let asr = FakeASR()
    let key = RecordingInserter()
    let coordinator = InsertionCoordinator(keystroke: key, paste: pasteInserter,
                                           rangeReplacer: rangeReplacer, pasteThreshold: pasteThreshold)
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0) } },
        fieldReader: fieldReader
    )
    return (controller, audio, asr, key, polisher, hud)
}
