import Foundation
@testable import SaymendCore

let defaultTestFieldIdentity = FieldIdentity(token: 1)

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
/// 已知 test-hardening 限制：多數既有 controller tests 直接 await `lastIntentTask.value`，沒有
/// bounded watchdog；若 mutation 額外建立一個 gated intent，應紅的測試可能改成掛住。正式行為不受影響，
/// 但新增 gated regression 應優先用 `awaitBounded` 並在 timeout 時 release/cancel cleanup。
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
    var suppliesDefaultFieldIdentity = true
    var context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: nil)
    func snapshot() -> FieldContext {
        var value = context
        if suppliesDefaultFieldIdentity, value.hasFocusedElement, value.fieldIdentity == nil {
            value.fieldIdentity = defaultTestFieldIdentity
        }
        return value
    }
}

/// 有狀態的欄位環境：TextInserter、FieldContextProviding、AX range 全部操作同一份文字、caret
/// 與 focus。只看 `.delete(N)` 無法證明刪的是本 session；這個 fake 直接讓測試斷言最終欄位內容。
final class StatefulFieldEnvironment: TextInserter, FieldContextProviding, SessionRangeReplacing {
    var afterNextSnapshot: (() -> Void)?
    var verifyOverride: RangeReplaceResult?
    var replaceOverride: RangeReplaceResult?
    var preservingCaretOverride: RangeReplaceResult?
    var failInsertsRemaining = 0
    private struct State {
        var text: String
        var caretUTF16: Int
        var isSecure: Bool
        var selectedRange: FieldContext.SelectedRange?
        var identity: FieldIdentity?
    }

    private var fields: [String: State] = [:]
    private var focusedID: String?
    private let identityRegistry = FieldIdentityRegistry<String>(areEqual: ==)

    func addField(_ id: String, text: String, caretUTF16: Int? = nil,
                  isSecure: Bool = false) {
        fields[id] = State(text: text, caretUTF16: caretUTF16 ?? text.utf16.count,
                           isSecure: isSecure, selectedRange: nil, identity: nil)
        if focusedID == nil { focusedID = id }
    }

    func focus(_ id: String) {
        precondition(fields[id] != nil)
        focusedID = id
    }

    func text(in id: String) -> String { fields[id]!.text }

    func select(in id: String, location: Int, length: Int) {
        fields[id]!.selectedRange = .init(location: location, length: length)
        fields[id]!.caretUTF16 = location + length
    }

    func typeUserText(_ text: String) throws { try insert(text) }

    var identityEntryCount: Int { identityRegistry.count }

    func snapshot() -> FieldContext {
        guard let focusedID, var state = fields[focusedID] else { return FieldContext() }
        if state.identity == nil {
            state.identity = identityRegistry.identity(for: focusedID)
            fields[focusedID] = state
        }
        let selectedText: String? = state.selectedRange.flatMap { selection in
            guard let target = range(in: state.text, location: selection.location,
                                     utf16Length: selection.length) else { return nil }
            return String(state.text[target])
        }
        let context = FieldContext(hasFocusedElement: true, isSecure: state.isSecure,
                                   caretLocation: state.caretUTF16, fieldIdentity: state.identity,
                                   selectedRange: state.selectedRange, selectedText: selectedText)
        let hook = afterNextSnapshot
        afterNextSnapshot = nil
        hook?()                                         // 模擬 snapshot 與 physical write 間外部切 focus
        return context
    }

    func releaseFieldIdentity(_ identity: FieldIdentity?) {
        guard let identity else { return }
        for id in fields.keys where fields[id]?.identity == identity {
            identityRegistry.release(identity)
            fields[id]!.identity = nil
        }
    }

    func insert(_ text: String) throws {
        if failInsertsRemaining > 0 {
            failInsertsRemaining -= 1
            throw InserterError.postFailed
        }
        try mutateFocused { state in
            guard let index = stringIndex(in: state.text, utf16Offset: state.caretUTF16) else {
                throw InserterError.postFailed
            }
            state.text.insert(contentsOf: text, at: index)
            state.caretUTF16 += text.utf16.count
        }
    }

    func deleteBackward(count: Int) throws {
        try mutateFocused { state in
            guard var start = stringIndex(in: state.text, utf16Offset: state.caretUTF16) else {
                throw InserterError.postFailed
            }
            let end = start
            for _ in 0..<count where start > state.text.startIndex {
                start = state.text.index(before: start)
            }
            let newCaret = state.text[..<start].utf16.count
            state.text.removeSubrange(start..<end)
            state.caretUTF16 = newCaret
        }
    }

