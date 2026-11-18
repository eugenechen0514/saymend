import ApplicationServices
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #70：App 端的焦點變更監看。
///
/// 驗收條件 3「observer 的註冊／移除恰一次（比照 #43 lease 的驗帳方式）」在這裡驗：fake backend 記下每一次
/// attach／detach／訂閱／退訂，斷言**每個成功的註冊恰卸一次**、跨 App 重掛時舊的先卸。
/// 元素用 `AXUIElementCreateApplication(pid)` 建（不需要輔助使用權限），不同 pid 即不同元素。
///
/// 這裡驗不到的：真的 AX 通知送不送得到、哪些 App 不發 `kAXFocusedUIElementChanged`——只能實機驗。
@Suite @MainActor struct AXFocusWatcherTests {

    private let appA: pid_t = 101
    private let appB: pid_t = 202
    private let me: pid_t = 999

    private func element(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    /// 判定只認元素本身：`secureElements` 裡的（CFEqual）回 `.secure`
    private func security(secure: [AXUIElement], unknown: [AXUIElement] = []) -> (AXUIElement) -> FocusedFieldSecurity {
        { el in
            if secure.contains(where: { CFEqual($0, el) }) { return .secure }
            if unknown.contains(where: { CFEqual($0, el) }) { return .secureUnknown }
            return .notSecure
        }
    }

    private func makeWatcher(_ backend: FakeAXFocusBackend,
                             secure: [AXUIElement] = []) -> AXFocusWatcher {
        AXFocusWatcher(security: security(secure: secure), backend: backend, ownPID: me)
    }

    // MARK: - 驗帳

    @Test func startAttachesToTheFocusedAppOnceAndStopDetachesItOnce() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let watch = makeWatcher(backend).startWatching { _ in }
        #expect(backend.attaches == [appA])
        #expect(backend.activationSubscriptions == 1)

        watch.stop()
        #expect(backend.detaches == [appA])
        #expect(backend.activationUnsubscriptions == 1)
        #expect(backend.liveRegistrations == 0 && backend.liveActivationTokens == 0)
    }

