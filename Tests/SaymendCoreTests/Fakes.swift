import Foundation
@testable import SaymendCore

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
    /// 預設：有聚焦元素、無 anchor、無 identity＝「沒有 AX」的 App。要模擬有 AX 的欄位用 `sessionField()`。
    var context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: nil)
    /// 有 AX 的欄位：anchor 0、identity token 1。issue #44 起 makeController 的預設 reader——
    /// 契約翻轉後，會刪字的操作沒有 anchor＋identity 就一律 fail closed，多數既有測試要的是「能替換」。
    static func sessionField(caret: Int = 0, token: UInt64 = 1) -> FakeFieldReader {
        let r = FakeFieldReader()
        r.context = FieldContext(hasFocusedElement: true, caretLocation: caret, fieldIdentity: FieldIdentity(token: token))
        return r
    }
    /// 被歸還的 identity token（issue #43）。不變式：session 結束後 released.count == snapshots
    /// ——每個 snapshot 的 token 要嘛被 ledger 採用（archive 時歸還）、要嘛當場歸還。
    private(set) var released: [FieldIdentity?] = []
    private(set) var snapshots = 0
    func snapshot() -> FieldContext { snapshots += 1; return context }
    func releaseFieldIdentity(_ identity: FieldIdentity?) { released.append(identity) }
}

/// 有狀態的欄位環境（自 PR #36 撿來，issue #44）：同一份狀態同時扮演 TextInserter（keystroke 與 paste）、
/// FieldContextProviding（reader）與 SessionRangeReplacing（AX），所以測試能**斷言最終欄位內容**，
/// 而不是只數 inserter 收到幾個 op——PR #36 的三個資料遺失 bug 就是在「op 都對、欄位卻錯」裡藏了很久。
///
/// 多欄位＋焦點切換：`focus(_:)` 不會通知 controller（模擬 Tab／maxlength 自動跳格這類不觸發使用者活動偵測的焦點移動）。
/// identity 走真的 `FieldIdentityRegistry`，每次 snapshot 都登記一個持有者，配合 controller 的 lease 紀律（#43）。
final class StatefulFieldEnvironment: TextInserter, FieldContextProviding, SessionRangeReplacing {
    /// false＝這個 App 不支援 AX 讀寫：verify／replace 一律 .unsupported（純追加照常）
    var axCapable = true
    var failInsertsRemaining = 0
    private struct State {
        var text: String
        var caretUTF16: Int
        var isSecure: Bool
        var selectedRange: FieldContext.SelectedRange?
    }
    private var fields: [String: State] = [:]
    private var focusedID: String?
    private let registry = FieldIdentityRegistry<String>(areEqual: ==)
    private(set) var axWrites: [(field: String, location: Int, expected: String, new: String)] = []

    func addField(_ id: String, text: String, caretUTF16: Int? = nil, isSecure: Bool = false) {
        fields[id] = State(text: text, caretUTF16: caretUTF16 ?? text.utf16.count, isSecure: isSecure, selectedRange: nil)
        if focusedID == nil { focusedID = id }
    }
    func focus(_ id: String) { precondition(fields[id] != nil); focusedID = id }
    func text(in id: String) -> String { fields[id]!.text }
    func select(in id: String, location: Int, length: Int) {
        fields[id]!.selectedRange = .init(location: location, length: length)
        fields[id]!.caretUTF16 = location + length
    }
    /// 使用者在聚焦欄位的游標處手打（不通知 controller——模擬凍結偵測漏掉的情況）
    func typeUserText(_ text: String) { try? insert(text) }
    var identityEntryCount: Int { registry.count }

    // MARK: FieldContextProviding
    func snapshot() -> FieldContext {
        guard let focusedID, let state = fields[focusedID] else { return FieldContext() }
        if state.isSecure { return FieldContext(hasFocusedElement: true, isSecure: true) }
        let selectedText: String? = state.selectedRange.flatMap { sel in
            range(in: state.text, location: sel.location, utf16Length: sel.length).map { String(state.text[$0]) }
        }
        return FieldContext(hasFocusedElement: true, caretLocation: state.caretUTF16,
                            fieldIdentity: registry.identity(for: focusedID),
                            selectedRange: state.selectedRange, selectedText: selectedText)
    }
    func releaseFieldIdentity(_ identity: FieldIdentity?) { registry.release(identity) }

