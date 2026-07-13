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
    /// 進行中的異動高亮（相對 lastUpdate.text 的 UTF-16 範圍）與其淡出起算牆鐘時間。
    /// 高亮是「最近一次異動」的短暫強調（規格 §3.5），須跨 10Hz 輪詢存活至淡出結束——
    /// 不能像早期版本那樣在 refresh() 裡把它丟掉（否則第一個 poll tick 就消失）。
    private var activeHighlight: SpanUTF16?
    private var highlightStartedAt: CFTimeInterval?

    /// 異動高亮淡出曲線（規格 §3.5「2–3 秒淡出」）。前 holdDuration 秒維持全亮，
    /// 之後 fadeDuration 秒線性淡出到 0；總時長落在 2–3 秒。elapsed 超過總時長回 nil（撤除高亮）。
    /// 純函式、無副作用——把「高亮該亮多久、多亮」的判斷抽出來可單元測試（App 端 overlay 難以無視窗驗證）。
    nonisolated static let highlightHoldDuration: CFTimeInterval = 1.0
    nonisolated static let highlightFadeDuration: CFTimeInterval = 1.5
    nonisolated static func highlightOpacity(elapsed: CFTimeInterval) -> Double? {
        if elapsed < 0 { return 1.0 }
        if elapsed <= highlightHoldDuration { return 1.0 }
        let fadeElapsed = elapsed - highlightHoldDuration
        if fadeElapsed >= highlightFadeDuration { return nil }
        return 1.0 - (fadeElapsed / highlightFadeDuration)
    }

    init(overlay: OverlayWindowController, hud: HUDWindowController) {
        self.overlay = overlay
        self.hud = hud
    }

    // MARK: - SessionFeedbackPresenting

    func sessionUpdated(_ update: FeedbackUpdate) {
        lastUpdate = update
        if let span = update.highlight, span.length > 0 {
            activeHighlight = span                      // 新異動＝重置淡出時鐘（最近一次異動）
            highlightStartedAt = CACurrentMediaTime()
        }
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
        clearHighlight()
    }

    func sessionEnded() {
        stopFollowing()
        overlay.hide()
        lastUpdate = nil
        clearHighlight()
    }

    private func clearHighlight() {
        activeHighlight = nil
        highlightStartedAt = nil
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
        // 異動高亮：由 coordinator 依牆鐘時間驅動淡出（規格 §3.5「2–3 秒淡出」）。
        // 每個 poll frame 重新查座標讓高亮跟隨欄位、並以遞減 opacity 淡出；淡出結束即撤除狀態。
        var highlight: [CGRect] = []
        var highlightOpacity: Double = 0
        if let span = activeHighlight, let started = highlightStartedAt, span.length > 0 {
            if let opacity = Self.highlightOpacity(elapsed: CACurrentMediaTime() - started) {
                if let hlRects = AXFieldAccess.lineRects(element: element,
                                                         location: anchor + span.location,
                                                         utf16Length: span.length) {
                    highlight = hlRects.compactMap { OverlayWindowController.cocoaRect(fromCG: $0) }
                    highlightOpacity = opacity
                }
            } else {
                clearHighlight()                       // 淡出結束：撤除高亮狀態，之後純底線更新
            }
        }
        overlay.show(underline: underline, highlight: highlight, highlightOpacity: highlightOpacity)
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

    /// 重查座標：成功更新（高亮由 render 依 activeHighlight＋牆鐘時間續繪並淡出），
    /// 失敗立刻隱藏並停止跟隨。
    private func refresh() {
        guard let update = lastUpdate, let anchor = update.anchor else { return }
        if !render(update, anchor: anchor) {
            overlay.hide()
            stopFollowing()
        }
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
