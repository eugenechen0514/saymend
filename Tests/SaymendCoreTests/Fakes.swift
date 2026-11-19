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

/// 剪貼簿急救 spy（欄位寫不進去、或 session 已無法承接 outcome 時的最後手段）
final class ClipboardSpy {
    /// 每次救援的文字與它所屬的 round（issue #42：只有同一輪才會在剪貼簿裡串接）。
    private(set) var entries: [(text: String, round: Int)] = []
    /// 多數斷言只在意文字，保留成 computed（既有 `spy.texts == [...]` 不必改）。
    var texts: [String] { entries.map(\.text) }
    /// 要斷言 round 邊界的測試用（同 session 相同、跨 session 不同）。
    var rounds: [Int] { entries.map(\.round) }
    /// issue #71：照 App 端 `ClipboardChannel` 的語意回報。真正的判定（changeCount、paste 在途）在 App 端的
    /// `ClipboardRescueReplacementTests` 驗；這裡只模型化 controller 需要的四種結果：
    /// 剪貼簿仍是同一輪＝`.appended`、仍是別一輪＝`.replacedEarlierRescue`、不是救援（或使用者複製過別的）＝`.landed`、
    /// `failNextWrite`＝`.notWritten`（剪貼簿維持原狀）。
    @discardableResult
    func rescue(_ text: String, round: Int) -> ClipboardRescueOutcome {
        entries.append((text, round))
        if failNextWrite { failNextWrite = false; return .notWritten }
        defer { landedRound = round; userTookClipboard = false }
        guard !userTookClipboard, let landed = landedRound else { return .landed }
        return landed == round ? .appended : .replacedEarlierRescue
    }
    /// 剪貼簿此刻是哪一輪的救援（nil＝不是我方救援）
    private var landedRound: Int?
    private var userTookClipboard = false
    /// 下一次救援寫不進剪貼簿
    var failNextWrite = false
    /// `earlierRescueInClipboard`：測試開始時剪貼簿裡已經有一份**別一輪**、使用者還沒動過的救援（issue #71 的情境）
    init(earlierRescueInClipboard: Bool = false) {
        if earlierRescueInClipboard { landedRound = Int.min }
    }
    /// 使用者自己複製了別的東西（changeCount 前進）：上一份救援已不在剪貼簿，下一次救援不算取代
    func userCopiedSomethingElse() { userTookClipboard = true }
}

final class FakeHUD: HUDPresenting {
    private(set) var states: [HUDState] = []
    /// issue #61：經 `presentRescueNotice` 送來的救援提示文案（依序）。
    private(set) var rescueNotices: [String] = []
    func present(_ state: HUDState) { states.append(state) }
    /// 照舊 append `.notice(message)` 到 `states`：既有的 `.notice` 斷言零遷移，
    /// `rescueNotices` 另外記下「這則走的是救援通道」。
    func presentRescueNotice(_ message: String) {
        rescueNotices.append(message)
        states.append(.notice(message))
    }
}

/// `HUDScheduling` 的虛擬時鐘（issue #61）。`advance(to:)` 依（到期時間、排程序）執行所有到期的區塊，
/// 包括執行途中新排、且同樣已到期的。測試一律用絕對時間（`advance(to: 1.9)` 再 `advance(to: 2.0)`），
/// 避免 1.999 + 0.001 這類浮點累加誤差。
final class FakeHUDScheduler: HUDScheduling {
    private(set) var now: TimeInterval = 0
    private var pending: [(due: TimeInterval, seq: Int, block: () -> Void)] = []
    private var nextSeq = 0
    /// 尚未執行的區塊數（含 arbiter 會以 epoch 忽略的過期回呼）
    var pendingCount: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        pending.append((now + seconds, nextSeq, block))
        nextSeq += 1
    }

    func advance(to t: TimeInterval) {
        precondition(t >= now, "虛擬時鐘不能倒退")
        while let i = pending.indices.filter({ pending[$0].due <= t })
                .min(by: { (pending[$0].due, pending[$0].seq) < (pending[$1].due, pending[$1].seq) }) {
            let item = pending.remove(at: i)
            now = item.due
            item.block()
        }
        now = t
    }
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
final class StatefulFieldEnvironment: TextInserter, FieldContextProviding, SessionRangeReplacing, FocusChangeWatching {
    /// false＝這個 App 不支援 AX 讀寫：verify／replace 一律 .unsupported（純追加照常）
    var axCapable = true
    var failInsertsRemaining = 0
    private struct State {
        var text: String
        var caretUTF16: Int
        var isSecure: Bool
        /// AX 問不出 subrole（連續逾時）：依 #59 fail closed 當密碼欄擋下，但這是「不知道」不是「知道」。
        /// 與 `isSecure` 分開才量得出「真的密碼欄」與「AX 沒回應」各佔多少（issue #37）。
        var subroleUnknown: Bool
        var selectedRange: FieldContext.SelectedRange?
        /// 這個欄位所屬 App 的 bundleID（issue #37 診斷要判讀「同 App 換欄位」還是「跨 App」）
        var bundleID: String?
    }
    private var fields: [String: State] = [:]
    private var focusedID: String?
    private let registry = FieldIdentityRegistry<String>(areEqual: ==)
    private(set) var axWrites: [(field: String, location: Int, expected: String, new: String)] = []

