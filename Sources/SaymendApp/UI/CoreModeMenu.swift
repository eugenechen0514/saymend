import AppKit
import SwiftUI
import SaymendCore

/// 選單列的核心模式子選單（規格 §4.3）。
/// 所有決策（誰打勾、何時停用）一律委派 `CoreModeMenuModel`——view 不自行判斷。
struct CoreModeMenu: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Menu("核心模式（本次聽寫）") {
            // model 由已解析的有效模式建構（走完整解析鏈，非 raw setting）
            let model = CoreModeMenuModel(
                allModes: delegate.allSelectableModes(),
                active: delegate.currentActiveMode(),
                frontAppBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

            // ── 第一區：點選 = 設 session override（只影響本次 session）
            // 頂部清除項（比照 M4「輸出語系」子選單「跟隨設定：X」）：清掉本次聽寫覆蓋，
            // 讓解析回到 per-app／全域。Option A 純動作按鈕、不帶勾勾——勾勾語意固定在
            // 「解析後的有效模式」上，不是「有沒有 session 覆蓋」。
            Button("跟隨（不覆蓋本次）") { delegate.selectSessionCoreMode(nil) }
            Divider()
            ForEach(model.allModes) { m in
                Button {
                    delegate.selectSessionCoreMode(m.id)
                } label: {
                    Text(model.isChecked(m) ? "✓ \(m.name)" : "   \(m.name)")
                }
            }

            Divider()

            // ── 將目前 App 綁定為某模式（per-app 快速入口；無 frontmost bundle 時停用）
            Menu("將目前 App 綁定為…") {
                ForEach(model.allModes) { m in
                    Button(m.name) { delegate.bindFrontAppToMode(m.id) }
                }
                Divider()
                Button("跟隨全域（解除綁定）") { delegate.bindFrontAppToMode(nil) }
            }
            .disabled(!model.canBindFrontApp)

            // ── 設為全域預設
            Menu("設為全域預設…") {
                ForEach(model.allModes) { m in
                    Button(m.name) { delegate.selectDefaultCoreMode(m.id) }
                }
                Divider()
                Button("使用內建預設（純聽寫整理）") { delegate.selectDefaultCoreMode(nil) }
            }

            Divider()
            Button("管理模式…") { delegate.openCoreModeSettings() }
        }
    }
}