    /// 重複 stop（controller 不該這樣做，但 handle 自己也不得重複卸載）
    @Test func stoppingTwiceDetachesOnlyOnce() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let watch = makeWatcher(backend).startWatching { _ in }
        watch.stop()
        watch.stop()
        #expect(backend.detaches == [appA])
        #expect(backend.activationUnsubscriptions == 1)
    }

    /// 前景切到另一個 App：先卸舊、再掛新，stop 時卸新的。全程同一時間最多一個 observer。
    @Test func switchingAppsMovesTheObserverAndStopDetachesTheNewOne() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let watch = makeWatcher(backend).startWatching { _ in }
        backend.activate(appB)
        #expect(backend.attaches == [appA, appB])
        #expect(backend.detaches == [appA], "舊 App 的 observer 先卸")
        #expect(backend.maxLiveRegistrations == 1, "同一時間最多一個 observer")

        watch.stop()
        #expect(backend.detaches == [appA, appB])
        #expect(backend.liveRegistrations == 0)
    }

    /// 再次啟用同一個 App、或啟用的是 Saymend 自己：不重掛、不回報
    @Test func reactivatingTheSameAppOrOurselvesDoesNothing() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        backend.focusedElements[appA] = element(appA)
        var reports: [FocusedFieldSecurity] = []
        let watch = makeWatcher(backend).startWatching { reports.append($0) }
        backend.activate(appA)
        backend.activate(me)
        #expect(backend.attaches == [appA])
        #expect(backend.detaches.isEmpty)
        #expect(reports.isEmpty)
        watch.stop()
    }

    /// 掛不上（App 不支援 AX）：沒有註冊就沒有東西要卸；之後切到別的 App 照常掛
    @Test func aFailedAttachIsNeverDetachedAndTheNextAppStillGetsWatched() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        backend.failingPIDs = [appA]
        let watch = makeWatcher(backend).startWatching { _ in }
        backend.activate(appB)
        watch.stop()
        #expect(backend.attaches == [appA, appB])
        #expect(backend.detaches == [appB], "只卸成功掛上的那一個")
        #expect(backend.liveRegistrations == 0)
    }

    /// 開始時讀不到焦點 App：先不掛，等第一次切換再掛
    @Test func noFocusedAppAtStartAttachesOnTheFirstActivation() {
        let backend = FakeAXFocusBackend(focusedPID: nil)
        let watch = makeWatcher(backend).startWatching { _ in }
        #expect(backend.attaches.isEmpty)
        backend.activate(appB)
        #expect(backend.attaches == [appB])
        watch.stop()
        #expect(backend.detaches == [appB])
    }

    /// 開始時焦點在自己身上：不掛（在 main thread 對自己發同步 AX 查詢會卡到逾時）
    @Test func neverAttachesToOurOwnProcess() {
        let backend = FakeAXFocusBackend(focusedPID: me)
        let watch = makeWatcher(backend).startWatching { _ in }
        #expect(backend.attaches.isEmpty)
        watch.stop()
        #expect(backend.detaches.isEmpty)
    }

    // MARK: - 回報的內容

    /// 判定的是 AX 推來的**那個元素**，不是事後再查目前焦點：#70 的情境裡，處理「進入 P」那則通知時，
    /// App 的焦點早已回到 A。事後再查會回 `.notSecure`。
    @Test func reportsTheElementThatGainedFocusNotWhateverIsFocusedNow() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldA = element(1001)
        let fieldP = element(1002)
        backend.focusedElements[appA] = fieldA            // 「現在」焦點在 A
        var reports: [FocusedFieldSecurity] = []
        let watch = makeWatcher(backend, secure: [fieldP]).startWatching { reports.append($0) }

        backend.focusChanged(in: appA, to: fieldP)        // 但這則通知說的是 P
        backend.focusChanged(in: appA, to: fieldA)

        #expect(reports == [.secure, .notSecure])
        watch.stop()
    }

    /// 切到新 App：它原本就聚焦在密碼欄（沒有「焦點變更」可推）——主動問一次並回報
    @Test func activatingAnAppWhoseFocusIsAlreadyAPasswordFieldReportsIt() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldP = element(2002)
        backend.focusedElements[appB] = fieldP
        var reports: [FocusedFieldSecurity] = []
        let watch = makeWatcher(backend, secure: [fieldP]).startWatching { reports.append($0) }
        backend.activate(appB)
        #expect(reports == [.secure])
        watch.stop()
    }

    /// 換 App 之後，舊 App 的通知不再轉（已卸載），新 App 的才轉
    @Test func afterSwitchingOnlyTheNewAppsNotificationsAreReported() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldP = element(1002)
        var reports: [FocusedFieldSecurity] = []
        let watch = makeWatcher(backend, secure: [fieldP]).startWatching { reports.append($0) }
        backend.activate(appB)
        backend.focusChanged(in: appA, to: fieldP, includingDetached: true)   // 舊 App 遲到的通知
        #expect(reports.isEmpty)
        watch.stop()
    }

    /// stop 之後才送達的通知（含 stop 前已排進 run loop 的）一律不轉；啟用通知也一樣
    @Test func nothingIsReportedAfterStop() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldP = element(1002)
        backend.focusedElements[appB] = fieldP
        var reports: [FocusedFieldSecurity] = []
        let watch = makeWatcher(backend, secure: [fieldP]).startWatching { reports.append($0) }
        watch.stop()
        backend.focusChanged(in: appA, to: fieldP, includingDetached: true)
        backend.activate(appB, includingUnsubscribed: true)
        #expect(reports.isEmpty)
        #expect(backend.attaches == [appA], "stop 之後的啟用通知不得再掛 observer")
    }

    /// controller 在回呼裡當場硬停（`abortForSecureField` → `stop()`）：恰卸一次、不 crash、之後不再轉
    @Test func stoppingFromInsideTheCallbackDetachesExactlyOnce() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldP = element(1002)
        var reports: [FocusedFieldSecurity] = []
        var watch: (any FocusWatch)?
        watch = makeWatcher(backend, secure: [fieldP]).startWatching { security in
            reports.append(security)
            if security == .secure { watch?.stop() }
        }
        backend.focusChanged(in: appA, to: fieldP)
        backend.focusChanged(in: appA, to: fieldP, includingDetached: true)
        watch?.stop()                                      // controller 那邊不會再停，但就算停了也不得重複卸
        #expect(reports == [.secure])
        #expect(backend.detaches == [appA])
        #expect(backend.activationUnsubscriptions == 1)
    }

    /// 切 App 時新 App 的焦點就是密碼欄，controller 在回報裡當場 stop：新掛的那個要恰卸一次
    @Test func stoppingWhileHandlingAnActivationDetachesTheNewObserverOnce() {
        let backend = FakeAXFocusBackend(focusedPID: appA)
        let fieldP = element(2002)
        backend.focusedElements[appB] = fieldP
        var watch: (any FocusWatch)?
        watch = makeWatcher(backend, secure: [fieldP]).startWatching { _ in watch?.stop() }
        backend.activate(appB)
        #expect(backend.attaches == [appA, appB])
        #expect(backend.detaches == [appA, appB])
        #expect(backend.liveRegistrations == 0 && backend.liveActivationTokens == 0)
    }

    // MARK: - AXFieldReader.focusSecurity：與既有閘門共用 #59 三態

    @Test func focusSecurityMapsTheSharedSecureVerdict() {
        let el = element(appA)
        func reader(_ reads: [(AXError, String?)]) -> AXFieldReader {
            var queue = reads
            return AXFieldReader(registry: AXFieldRegistry(),
                                 readSubrole: { _ in queue.isEmpty ? (.success, nil) : queue.removeFirst() },
                                 focusedElement: { nil })
        }
        #expect(reader([(.success, kAXSecureTextFieldSubrole as String)]).focusSecurity(of: el) == .secure)
        #expect(reader([(.success, "AXSearchField")]).focusSecurity(of: el) == .notSecure)
        #expect(reader([(.attributeUnsupported, nil)]).focusSecurity(of: el) == .notSecure)
        #expect(reader([(.cannotComplete, nil), (.cannotComplete, nil)]).focusSecurity(of: el) == .secureUnknown,
                "逾時重試一次仍問不出來：fail closed")
        #expect(reader([(.cannotComplete, nil), (.success, kAXSecureTextFieldSubrole as String)])
                    .focusSecurity(of: el) == .secure, "重試問到了就照答案")
    }

    @Test func focusSecurityDoesNotRegisterAnyIdentity() {
        let registry = AXFieldRegistry()
        let reader = AXFieldReader(registry: registry, readSubrole: { _ in (.attributeUnsupported, nil) },
                                   focusedElement: { nil })
        _ = reader.focusSecurity(of: element(appA))
        #expect(registry.entryCount == 0, "#43 lease：監看不得替任何元素留持有者")
    }
}

