import Foundation
import SwiftUI
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #46：兩個 Esc 設定的 Settings UI。title、說明、persistence Binding 由同一個 descriptor 產生。
@Suite struct EscapeRetractionSettingsUITests {
    /// 文案要把預設值與風險一起說清楚：只釘其中一邊，文案與實際行為日後仍可能分岔。
    @Test func copyStatesBothDefaultsAndTheFrozenRisk() {
        #expect(EscapeRetractionSettingsText.polishedExplanation ==
            "預設開啟：聽寫中按 Esc 會退掉本次上屏的全部文字，包含已潤飾的部分。"
            + "關閉時只退掉尚未潤飾的原始轉錄，保留已潤飾落定的文字。"
            + "無法確認原欄位時一律不動文字、只提示。")
        #expect(EscapeRetractionSettingsText.frozenExplanation ==
            "預設關閉：你手動編輯過（已凍結）後，Esc 只結束聽寫、不動欄位。"
            + "開啟後 Esc 仍會退掉本次聽寫寫入的範圍；你在其後手打的文字保留，打進範圍內則不退、只提示。")
    }

    /// 兩個 Toggle 的 Binding 各寫各的 key，而且是 AppSettings 的那兩個 key（不是各自另存一份）。
    @MainActor @Test func toggleBindingsWriteTheirMatchingSettings() {
        let suite = "escape-bindings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let polished = EscapeRetractionSetting.polishedText.binding(to: settings)
        let frozen = EscapeRetractionSetting.frozenSession.binding(to: settings)
        #expect(polished.wrappedValue && !frozen.wrappedValue)          // 預設值透過 Binding 可見
        polished.wrappedValue = false
        #expect(!settings.escapeRetractsPolishedText && !settings.escapeRetractsFrozenSession, "沒接反")
        frozen.wrappedValue = true
        #expect(!settings.escapeRetractsPolishedText && settings.escapeRetractsFrozenSession)
        #expect(defaults.object(forKey: "escapeRetractsPolishedText") as? Bool == false)
        #expect(defaults.object(forKey: "escapeRetractsFrozenSession") as? Bool == true)
    }

    /// 從 production `SettingsView.body` 確認一般分頁仍接線且未被 hidden，再展開真正的
    /// `GeneralSettingsTab.body`（含所有 onChange）找 Toggle label 與說明 Text。
    /// 不能只建構最內層 child，否則 body／call site 被移除仍會假綠（`.id(<字串>)` 與 `.hidden()` 的教訓）。
    @MainActor @Test func generalTabShowsBothTogglesWithVisibleExplanations() {
        let suite = "escape-copy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let settingsBody = SettingsView(settings: settings).body
        #expect(ViewTreeInspection.containsUnhiddenType(named: "SaymendApp.GeneralSettingsTab", in: settingsBody))

        let visible = ViewTreeInspection.unhiddenTextStrings(in: GeneralSettingsTab(settings: settings).body)
        for option in EscapeRetractionSetting.allCases {
            #expect(visible.contains(option.title), "缺 Toggle：\(option)")
            #expect(visible.contains(option.explanation), "缺說明：\(option)")
        }

        // oracle：call site 若被 .hidden()，同一個 helper 必須把文案排除；hidden 的分頁也不得算接線
        let hiddenTab = Group { GeneralSettingsTab(settings: settings).body.hidden() }
        #expect(!ViewTreeInspection.unhiddenTextStrings(in: hiddenTab).contains(EscapeRetractionSettingsText.frozenExplanation))
        let hiddenInShell = Group { GeneralSettingsTab(settings: settings).hidden() }
        #expect(!ViewTreeInspection.containsUnhiddenType(named: "SaymendApp.GeneralSettingsTab", in: hiddenInShell))
    }
}
