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
        // issue #71：跨 session 的剪貼簿救援會覆寫上一段；被覆寫的那段從這裡找回。沒有救援過就不出現。
        if !delegate.recentRescues.isEmpty {
            Menu("最近救援") {
                Text("點選即複製回剪貼簿")
                Divider()
                ForEach(delegate.recentRescues, id: \.id) { rescue in
                    Button(RecentRescueMenuText.title(text: rescue.text, at: rescue.at)) {
                        delegate.copyRecentRescue(rescue)
                    }
                }
            }
        }
        OpenSettingsButton(title: "設定…")
        #if DEBUG
        // 這顆會把測試字串打進當下聚焦的任何欄位，正式版不得出現在選單。
        // （「測試替換」已隨 issue #44 移除：沒有 session／AX 的臨時 coordinator 不再能做任何替換。）
        Button("測試插入（2 秒後打進聚焦欄位）") { delegate.debugInsert() }
        #endif
        Divider()
        Button("結束 Saymend") { NSApp.terminate(nil) }
    }
}

/// 「最近救援」選單項目的文字（issue #71）：時間＋內容開頭。換行與連續空白收成一個空白，過長截斷加「…」。
enum RecentRescueMenuText {
    static let snippetLength = 24

    static func title(text: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: date))  \(snippet(text))"
    }

    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > snippetLength else { return flat }
        return String(flat.prefix(snippetLength)) + "…"
    }
}
