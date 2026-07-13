import AppKit
import SwiftUI
import SpeeckinkCore

/// HUD 浮條視窗（規格 §3.1 鐵律：絕不搶鍵盤焦點 → .nonactivatingPanel）。
/// notice 顯示 2.5 秒後自動隱藏。
final class HUDWindowController: HUDPresenting {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func present(_ state: HUDState) {
        assert(Thread.isMainThread)
        model.state = state
        hideTask?.cancel()
        switch state {
        case .hidden:
            panel?.orderOut(nil)
        case .listening:
            show()
        case .lingering:
            show()
        case .notice:
            show()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled else { return }
                self?.model.state = .hidden
                self?.panel?.orderOut(nil)
            }
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
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
