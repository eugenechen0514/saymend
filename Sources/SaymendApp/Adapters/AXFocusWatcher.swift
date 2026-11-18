import AppKit
import ApplicationServices
import OSLog
import SaymendCore

/// AX observer 與 App 啟用通知的最小介面（issue #70）。
///
/// 抽出來只為了讓「每個註冊恰卸下一次」與跨 App 重掛能用 fake 驗帳（比照 #43 lease）；
/// production 一律用 `LiveAXFocusObservingBackend`。真正的 AX 通知送不送得到，只能實機驗。
protocol AXFocusObservingBackend: AnyObject {
    /// 對 `pid` 掛上 `kAXFocusedUIElementChangedNotification`，通知以**新焦點元素**呼叫 `onFocusChanged`
    /// （main thread）。掛不上回 nil（App 不支援 AX、行程已結束、沒有輔助使用權限）。
    func attach(pid: pid_t, onFocusChanged: @escaping (AXUIElement) -> Void) -> AnyObject?
    /// 卸下 `attach` 回傳的那一個註冊。呼叫端保證每個註冊恰呼叫一次。
    func detach(_ registration: AnyObject)
    /// 目前焦點元素所屬的 App——session 開始時要掛在哪一個行程上
    func focusedApplicationPID() -> pid_t?
    /// 某個 App 自己記著的焦點元素。切到新 App 時那個 App 內部沒有「焦點變更」可推，只能主動問一次。
    func focusedElement(ofApplication pid: pid_t) -> AXUIElement?
    /// 訂閱前景 App 切換（main thread 回呼），回傳退訂用的 token
    func observeActivations(_ handler: @escaping (pid_t) -> Void) -> AnyObject
    /// 退訂。呼叫端保證每個 token 恰呼叫一次。
    func stopObservingActivations(_ token: AnyObject)
}

/// 錄音期間的焦點變更監看（issue #70）：controller 每段錄音 `startWatching` 一次、`stop()` 一次。
///
/// 判定的是 AX 推來的**那個元素**，不是收到通知後再查一次目前焦點：焦點進出密碼欄 P 很快時，
/// 兩則通知排在同一輪 run loop 裡，處理第一則的當下系統焦點早已回到 A——事後再查等於重造 #70 的洞。
/// 讀 P 的 subrole 不受「焦點已離開」影響，元素還在就問得到。
///
/// 已知邊界（寫在 PR，實機驗收才看得出來）：
/// - App 不發 `kAXFocusedUIElementChanged`（或 observer 掛不上）就收不到，退回原本兩道事件驅動的閘門（#21）。
/// - 不監看自己（Saymend 自己的視窗）：在 main thread 上對自己的行程發同步 AX 查詢會卡到逾時。
final class AXFocusWatcher: FocusChangeWatching {
    private let backend: any AXFocusObservingBackend
    private let security: (AXUIElement) -> FocusedFieldSecurity
    private let ownPID: pid_t

    /// `security` 接 `AXFieldReader.focusSecurity(of:)`：與開始聽寫、兩道閘門共用同一個 #59 三態判定，不另寫一份。
    init(security: @escaping (AXUIElement) -> FocusedFieldSecurity,
         backend: any AXFocusObservingBackend = LiveAXFocusObservingBackend(),
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.security = security
        self.backend = backend
        self.ownPID = ownPID
    }

    @MainActor
    func startWatching(onChange: @escaping @MainActor (FocusedFieldSecurity) -> Void) -> any FocusWatch {
        let watch = AXFocusWatch(backend: backend, security: security, ownPID: ownPID, onChange: onChange)
        watch.begin()
        return watch
    }
}

/// 一段錄音的監看。同一時間最多掛一個 AX observer（目前前景那個 App）；換 App 時先卸舊的再掛新的。
@MainActor
final class AXFocusWatch: FocusWatch {
    private static let log = Logger(subsystem: "io.saymend.app", category: "ax")

    private let backend: any AXFocusObservingBackend
    private let security: (AXUIElement) -> FocusedFieldSecurity
    private let ownPID: pid_t
    private let onChange: @MainActor (FocusedFieldSecurity) -> Void
    private var registration: AnyObject?
    /// 目前掛著（或嘗試掛過）的行程。掛失敗也記，同一個 App 再被啟用時不重掛。
    private var watchedPID: pid_t?
    private var activationToken: AnyObject?
    private var stopped = false
    /// 掛載世代：每次 attach 遞增，回呼帶著自己的世代。切 App 之後舊 observer 若還有排在 run loop 上的
    /// 通知，世代對不上就不轉——那是舊 App 的焦點，不是現在前景的。
    private var attachGeneration = 0

