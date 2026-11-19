import AppKit
import SwiftUI

/// 選單列開啟設定視窗的按鈕（「設定…」與核心模式子選單的「管理模式…」共用）。
///
/// 不用 `SettingsLink`：Saymend 是 `LSUIElement`（accessory app），`SettingsLink` 只開視窗、
/// 不會 activate App，設定視窗因此落在使用者目前前景 App 的後面。
/// 也不用 `showSettingsWindow:` selector：macOS 14 起 SwiftUI 不再理會它，視窗根本開不出來。
struct OpenSettingsButton: View {
    let title: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            openSettings()
            // 刻意用 deprecated 的 `activate(ignoringOtherApps:)`：macOS 14 起的 `NSApp.activate()` 是
            // cooperative activation，從選單列點下去時前景 App 不會讓出，實機驗證設定視窗仍留在後面。
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
