import AppKit
import SwiftUI
import SaymendCore

/// HUD 浮條視窗（規格 §3.1 鐵律：絕不搶鍵盤焦點 → .nonactivatingPanel）。
/// notice 顯示 2.5 秒後自動隱藏。
final class HUDWindowController: HUDPresenting {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// notice 自動隱藏後要回復的持久狀態：延續窗（lingering）期間的 notice（已修正／已復原…）
    /// 不能把「可修正＋復原鈕」整個藏掉——listening 靠 volatile 事件自然回復，lingering 得手動回復。
    private var persistentState: HUDState = .hidden
    /// SwiftUI 內容最近一次回報的實際尺寸；套用一律取最新值，過期回報自然收斂
    private var pendingContentSize: CGSize?

    init() {
        // 視窗尺寸手動貼齊內容（onGeometryChange 回報）。回報發生在 SwiftUI layout 期間，
        // 當下動視窗 frame 會重入 AppKit 的 update-constraints pass——macOS 26 對此直接丟
        // NSGenericException（保險絲：pass 次數超過視窗內 view 數）。故一律 async 跳出後再套用。
        model.onContentSizeChange = { [weak self] size in
            guard let self else { return }
            self.pendingContentSize = size
            DispatchQueue.main.async { self.applyContentSize() }
        }
    }

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
        case .listening, .lingering, .selectionListening, .transcribing:
            persistentState = state
            show()
        case .notice, .diff:
            show()
            let duration: Duration = { if case .diff = state { return .milliseconds(4000) }
                                       return .milliseconds(2500) }()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: duration)
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
        // 狀態切換後內容尺寸可能已變；就算 onGeometryChange 因尺寸相同不再回報，也要補一次貼齊
        DispatchQueue.main.async { [weak self] in self?.applyContentSize() }
    }

    /// 把視窗貼齊內容膠囊的實際尺寸並重新置中。視窗緊貼內容是 containsScreenPoint 的
    /// 語意基礎（判「點在 HUD 上」不能把透明邊當自家），不能改成固定大視窗置中內容。
    private func applyContentSize() {
        guard let panel, panel.isVisible, let size = pendingContentSize else { return }
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        positionAtBottomCenter()
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: HUDView(model: model))
        // 鐵律：不讓 NSHostingView 以 autolayout 約束驅動視窗尺寸（macOS 26 會在 layout pass
        // 內重入 update-constraints 觸發 NSGenericException 崩潰）。尺寸走 applyContentSize。
        hosting.sizingOptions = []
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