    init(backend: any AXFocusObservingBackend, security: @escaping (AXUIElement) -> FocusedFieldSecurity,
         ownPID: pid_t, onChange: @escaping @MainActor (FocusedFieldSecurity) -> Void) {
        self.backend = backend
        self.security = security
        self.ownPID = ownPID
        self.onChange = onChange
    }

    func begin() {
        // backend 的回呼都在 main thread（AX run loop source 掛在 main run loop、啟用通知走 .main queue）
        activationToken = backend.observeActivations { [weak self] pid in
            MainActor.assumeIsolated { self?.applicationActivated(pid) }
        }
        if let pid = backend.focusedApplicationPID(), pid != ownPID {
            attach(to: pid)
        }
    }

    func stop() {
        guard !stopped else { return }            // 冪等：重複 stop 不重複卸載
        stopped = true
        detach()
        if let token = activationToken {
            activationToken = nil
            backend.stopObservingActivations(token)
        }
    }

    private func attach(to pid: pid_t) {
        watchedPID = pid
        attachGeneration &+= 1
        let generation = attachGeneration
        registration = backend.attach(pid: pid) { [weak self] element in
            MainActor.assumeIsolated {
                guard let self, generation == self.attachGeneration else { return }
                self.report(element)
            }
        }
        if registration == nil {
            // 不是錯誤：這個 App 不支援 AX 通知，退回事件驅動的兩道閘門（#21）。只留 debug 供實機判讀。
            Self.log.debug("focus watch: 無法對 pid \(pid, privacy: .public) 掛上焦點變更通知")
        }
    }

    private func detach() {
        watchedPID = nil
        guard let registration else { return }
        self.registration = nil                   // 先清再卸：卸載若同步回呼也不會再卸一次
        backend.detach(registration)
    }

    /// 前景 App 換了：observer 是掛在單一行程上的，要跟著換。新 App 內部沒有焦點「變更」，
    /// 它原本聚焦的元素（可能就是密碼欄）要主動問一次。
    private func applicationActivated(_ pid: pid_t) {
        guard !stopped, pid != ownPID, pid != watchedPID else { return }
        detach()
        attach(to: pid)
        if let element = backend.focusedElement(ofApplication: pid) {
            report(element)
        }
    }

    private func report(_ element: AXUIElement) {
        guard !stopped else { return }            // stop 之後才送達的通知一律不轉
        onChange(security(element))
    }
}

/// production backend：AXObserver 掛在 main run loop（common modes，選單追蹤期間也收得到）。
final class LiveAXFocusObservingBackend: AXFocusObservingBackend {
    /// `refcon` 指向的 handler 盒子。註冊時 retain、卸載時 release——與註冊同生共死。
    private final class HandlerBox {
        let handler: (AXUIElement) -> Void
        init(_ handler: @escaping (AXUIElement) -> Void) { self.handler = handler }
    }

    private final class Registration {
        let observer: AXObserver
        let application: AXUIElement
        let box: Unmanaged<HandlerBox>
        init(observer: AXObserver, application: AXUIElement, box: Unmanaged<HandlerBox>) {
            self.observer = observer
            self.application = application
            self.box = box
        }
    }

    private static let notification = kAXFocusedUIElementChangedNotification as CFString

    /// C callback 不能捕捉任何東西，handler 從 refcon 取回
    private static let callback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        Unmanaged<HandlerBox>.fromOpaque(refcon).takeUnretainedValue().handler(element)
    }

    func attach(pid: pid_t, onFocusChanged: @escaping (AXUIElement) -> Void) -> AnyObject? {
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return nil }
        let application = AXUIElementCreateApplication(pid)
        let box = Unmanaged.passRetained(HandlerBox(onFocusChanged))
        guard AXObserverAddNotification(observer, application, Self.notification, box.toOpaque()) == .success else {
            box.release()
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return Registration(observer: observer, application: application, box: box)
    }

    func detach(_ registration: AnyObject) {
        guard let registration = registration as? Registration else { return }
        AXObserverRemoveNotification(registration.observer, registration.application, Self.notification)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
        registration.box.release()
    }

    func focusedApplicationPID() -> pid_t? {
        if let element = AXFieldAccess.focusedElement() {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func focusedElement(ofApplication pid: pid_t) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    func observeActivations(_ handler: @escaping (pid_t) -> Void) -> AnyObject {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            handler(app.processIdentifier)
        }
    }

    func stopObservingActivations(_ token: AnyObject) {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}
