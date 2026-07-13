import AppKit
import ApplicationServices
import SpeeckinkCore

/// 視覺回饋協調器（規格 §3.5）：Core 發語意事件，這裡決定「畫 overlay 還是降級 HUD diff」。
/// 鐵律：寧可不顯示，不可畫錯位置——任何 AX 查詢失敗、跟不上，立刻隱藏。
/// 跟隨機制：AX 通知（視窗移動／縮放、值變更、游標變更、元件銷毀）＋可見期間 10Hz 輪詢重查。
/// 能力快取：bundleID → BoundsForRange 是否可用（App 生命週期內有效；完整 profile 屬 M4）。
@MainActor
final class FeedbackCoordinator: SessionFeedbackPresenting {
    private let overlay: OverlayWindowController
    private let hud: HUDWindowController
    private var capability: [String: Bool] = [:]
    private var lastUpdate: FeedbackUpdate?
    private var pollTimer: Timer?
    private var axObserver: AXObserver?
    private var observedElement: AXUIElement?

    init(overlay: OverlayWindowController, hud: HUDWindowController) {
        self.overlay = overlay
        self.hud = hud
    }

    // MARK: - SessionFeedbackPresenting

    func sessionUpdated(_ update: FeedbackUpdate) {
        lastUpdate = update
        guard let anchor = update.anchor else {
            overlay.hide()
            diffFallback(update)                       // 無 AX 錨位：overlay 註定不可用
            return
        }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if capability[bundle] == false {
            diffFallback(update)
            return
        }
        if render(update, anchor: anchor) {
            capability[bundle] = true
            startFollowing()
        } else {
            capability[bundle] = false                 // 首繪失敗＝該 App 不支援（記入能力快取）
            overlay.hide()
            stopFollowing()
            diffFallback(update)
        }
    }

    func sessionFrozen() {
        stopFollowing()
        overlay.fadeOutAndHide()                       // 凍結：底線淡出（規格 §3.5）
        lastUpdate = nil
    }

    func sessionEnded() {
        stopFollowing()
        overlay.hide()
        lastUpdate = nil
    }

    // MARK: - 繪製

    /// 回傳是否成功畫出。查詢失敗一律 false（呼叫端決定隱藏／降級）。
    private func render(_ update: FeedbackUpdate, anchor: Int) -> Bool {
        guard let element = AXFieldAccess.focusedElement() else { return false }
        let length = update.text.utf16.count
        guard length > 0,
              let cgRects = AXFieldAccess.lineRects(element: element, location: anchor, utf16Length: length) else {
            return false
        }
        var underline: [CGRect] = []
        for r in cgRects {
            guard let cocoa = OverlayWindowController.cocoaRect(fromCG: r) else { return false }
            underline.append(cocoa)
        }
        var highlight: [CGRect] = []
        if let span = update.highlight, span.length > 0,
           let hlRects = AXFieldAccess.lineRects(element: element,
                                                 location: anchor + span.location,
                                                 utf16Length: span.length) {
            highlight = hlRects.compactMap { OverlayWindowController.cocoaRect(fromCG: $0) }
        }
        overlay.show(underline: underline, highlight: highlight)
        return true
    }

    /// overlay 畫不了才降級；且只在真的有異動時打擾（純底線更新沒有 diff 可看）
    private func diffFallback(_ update: FeedbackUpdate) {
        guard let old = update.oldText else { return }
        let windows = InlineDiff.windows(old: old, new: update.text)
        guard !windows.isEmpty else { return }
        hud.present(.diff(windows))
    }

    // MARK: - 跟隨（10Hz 輪詢＋AX 通知）

    private func startFollowing() {
        if pollTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        installAXObserverIfNeeded()
    }

    private func stopFollowing() {
        pollTimer?.invalidate()
        pollTimer = nil
        teardownAXObserver()
    }

    /// 重查座標：成功更新（不重播高亮），失敗立刻隱藏並停止跟隨
    private func refresh() {
        guard let update = lastUpdate, let anchor = update.anchor else { return }
        let still = FeedbackUpdate(anchor: anchor, text: update.text)   // 高亮是一次性的
        if !renderQuiet(still, anchor: anchor) {
            overlay.hide()
            stopFollowing()
        }
    }

    private func renderQuiet(_ update: FeedbackUpdate, anchor: Int) -> Bool {
        render(update, anchor: anchor)
    }

    private func installAXObserverIfNeeded() {
        guard axObserver == nil,
              let app = NSWorkspace.shared.frontmostApplication,
              let element = AXFieldAccess.focusedElement() else { return }
        var observer: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            let coordinator = Unmanaged<FeedbackCoordinator>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in coordinator.refresh() }
        }, &observer) == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                     kAXMovedNotification, kAXResizedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedElement = element
    }

    private func teardownAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let element = observedElement {
                for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                             kAXMovedNotification, kAXResizedNotification,
                             kAXUIElementDestroyedNotification] {
                    AXObserverRemoveNotification(observer, element, name as CFString)
                }
            }
        }
        axObserver = nil
        observedElement = nil
    }
}