    func addField(_ id: String, text: String, caretUTF16: Int? = nil, isSecure: Bool = false,
                  subroleUnknown: Bool = false, bundleID: String? = nil) {
        fields[id] = State(text: text, caretUTF16: caretUTF16 ?? text.utf16.count, isSecure: isSecure,
                           subroleUnknown: subroleUnknown, selectedRange: nil, bundleID: bundleID)
        if focusedID == nil { focusedID = id }
    }
    /// 移動焦點。`notifyingWatches`（issue #70）：預設照 AX 的 `kAXFocusedUIElementChangedNotification`，
    /// 以**新焦點那個欄位**的判定同步通知所有仍在監看的 watch——但只有把 env 當成 `focusWatcher`
    /// 交給 controller 的測試才有 watch，其他測試的 `focus(_:)` 仍代表「監看不到的焦點移動」。
    /// 傳 false＝這次移動 AX 沒推通知（App 不發、observer 沒掛上），用來單獨驗事件驅動的閘門。
    func focus(_ id: String, notifyingWatches: Bool = true) {
        precondition(fields[id] != nil)
        focusedID = id
        guard notifyingWatches else { return }
        let security = focusSecurity(of: fields[id]!)
        // 快照目前在監看的 id：handler 可能當場 stop（controller 硬停），也可能開新 watch
        for watchID in watches.keys.sorted() {
            guard let watch = watches[watchID], !watch.stopped else { continue }
            MainActor.assumeIsolated { watch.onChange(security) }
        }
    }
    /// 讀不到焦點（AX 逾時、焦點落在非文字元素上）：閘門回 `.unknown`、snapshot 回空的 `FieldContext()`。
    /// issue #65 用它模擬「session 有 identity，卻問不出現在的焦點」。
    func blur() { focusedID = nil }
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
        // fail closed：問不出 subrole 與確定是密碼欄，在 snapshot 這條路徑上收斂成同一個 isSecure
        // （`FieldContext` 沒有 verdict 欄位，比照 production 的 `snapshot(of:)`）。
        if state.isSecure || state.subroleUnknown { return FieldContext(hasFocusedElement: true, isSecure: true) }
        let selectedText: String? = state.selectedRange.flatMap { sel in
            range(in: state.text, location: sel.location, utf16Length: sel.length).map { String(state.text[$0]) }
        }
        return FieldContext(hasFocusedElement: true, caretLocation: state.caretUTF16,
                            fieldIdentity: registry.identity(for: focusedID),
                            selectedRange: state.selectedRange, selectedText: selectedText,
                            frontAppBundleID: state.bundleID)
    }
    func releaseFieldIdentity(_ identity: FieldIdentity?) { registry.release(identity) }

    /// 閘門查詢**之後**、回傳之前執行一次（預設 nil＝不介入）。用來製造 TOCTOU 的窄窗口：
    /// 閘門已經答完「焦點還在 A」，就在這一瞬間把焦點搬走。
    /// 語義刻意與「先算結果、再呼叫 hook、最後回傳」綁死——hook 不影響**本次**的回答，只影響下一次。
    /// `fieldGateCalls` 讓測試能指定「第幾次查詢之後才搬」（fallback 窗口 W1′ 需要）。
    var afterFieldGate: (() -> Void)?
    private(set) var fieldGateCalls = 0

    /// 輕量閘門（issue #37）：與 production AXFieldReader 同一條邏輯——先 secure、再 identity，
    /// 且**只用 `registry.matches`**（不登記持有者），所以 lease 不變式不受閘門影響。
    func fieldGate(sessionIdentity: FieldIdentity?) -> FieldGate {
        let result = computeFieldGate(sessionIdentity: sessionIdentity)
        fieldGateCalls += 1
        afterFieldGate?()
        return result
    }

    private func computeFieldGate(sessionIdentity: FieldIdentity?) -> FieldGate {
        guard let focusedID, let state = fields[focusedID] else { return .unknown }
        if state.isSecure { return .secure }
        if state.subroleUnknown { return .secureUnknown }
        guard let sessionIdentity else { return .unknown }
        return registry.matches(sessionIdentity, element: focusedID)
            ? .same
            : .different(currentAppBundleID: state.bundleID)
    }

    // MARK: FocusChangeWatching（issue #70）

    private final class Watch: FocusWatch {
        weak var env: StatefulFieldEnvironment?
        let id: Int
        init(env: StatefulFieldEnvironment, id: Int) { self.env = env; self.id = id }
        func stop() { env?.stopWatch(id) }
        func resync() { env?.resync(id) }
    }
    private var watches: [Int: (onChange: @MainActor (FocusedFieldSecurity) -> Void, stopped: Bool)] = [:]
    private var nextWatchID = 0
    /// `startWatching` 的呼叫數
    private(set) var watchStarts = 0
    /// `stop()` 的**原始**呼叫數（重複 stop 也算）：恰一次的驗帳就是 `watchStops == watchStarts`，
    /// controller 對同一個 handle stop 兩次會讓它大於 starts。
    private(set) var watchStops = 0
    /// `resync()` 的呼叫數（controller 在錄音中每個 tick 呼叫一次）。跨行程重掛的行為在 App 端驗。
    fileprivate(set) var resyncCalls = 0
    /// `startWatching` 被呼叫、**watch 還沒登記之前**執行一次（預設 nil）。用來製造「snapshot 之後、observer 掛上之前」
    /// 的焦點移動：這時沒有 watch 可通知，等同 AX 通知發出時 observer 還不存在。
    var beforeStartWatching: (() -> Void)?
    /// 非 nil＝下一次 `resync()` 時以這個判定回報（模擬「焦點已在別的行程、改掛過去後發現是密碼欄」）
    var resyncReport: FocusedFieldSecurity?

    @MainActor
    private func resync(_ id: Int) {
        resyncCalls += 1
        guard let report = resyncReport, let watch = watches[id], !watch.stopped else { return }
        resyncReport = nil
        watch.onChange(report)
    }
    /// 仍在監看（start 過、尚未 stop）的 watch 數
    var activeWatchCount: Int { watches.values.filter { !$0.stopped }.count }

    @MainActor
    func startWatching(onChange: @escaping @MainActor (FocusedFieldSecurity) -> Void) -> any FocusWatch {
        beforeStartWatching?()
        watchStarts += 1
        nextWatchID += 1
        watches[nextWatchID] = (onChange, false)
        return Watch(env: self, id: nextWatchID)
    }

    private func stopWatch(_ id: Int) {
        watchStops += 1
        watches[id]?.stopped = true
    }

    /// 模擬「stop 之前就已排進 run loop、stop 之後才送達」的遲到通知：送給**已停止**的 watch。
    /// production 的 observer 移除後不會再送，但 controller 不能依賴這點——它必須自己認得舊 watch。
    @MainActor
    func deliverToStoppedWatches(_ security: FocusedFieldSecurity) {
        for watchID in watches.keys.sorted() where watches[watchID]?.stopped == true {
            watches[watchID]?.onChange(security)
        }
    }

    /// 與 production `AXFieldReader.focusSecurity(of:)` 同一條判定：只看元素本身的 subrole，不碰 identity
    private func focusSecurity(of state: State) -> FocusedFieldSecurity {
        if state.isSecure { return .secure }
        if state.subroleUnknown { return .secureUnknown }
        return .notSecure
    }

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

