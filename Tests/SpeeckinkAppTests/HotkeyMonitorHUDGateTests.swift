import CoreGraphics
import Testing
@testable import SpeeckinkApp

/// 迴歸測試：延續窗／鎖定聽寫下，點自家 HUD 的「復原」鈕不得被當成使用者活動。
/// 否則 leftMouseDown 會先觸發 onUserActivity → userActivityDetected → archiveSession，
/// 使隨後 onTapGesture 排隊觸發的 undoRequested 變成 no-op（規格 §3.3 HUD 常駐復原）。
@Suite struct HotkeyMonitorHUDGateTests {

    private func makeMonitor(capturing: @escaping () -> Bool,
                             onHUD: @escaping (CGPoint) -> Bool) -> HotkeyMonitor {
        let monitor = HotkeyMonitor(hotkey: { .rightCommand }, isCapturing: capturing)
        monitor.isEventOnOwnHUD = onHUD
        return monitor
    }

    @Test func mouseDownOnOwnHUDIsNotUserActivity() {
        // 擷取中（延續窗），點擊落在自家 HUD 上 → 交給復原按鈕，不算使用者活動
        let monitor = makeMonitor(capturing: { true }, onHUD: { _ in true })
        #expect(monitor.shouldEmitUserActivityForMouse(at: CGPoint(x: 100, y: 100)) == false)
    }

    @Test func mouseDownOffHUDIsUserActivity() {
        // 擷取中，點擊落在 HUD 之外（如目標 App）→ 使用者活動（凍結／封存觸發器）
        let monitor = makeMonitor(capturing: { true }, onHUD: { _ in false })
        #expect(monitor.shouldEmitUserActivityForMouse(at: CGPoint(x: 100, y: 100)) == true)
    }

    @Test func mouseDownWhenNotCapturingIsIgnored() {
        // 非擷取中：任何點擊都不算使用者活動
        let monitor = makeMonitor(capturing: { false }, onHUD: { _ in false })
        #expect(monitor.shouldEmitUserActivityForMouse(at: CGPoint(x: 100, y: 100)) == false)
    }

    /// 座標敏感：以「HUD 佔據某矩形」的 stub 驗證同一決策同時看得懂命中與未命中，
    /// 對應真實接線中 HotkeyMonitor.isEventOnOwnHUD → HUDWindowController.containsScreenPoint。
    @Test func hitTestDistinguishesInsideAndOutsideHUDRect() {
        let hudRect = CGRect(x: 200, y: 0, width: 520, height: 44)
        let monitor = makeMonitor(capturing: { true }, onHUD: { hudRect.contains($0) })
        #expect(monitor.shouldEmitUserActivityForMouse(at: CGPoint(x: 210, y: 20)) == false)  // 命中 HUD
        #expect(monitor.shouldEmitUserActivityForMouse(at: CGPoint(x: 210, y: 500)) == true)  // HUD 外
    }
}