    // MARK: TextInserter（只會插入）
    func insert(_ text: String) throws {
        if failInsertsRemaining > 0 { failInsertsRemaining -= 1; throw InserterError.postFailed }
        guard let focusedID, var state = fields[focusedID] else { throw InserterError.postFailed }
        guard let index = stringIndex(in: state.text, utf16Offset: state.caretUTF16) else { throw InserterError.postFailed }
        if let sel = state.selectedRange, let target = range(in: state.text, location: sel.location, utf16Length: sel.length) {
            state.text.replaceSubrange(target, with: text)          // OS 原生：打字覆蓋活選取
            state.caretUTF16 = sel.location + text.utf16.count
            state.selectedRange = nil
        } else {
            state.text.insert(contentsOf: text, at: index)
            state.caretUTF16 += text.utf16.count
        }
        fields[focusedID] = state
    }

    // MARK: SessionRangeReplacing（identity-bound）
    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult {
        guard axCapable, let focusedID, let state = fields[focusedID] else { return .unsupported }
        guard registry.matches(fieldIdentity, element: focusedID) else { return .mismatch }
        return range(in: state.text, location: location, expected: expected) == nil ? .mismatch : .replaced
    }
    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int, expected: String,
                              with newText: String) -> RangeReplaceResult {
        replace(fieldIdentity: fieldIdentity, location: location, expected: expected, with: newText, preserveCaret: false)
    }
    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int, expected: String,
                                             with newText: String) -> RangeReplaceResult {
        replace(fieldIdentity: fieldIdentity, location: location, expected: expected, with: newText, preserveCaret: true)
    }
    private func replace(fieldIdentity: FieldIdentity, location: Int, expected: String,
                         with newText: String, preserveCaret: Bool) -> RangeReplaceResult {
        guard axCapable, let focusedID, var state = fields[focusedID] else { return .unsupported }
        guard registry.matches(fieldIdentity, element: focusedID) else { return .mismatch }
        guard let target = range(in: state.text, location: location, expected: expected) else { return .mismatch }
        let oldCaret = state.caretUTF16
        state.text.replaceSubrange(target, with: newText)
        state.selectedRange = nil
        state.caretUTF16 = preserveCaret
            ? caretAfterReplacement(current: oldCaret, location: location, oldLength: expected.utf16.count, newLength: newText.utf16.count)
            : location + newText.utf16.count
        fields[focusedID] = state
        axWrites.append((focusedID, location, expected, newText))
        return .replaced
    }

    // MARK: UTF-16 輔助
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
              let index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset, limitedBy: text.utf16.endIndex)
        else { return nil }
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
    rangeReplacer: FakeRangeReplacer? = FakeRangeReplacer(),     // 預設有 AX（issue #44）；要模擬無 AX 的 App 明確傳 nil
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
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0) } },
        fieldReader: fieldReader ?? FakeFieldReader.sessionField(),   // 預設有 anchor＋identity（issue #44）
        feedback: feedback,
        history: history,
        contextOCR: contextOCR
    )
    return (controller, audio, asr, key, polisher, hud)
}

/// 以 StatefulFieldEnvironment 同時擔任 keystroke／paste／AX／reader 的 controller
@MainActor
func makeStatefulController(
    env: StatefulFieldEnvironment,
    polisher: GatedIntentService = GatedIntentService(),
    clipboard: ClipboardSpy? = nil,
    history: FakeHistory? = nil
) -> (DictationController, FakeASR, FakeHUD) {
    let audio = FakeAudio()
    let asr = FakeASR()
    let coordinator = InsertionCoordinator(keystroke: env, paste: env, rangeReplacer: env, pasteThreshold: 100)
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0) } },
        fieldReader: env, feedback: nil, history: history, contextOCR: nil)
    return (controller, asr, hud)
}
