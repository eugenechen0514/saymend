import AppKit
import SwiftUI
import SpeeckinkCore

/// HUD 浮條視窗（規格 §3.1 鐵律：絕不搶鍵盤焦點 → .nonactivatingPanel）。
/// notice 顯示 2.5 秒後自動隱藏。
final class HUDWindowController: HUDPresenting {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// notice 自動隱藏後要回復的持久狀態：延續窗（lingering）期間的 notice（已修正／已復原…）
    /// 不能把「可修正＋復原鈕」整個藏掉——listening 靠 volatile 事件自然回復，lingering 得手動回復。
    private var persistentState: HUDState = .hidden

    /// HUD 復原按鈕回呼（app 組裝時指到 controller.undoRequested）
    var onUndoTap: (() -> Void)? {
        get { model.onUndoTap }
        set { model.onUndoTap = newValue }
    }

    func present(_ state: HUDState) {
        assert(Thread.isMainThread)
        model.state = state
        hideTask?.cancel()
        switch state {
        case .hidden:
            persistentState = .hidden
            panel?.orderOut(nil)
        case .listening, .lingering:
            persistentState = state
            show()
        case .notice:
            show()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled, let self else { return }
                if case .lingering = self.persistentState {
                    self.model.state = .lingering   // 延續窗還有效：把「可修正／復原」顯示回來
                    self.show()
                } else {
                    self.model.state = .hidden
                    self.panel?.orderOut(nil)
                }
            }
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    /// 判斷 CG 全域座標點（原點左上、Y 向下，來自 CGEvent.location）是否落在可見的 HUD 面板上。
    /// CG 全域座標與 Cocoa 全域座標共用主螢幕原點，僅 Y 軸翻轉：cocoaY = 主螢幕高度 − cgY。
    func containsScreenPoint(_ cgPoint: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let cocoaPoint = NSPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        return panel.frame.contains(cocoaPoint)
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        positionAtBottomCenter()
        panel?.orderFrontRegardless()   // 不 activate、不搶焦點
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: HUDView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private func positionAtBottomCenter() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 24
        ))
    }
}
