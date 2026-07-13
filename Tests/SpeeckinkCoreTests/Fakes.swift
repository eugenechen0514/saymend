import Foundation
@testable import SpeeckinkCore

enum FakeAudioError: Error { case startFailed }

final class FakeAudio: AudioCaptureService {
    var levelHandler: ((Float) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var failNextStart = false
    var continuation: AsyncStream<AudioChunk>.Continuation?
    func start() throws -> AsyncStream<AudioChunk> {
        if failNextStart { failNextStart = false; throw FakeAudioError.startFailed }
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
    private let lock = NSLock()
    var outcome: IntentOutcome = .newContent("（潤飾）")
    /// 以 utteranceRaw 指定該句的 outcome（未列者用 outcome）。
    /// 不可用「呼叫順序」佇列：controller 刻意讓多句 LLM 呼叫平行，兩個 process() 搶鎖的
    /// 順序與句序無關，佇列會在負載下把 outcome/gate 配錯句（實測 flaky）。
    var outcomeByRaw: [String: IntentOutcome] = [:]
    /// 以 utteranceRaw 指定該句要卡 gate 等 release()（未列者用 gated）
    var gatedRaws: Set<String> = []
    private(set) var calls: [(raw: String, context: IntentContext)] = []
    /// 若設為 false，process 立即回傳；true 時等 release() 才回
    var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReleases = 0
    // 多個 utterance 的 process() 會在不同 executor 執行緒併發進來（controller 的 LLM 呼叫刻意平行），
    // 共享陣列必須上鎖，否則 continuation 可能遺失造成測試永久卡住。
    func process(utteranceRaw: String, context: IntentContext) async -> IntentOutcome {
        let (thisOutcome, thisGated): (IntentOutcome, Bool) = lock.withLock {
            calls.append((utteranceRaw, context))
            let o = outcomeByRaw[utteranceRaw] ?? outcome
            let g = gatedRaws.contains(utteranceRaw) || gated
            return (o, g)
        }
        if thisGated {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let proceedNow: Bool = lock.withLock {
                    if pendingReleases > 0 {
                        pendingReleases -= 1
                        return true
                    }
                    waiters.append(cont)
                    return false
                }
                if proceedNow { cont.resume() }
            }
        }
        return thisOutcome
    }
    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                pendingReleases += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
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

/// 回饋層 spy（M3 overlay／diff 的 Core 側接點）
final class FakeFeedback: SessionFeedbackPresenting {
    enum Event: Equatable {
        case updated(FeedbackUpdate)
        case frozen
        case ended
    }
    private(set) var events: [Event] = []
    func sessionUpdated(_ update: FeedbackUpdate) { events.append(.updated(update)) }
    func sessionFrozen() { events.append(.frozen) }
    func sessionEnded() { events.append(.ended) }
}

@MainActor
func makeController(
    polisher: GatedIntentService = GatedIntentService(),
    pasteThreshold: Int = 100,
    pasteInserter: RecordingInserter = RecordingInserter(),
    rangeReplacer: FakeRangeReplacer? = nil,
    clipboard: ClipboardSpy? = nil,
    fieldReader: FakeFieldReader? = nil,
    feedback: FakeFeedback? = nil
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
        fieldReader: fieldReader,
        feedback: feedback
    )
    return (controller, audio, asr, key, polisher, hud)
}