/// 記帳用的 fake backend：每一次 attach／detach／訂閱／退訂都記下來，並能送出「已卸載之後才到」的通知。
final class FakeAXFocusBackend: AXFocusObservingBackend {
    private final class Registration {
        let pid: pid_t
        let handler: (AXUIElement) -> Void
        var detached = false
        init(pid: pid_t, handler: @escaping (AXUIElement) -> Void) { self.pid = pid; self.handler = handler }
    }
    private final class ActivationToken {
        let handler: (pid_t) -> Void
        var cancelled = false
        init(_ handler: @escaping (pid_t) -> Void) { self.handler = handler }
    }

    var focusedPID: pid_t?
    var focusedElements: [pid_t: AXUIElement] = [:]
    var failingPIDs: Set<pid_t> = []
    private(set) var attaches: [pid_t] = []
    private(set) var detaches: [pid_t] = []
    private(set) var activationSubscriptions = 0
    private(set) var activationUnsubscriptions = 0
    private(set) var maxLiveRegistrations = 0
    private var registrations: [Registration] = []
    private var tokens: [ActivationToken] = []

    var liveRegistrations: Int { registrations.filter { !$0.detached }.count }
    var liveActivationTokens: Int { tokens.filter { !$0.cancelled }.count }

    init(focusedPID: pid_t?) { self.focusedPID = focusedPID }

    func attach(pid: pid_t, onFocusChanged: @escaping (AXUIElement) -> Void) -> AnyObject? {
        attaches.append(pid)
        guard !failingPIDs.contains(pid) else { return nil }
        let r = Registration(pid: pid, handler: onFocusChanged)
        registrations.append(r)
        maxLiveRegistrations = max(maxLiveRegistrations, liveRegistrations)
        return r
    }

    func detach(_ registration: AnyObject) {
        let r = registration as! Registration
        precondition(!r.detached, "同一個註冊卸了兩次")
        r.detached = true
        detaches.append(r.pid)
    }

    func focusedApplicationPID() -> pid_t? { focusedPID }
    func focusedElement(ofApplication pid: pid_t) -> AXUIElement? { focusedElements[pid] }

    func observeActivations(_ handler: @escaping (pid_t) -> Void) -> AnyObject {
        activationSubscriptions += 1
        let t = ActivationToken(handler)
        tokens.append(t)
        return t
    }

    func stopObservingActivations(_ token: AnyObject) {
        let t = token as! ActivationToken
        precondition(!t.cancelled, "同一個訂閱退了兩次")
        t.cancelled = true
        activationUnsubscriptions += 1
    }

    /// 模擬 AX 對 `pid` 推一則 focus-changed。`includingDetached`＝連已卸載的註冊也送（遲到的通知）
    func focusChanged(in pid: pid_t, to element: AXUIElement, includingDetached: Bool = false) {
        for r in registrations where r.pid == pid && (includingDetached || !r.detached) {
            r.handler(element)
        }
    }

    /// 模擬前景切到 `pid`。`includingUnsubscribed`＝連已退訂的也送
    func activate(_ pid: pid_t, includingUnsubscribed: Bool = false) {
        focusedPID = pid
        for t in tokens where includingUnsubscribed || !t.cancelled {
            t.handler(pid)
        }
    }
}
