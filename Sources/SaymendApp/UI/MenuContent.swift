import AppKit
import SwiftUI
import SaymendCore

struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Text(delegate.statusLine)
        Divider()
        Menu("輸出語系（本次聽寫）") {
            Button("跟隨設定：\(delegate.settings.outputLanguage.displayName)") {
                delegate.settings.sessionLanguageOverride = nil
            }
            Divider()
            ForEach(OutputLanguage.allCases, id: \.self) { lang in
                Button(lang.displayName) {
                    delegate.settings.sessionLanguageOverride = lang
                }
            }
        }
        CoreModeMenu(delegate: delegate)      // M5 新增
        SettingsLink { Text("設定…") }
        #if DEBUG
        // 這顆會把測試字串打進當下聚焦的任何欄位，正式版不得出現在選單。
        // （「測試替換」已隨 issue #44 移除：沒有 session／AX 的臨時 coordinator 不再能做任何替換。）
        Button("測試插入（2 秒後打進聚焦欄位）") { delegate.debugInsert() }
        #endif
        Divider()
        Button("結束 Saymend") { NSApp.terminate(nil) }
    }
}
