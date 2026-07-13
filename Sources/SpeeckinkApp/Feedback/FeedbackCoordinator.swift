import AppKit
import ApplicationServices
import SpeeckinkCore
import os.log

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
    /// 本 session 的目標欄位元素：首次繪製時釘定。App 內 Tab 換欄位不觸發活動偵測，
    /// session 不會封存，但焦點已不在原欄位——此時必須隱藏而非照 stale anchor 亂畫
    /// （鐵律：寧可不顯示，不可畫錯位置，規格 §3.5；終審 finding）。
    private var sessionElement: AXUIElement?
    /// 連續繪製失敗計數與本 session 放棄旗標。
    /// 鍵入走 CGEvent 事件佇列，sessionUpdated 當下文字常尚未落地——首繪失敗是**時序常態**，
    /// 不是能力問題（能力用參數化屬性清單探測）。失敗→隱藏＋靠 10Hz 輪詢重試；
    /// 連續失敗 10 次（約 1 秒）仍畫不出來才對本 session 放棄、降級 HUD diff。
    private var consecutiveRenderFailures = 0
    private var overlayGaveUp = false
    private static let giveUpThreshold = 10
    private static let logger = Logger(subsystem: "io.speeckink.app", category: "feedback")
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
        if overlayGaveUp {                             // 本 session 已放棄 overlay：維持 diff 降級
            diffFallback(update)
            return
        }
        guard adoptOrVerifySessionElement() else {
            overlay.hide()                             // 焦點不在 session 欄位：不畫，也不判定能力
            return
        }
        // 能力＝該元素是否宣告 BoundsForRange 參數化屬性（一次探測入快取）。
        // 不可用「首繪成敗」判能力：鍵入是非同步落地，首繪查座標常跑在文字之前（時序，非能力）。
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if capability[bundle] == nil, let element = sessionElement {
            capability[bundle] = Self.supportsBoundsForRange(element)
            Self.logger.debug("能力探測 \(bundle, privacy: .public)：BoundsForRange=\(self.capability[bundle] ?? false)")
        }
        guard capability[bundle] == true else {
            diffFallback(update)
            return
        }
        startFollowing()                               // 輪詢即重試引擎：文字落地後自動補畫
        if render(update, anchor: anchor) {
            consecutiveRenderFailures = 0
        } else {
            overlay.hide()                             // 鐵律：跟不上先隱藏，讓 poll 補
            noteRenderFailure()
        }
    }

    func sessionFrozen() {
        stopFollowing()
        overlay.fadeOutAndHide()                       // 凍結：底線淡出（規格 §3.5）
        lastUpdate = nil
        sessionElement = nil
        clearHighlight()
        resetRenderHealth()
    }

    func sessionEnded() {
        stopFollowing()
        overlay.hide()
        lastUpdate = nil
        sessionElement = nil
        clearHighlight()
        resetRenderHealth()
    }

    private func resetRenderHealth() {
        consecutiveRenderFailures = 0
        overlayGaveUp = false
    }

    /// 連續失敗約 1 秒仍畫不出＝該欄位雖宣告能力但回不了可用座標：本 session 放棄 overlay、
    /// 降級 HUD diff（不寫能力快取——下個 session 重新來過）。
    private func noteRenderFailure() {
        consecutiveRenderFailures += 1
        guard consecutiveRenderFailures >= Self.giveUpThreshold, !overlayGaveUp else { return }
        overlayGaveUp = true
        overlay.hide()
        stopFollowing()
        Self.logger.debug("overlay 連續 \(Self.giveUpThreshold) 次繪製失敗，本 session 降級 HUD diff")
        if let update = lastUpdate { diffFallback(update) }
    }

    /// 元素是否宣告 kAXBoundsForRangeParameterizedAttribute（能力探測）
    private static func supportsBoundsForRange(_ element: AXUIElement) -> Bool {
        var namesRef: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return false }
        return names.contains(kAXBoundsForRangeParameterizedAttribute as String)
    }

    /// 首次呼叫＝把目前聚焦元素釘為 session 目標；之後＝驗證焦點仍在同一元素。
    /// CFEqual 比較 AXUIElement 的底層 token（同一元素的兩個 wrapper 相等）。
    private func adoptOrVerifySessionElement() -> Bool {
        guard let focused = AXFieldAccess.focusedElement() else { return false }
        if let pinned = sessionElement { return CFEqual(focused, pinned) }
        sessionElement = focused
        return true
    }

    private func clearHighlight() {
        activeHighlight = nil
        highlightStartedAt = nil
    }

    // MARK: - 繪製

    /// 回傳是否成功畫出。查詢失敗一律 false（呼叫端決定隱藏／降級）。
    /// 一律畫在釘定的 session 元素上（呼叫端已用 adoptOrVerifySessionElement 驗過焦點）。
    private func render(_ update: FeedbackUpdate, anchor: Int) -> Bool {
        guard let element = sessionElement else { return false }
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
        guard adoptOrVerifySessionElement() else {
            overlay.hide()                             // 焦點移走（如 App 內 Tab）：立即隱藏
            stopFollowing()
            return
        }
        if render(update, anchor: anchor) {
            consecutiveRenderFailures = 0
        } else {
            overlay.hide()                             // 暫時跟不上：隱藏但續 poll，落地即補畫
            noteRenderFailure()
        }
    }

    private func installAXObserverIfNeeded() {
        guard axObserver == nil,
              let app = NSWorkspace.shared.frontmostApplication,
              let element = sessionElement else { return }
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