/// issue #71：剪貼簿裡原本有別一輪的救援時，救援提示應有的樣子
@MainActor
func rescueNotice(_ base: String, _ earlierRescueInClipboard: Bool) -> String {
    earlierRescueInClipboard ? base + DictationController.replacedEarlierRescueSuffix : base
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
    // 預設就接上寫入前的焦點閘門（issue #37）：不接的話新路徑在多數測試裡根本不執行，
    // mutation 也就殺不到。FakeFieldReader 走 protocol 預設實作（由 snapshot() 推導），
    // 所以每次閘門查詢都多一次 snapshot ＋ 一次 token 歸還——`released.count == snapshots`
    // 這條 lease 不變式仍然成立（成對增加），但逐項比對 released 陣列的測試要跟著校準。
    let reader = fieldReader ?? FakeFieldReader.sessionField()   // 預設有 anchor＋identity（issue #44）
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    // settings 刻意先於 coordinator 建立：保險絲（issue #37）要與 controller 共用同一個實例，
    // 測試才能在建構後翻 `c.settings.rawAppendGateEnabled` 並被閘門即時讀到。
    // 誠實揭露：**目前沒有任何測試從這個 helper 走保險絲**（保險絲的端到端測試都用
    // `makeStatefulController`）。這裡照接是為了兩個 helper 語意一致——否則之後有人在這裡寫
    // 保險絲測試會拿到「開關翻了卻沒作用」的假綠。
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let coordinator = InsertionCoordinator(keystroke: key, paste: pasteInserter,
                                           rangeReplacer: rangeReplacer, pasteThreshold: pasteThreshold,
                                           fieldGate: { [weak reader] identity in
                                               reader?.fieldGate(sessionIdentity: identity) ?? .unknown
                                           },
                                           gateEnabled: { settings.rawAppendGateEnabled })
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: hud, settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0, round: $1) } },
        fieldReader: reader,        // 上方已解析（閘門 closure 要捕捉同一個實例）
        feedback: feedback,
        history: history,
        contextOCR: contextOCR
    )
    return (controller, audio, asr, key, polisher, hud)
}