    func verifyRange(fieldIdentity: FieldIdentity, location: Int,
                     expected: String) -> RangeReplaceResult {
        if let verifyOverride { return verifyOverride }
        guard let focusedID, let state = fields[focusedID] else { return .unsupported }
        guard identityRegistry.matches(fieldIdentity, element: focusedID) else { return .mismatch }
        return range(in: state.text, location: location, expected: expected) == nil ? .mismatch : .replaced
    }

    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int,
                              expected: String, with newText: String) -> RangeReplaceResult {
        if let replaceOverride { return replaceOverride }
        return replace(fieldIdentity: fieldIdentity, location: location, expected: expected,
                with: newText, preserveCaret: false)
    }

    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int,
                                             expected: String, with newText: String) -> RangeReplaceResult {
        if let preservingCaretOverride { return preservingCaretOverride }
        return replace(fieldIdentity: fieldIdentity, location: location, expected: expected,
                       with: newText, preserveCaret: true)
    }

    private var focusedState: State? {
        guard let focusedID else { return nil }
        return fields[focusedID]
    }

    private func mutateFocused(_ body: (inout State) throws -> Void) throws {
        guard let focusedID, var state = fields[focusedID] else { throw InserterError.postFailed }
        try body(&state)
        fields[focusedID] = state
    }

    private func replace(fieldIdentity: FieldIdentity, location: Int,
                         expected: String, with newText: String,
                         preserveCaret: Bool) -> RangeReplaceResult {
        guard let focusedID, var state = fields[focusedID] else { return .unsupported }
        guard identityRegistry.matches(fieldIdentity, element: focusedID) else { return .mismatch }
        guard let target = range(in: state.text, location: location, expected: expected) else {
            return .mismatch
        }
        let oldCaret = state.caretUTF16
        state.text.replaceSubrange(target, with: newText)
        state.selectedRange = nil
        if preserveCaret {
            state.caretUTF16 = caretAfterReplacement(current: oldCaret, location: location,
                                                     oldLength: expected.utf16.count,
                                                     newLength: newText.utf16.count)
        } else {
            state.caretUTF16 = location + newText.utf16.count
        }
        fields[focusedID] = state
        return .replaced
    }

    private func range(in text: String, location: Int, expected: String) -> Range<String.Index>? {
        guard let target = range(in: text, location: location, utf16Length: expected.utf16.count),
              String(text[target]) == expected else { return nil }
        return target
    }

    private func range(in text: String, location: Int, utf16Length: Int) -> Range<String.Index>? {
        guard let lower = stringIndex(in: text, utf16Offset: location),
              let upper = stringIndex(in: text, utf16Offset: location + utf16Length) else { return nil }
        return lower..<upper
    }

    private func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0,
              let index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset,
                                           limitedBy: text.utf16.endIndex) else { return nil }
        return String.Index(index, within: text)
    }
}

/// 歷史 spy
final class FakeHistory: HistoryRecording {
    private(set) var sessions: [HistorySessionRecord] = []
    private(set) var exchanges: [HistoryExchangeRecord] = []
    private(set) var finished: [(id: String, finalText: String?)] = []
    private(set) var diagnostics: [ASRDiagnosticRecord] = []
    func beginSession(_ record: HistorySessionRecord) { sessions.append(record) }
    func recordExchange(_ record: HistoryExchangeRecord) { exchanges.append(record) }
    func recordASRDiagnostic(_ record: ASRDiagnosticRecord) { diagnostics.append(record) }
    func finishSession(id: String, finalText: String?) { finished.append((id, finalText)) }
    func recentSessions(limit: Int) -> [HistorySessionRecord] { Array(sessions.suffix(limit).reversed()) }
    func exchanges(sessionID: String) -> [HistoryExchangeRecord] { exchanges.filter { $0.sessionID == sessionID } }
    func asrDiagnostics(sessionID: String) -> [ASRDiagnosticRecord] { diagnostics.filter { $0.sessionID == sessionID } }
    func purge(olderThanDays: Int) {}
    func deleteAll() { sessions = []; exchanges = []; finished = []; diagnostics = [] }
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
    feedback: FakeFeedback? = nil,
    history: FakeHistory? = nil,
    contextOCR: (() async -> String?)? = nil
) -> (DictationController, FakeAudio, FakeASR, RecordingInserter, GatedIntentService, FakeHUD) {
    let audio = FakeAudio()
    let asr = FakeASR()
    let key = RecordingInserter()
    let coordinator = InsertionCoordinator(keystroke: key, paste: pasteInserter,
                                           rangeReplacer: rangeReplacer, pasteThreshold: pasteThreshold)
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let effectiveFieldReader: FakeFieldReader = fieldReader ?? {
        let reader = FakeFieldReader()
        reader.suppliesDefaultFieldIdentity = false
        return reader
    }()
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0) } },
        fieldReader: effectiveFieldReader,
        feedback: feedback,
        history: history,
        contextOCR: contextOCR
    )
    if fieldReader == nil, rangeReplacer == nil {
        controller.allowUnverifiedWritesForTesting()
    }
    return (controller, audio, asr, key, polisher, hud)
}

@MainActor
func makeStatefulController(
    environment: StatefulFieldEnvironment,
    polisher: GatedIntentService = GatedIntentService(),
    supportsAX: Bool = true,
    clipboard: ClipboardSpy? = nil,
    history: FakeHistory? = nil
) -> (DictationController, FakeAudio, FakeASR, FakeHUD) {
    let audio = FakeAudio(), asr = FakeASR(), hud = FakeHUD()
    let coordinator = InsertionCoordinator(keystroke: environment, paste: environment,
                                           rangeReplacer: supportsAX ? environment : nil,
                                           pasteThreshold: 100)
    let suite = "stateful-field-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!,
                               secrets: InMemorySecretStore())
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0) } },
        fieldReader: environment,
        history: history
    )
    return (controller, audio, asr, hud)
}
