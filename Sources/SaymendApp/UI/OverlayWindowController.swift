import AppKit

/// 視覺回饋層視窗（規格 §3.5）：全透明、完全 click-through 的無邊框浮窗，蓋在目標欄位上畫記號。
/// 鐵律：純 CALayer 手動 frame——不用 SwiftUI/NSHostingView（macOS 26 autolayout 視窗尺寸
/// 約束會在 layout pass 重入 update-constraints 而崩潰，見 HUDWindowController 同款教訓）。
/// ignoresMouseEvents＝點 overlay 區域＝點目標 App＝使用者活動凍結，語意天然正確，
/// 無需納入 HotkeyMonitor 的 isEventOnOwnHUD 判定。
final class OverlayWindowController {
    private var window: NSWindow?
    private var contentLayer: CALayer?

    /// AX 回的 CG 螢幕座標（原點左上、Y 向下）→ Cocoa 螢幕座標（原點左下、Y 向上）。
    /// 兩者共用主螢幕原點，僅 Y 軸翻轉（同 HUDWindowController.containsScreenPoint 的換算）。
    static func cocoaRect(fromCG rect: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: rect.origin.x,
                      y: primaryHeight - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }

    /// 依 Cocoa 螢幕座標畫底線（每行一條，貼行底）與異動高亮。
    /// 高亮的淡出（規格 §3.5「2–3 秒淡出」）由 FeedbackCoordinator 依牆鐘時間逐 frame 驅動——
    /// 每個 10Hz poll 傳入遞減的 highlightOpacity，overlay 只是把它畫成靜態透明度。
    /// 早期版本在此掛 CABasicAnimation 淡出，但 show() 每 frame 全量重建 layer tree（見下），
    /// 動畫還沒開始就連 layer 一起被丟棄，高亮只活一個 poll 週期（~0.1 秒），遠低於規格。
    func show(underline: [CGRect], highlight: [CGRect], highlightOpacity: Double) {
        assert(Thread.isMainThread)
        guard !underline.isEmpty else { hide(); return }

        let padding: CGFloat = 6
        let union = underline.dropFirst().reduce(underline[0]) { $0.union($1) }
            .union(highlight.dropFirst().reduce(highlight.first ?? underline[0]) { $0.union($1) })
            .insetBy(dx: -padding, dy: -padding)

        if window == nil { window = Self.makeWindow() }
        guard let window, let host = window.contentView else { return }
        window.setFrame(union, display: false)

        // 全量重建 sublayers（數量小，重建比 diff 簡單可靠）
        let root = CALayer()
        root.frame = host.bounds
        for rect in underline {
            let local = CGRect(x: rect.origin.x - union.origin.x,
                               y: rect.origin.y - union.origin.y,
                               width: rect.width, height: rect.height)
            let line = CALayer()
            line.frame = CGRect(x: local.minX, y: local.minY - 1, width: local.width, height: 2)
            line.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            line.cornerRadius = 1
            root.addSublayer(line)
        }
        for rect in highlight {
            let local = CGRect(x: rect.origin.x - union.origin.x,
                               y: rect.origin.y - union.origin.y,
                               width: rect.width, height: rect.height)
            let glow = CALayer()
            glow.frame = local.insetBy(dx: -1, dy: -1)
            glow.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
            glow.cornerRadius = 3
            // 淡出：coordinator 依牆鐘算好的透明度（新 layer 初值不觸發 CA 隱式動畫）
            glow.opacity = Float(min(1, max(0, highlightOpacity)))
            root.addSublayer(glow)
        }
        host.layer = root
        host.wantsLayer = true
        contentLayer = root
        root.opacity = 1
        window.orderFrontRegardless()
    }

    /// 凍結：底線淡出後隱藏（規格 §3.5「session 凍結時淡出」）
    func fadeOutAndHide() {
        assert(Thread.isMainThread)
        guard let window, window.isVisible, let layer = contentLayer else { hide(); return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.hide() }
        layer.add(fade, forKey: "freezeFade")
        CATransaction.commit()
    }

    func hide() {
        assert(Thread.isMainThread)
        window?.orderOut(nil)
        contentLayer = nil
    }

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                  // 完全 click-through（規格 §3.5）
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSView()
        w.contentView?.wantsLayer = true
        return w
    }
}