/// 以 StatefulFieldEnvironment 同時擔任 keystroke／paste／AX／reader 的 controller
///
/// `wrapHUD`（issue #61）：把 FakeHUD 包一層再交給 controller（端到端測試用來包 `HUDArbiter`）。
/// 回傳的**仍是內層 FakeHUD**——也就是 arbiter 的輸出端、window 實際收到的序列。預設不包，
/// FakeHUD 直接觀察 controller 的原始輸出（`makeController` 一律不包）。
@MainActor
func makeStatefulController(
    env: StatefulFieldEnvironment,
    polisher: GatedIntentService = GatedIntentService(),
    clipboard: ClipboardSpy? = nil,
    history: FakeHistory? = nil,
    feedback: FakeFeedback? = nil,
    wrapHUD: (FakeHUD) -> any HUDPresenting = { $0 },
    focusWatcher: (any FocusChangeWatching)? = nil
) -> (DictationController, FakeASR, FakeHUD) {
    let audio = FakeAudio()
    let asr = FakeASR()
    let hud = FakeHUD()
    let suite = "test-\(UUID().uuidString)"
    // 同 makeController：settings 先建，保險絲與 controller 共用同一個實例。
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    let coordinator = InsertionCoordinator(keystroke: env, paste: env, rangeReplacer: env, pasteThreshold: 100,
                                           fieldGate: { [weak env] identity in
                                               env?.fieldGate(sessionIdentity: identity) ?? .unknown
                                           },
                                           gateEnabled: { settings.rawAppendGateEnabled })
    let controller = DictationController(
        audio: audio, asr: asr, coordinator: coordinator,
        intent: polisher, hud: wrapHUD(hud), settings: settings,
        clipboardRescue: clipboard.map { spy in { spy.rescue($0, round: $1) } },
        fieldReader: env, feedback: feedback, history: history, contextOCR: nil,
        focusWatcher: focusWatcher)
    return (controller, asr, hud)
}
