import Foundation
import SwiftUI
import Testing
import SaymendCore
@testable import SaymendApp

@Suite struct StreamingSettingsTextTests {
    /// 預設值與取捨要一起說清楚：只釘其中一邊，文案與實際行為日後仍可能分岔。
    @Test func requiredSegmentsTradeoffExplainsTheUnchangedDefault() {
        #expect(WhisperStreamingOptions.packageDefault.requiredSegmentsForConfirmation == 2)
        #expect(StreamingSettingsText.requiredSegmentsTradeoff ==
            "累積出多個片段時，數值 1 通常會讓文字在說話中較快上屏，但只留一個尾端片段等待後文修正，錯字可能較早鎖進定稿。"
            + "數值愈高，保留的尾端片段愈多、較穩定，但短句更可能到結束時才集中上屏；"
            + "只切成一個片段的短句，設 1 或 2 都會等到結束。")
    }

    @Test func escapeRetractionCopyStatesBothDefaultsAndTheFrozenRisk() {
        #expect(EscapeRetractionSettingsText.polishedExplanation ==
            "預設開啟。聽寫仍在進行時按 Esc，會退掉本次已上屏的全部文字，包含已潤飾的部分。關閉時保留已經潤飾落定的文字。若目前 App 無法驗證原欄位，為避免刪錯字會保留內容並提示。")
        #expect(EscapeRetractionSettingsText.frozenExplanation ==
            "預設關閉以遵守凍結後不再改寫的原則。開啟後，Esc 可能連你凍結後自己輸入的內容一起刪掉，而且無法復原。")
    }

    @MainActor @Test func escapeRetractionToggleBindingsWriteTheirMatchingSettings() {
        let suite = "escape-bindings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let polished = EscapeRetractionSetting.polishedText.binding(to: settings)
        let frozen = EscapeRetractionSetting.frozenSession.binding(to: settings)
        #expect(polished.wrappedValue && !frozen.wrappedValue)
        polished.wrappedValue = false
        frozen.wrappedValue = true
        #expect(!settings.escapeRetractsPolishedText)
        #expect(settings.escapeRetractsFrozenSession)
        #expect(defaults.object(forKey: "escapeRetractsPolishedText") as? Bool == false)
        #expect(defaults.object(forKey: "escapeRetractsFrozenSession") as? Bool == true)
    }

    /// 從 production `SettingsView.body` 確認一般分頁仍有接線且未被 hidden，再展開真正的
    /// `GeneralSettingsTab.body`（包含所有 onChange）尋找 Toggle label 與說明 Text。
    /// 不能只建構最內層 child，否則 body/call site 被移除仍會假綠。
    @MainActor @Test func settingsViewContainsVisibleEscapeRetractionWarnings() {
        let suite = "escape-copy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let settingsBody = SettingsView(settings: settings).body
        #expect(containsUnhiddenType(named: "SaymendApp.GeneralSettingsTab", in: settingsBody))

        let tabBody = GeneralSettingsTab(settings: settings).body
        let visible = unhiddenTextStrings(in: tabBody)
        #expect(visible.contains("Esc 一併退掉已潤飾文字"))
        #expect(visible.contains("凍結後按 Esc 仍退字"))
        #expect(visible.contains(EscapeRetractionSettingsText.polishedExplanation))
        #expect(visible.contains(EscapeRetractionSettingsText.frozenExplanation))

        let hiddenAtCallSite = Group { GeneralSettingsTab(settings: settings).body.hidden() }
        #expect(!unhiddenTextStrings(in: hiddenAtCallSite)
            .contains(EscapeRetractionSettingsText.frozenExplanation))
        let hiddenFromSettingsView = Group { GeneralSettingsTab(settings: settings).hidden() }
        #expect(!containsUnhiddenType(named: "SaymendApp.GeneralSettingsTab", in: hiddenFromSettingsView))
    }

    /// 不只找 opaque tree 裡的任意 String：該字串必須位在真正的 `Text` storage，
    /// 且祖先不能有 SwiftUI `_HiddenModifier`。這個 seam 精確守 `.id(text)` 與 `.hidden()`，
    /// 不宣稱取代 screenshot test 判斷 opacity、遮擋等一般像素可見性。
    @MainActor @Test func streamAdvancedSectionContainsUnhiddenTradeoffText() {
        let suite = "stream-copy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        let tab = GeneralSettingsTab(settings: settings)

        // 從含真正 call site 的 DisclosureGroup subtree 進入；不能只測被插入的 child。
        let section = tab.streamAdvancedSection
        #expect(unhiddenTextStrings(in: section).contains(StreamingSettingsText.requiredSegmentsTradeoff))

        // 若真正 call site 寫成 `streamBehaviorControls.hidden()`，oracle 必須把文案排除。
        let hiddenAtCallSite = Group { tab.streamBehaviorControls.hidden() }
        #expect(!unhiddenTextStrings(in: hiddenAtCallSite)
            .contains(StreamingSettingsText.requiredSegmentsTradeoff))

        // hidden sibling 的 generic type 會出現在共同 container 名稱裡，但不得把 visible sibling 誤殺。
        let siblingOracle = VStack { Text("visible sibling"); Text("hidden sibling").hidden() }
        #expect(unhiddenTextStrings(in: siblingOracle).contains("visible sibling"))
        #expect(!unhiddenTextStrings(in: siblingOracle).contains("hidden sibling"))
    }

    private func containsUnhiddenType(named expected: String,
                                      in value: Any,
                                      hiddenByAncestor: Bool = false,
                                      depth: Int = 0) -> Bool {
        guard depth < 40 else { return false }
        let mirror = Mirror(reflecting: value)
        let directlyHidden = mirror.children.contains {
            $0.label == "modifier"
                && String(reflecting: Swift.type(of: $0.value)) == "SwiftUI._HiddenModifier"
        }
        let hidden = hiddenByAncestor || directlyHidden
        if String(reflecting: Swift.type(of: value)) == expected { return !hidden }
        return mirror.children.contains {
            containsUnhiddenType(named: expected, in: $0.value,
                                 hiddenByAncestor: hidden, depth: depth + 1)
        }
    }

    private func unhiddenTextStrings(in value: Any,
                                     hiddenByAncestor: Bool = false,
                                     depth: Int = 0) -> [String] {
        guard depth < 120 else { return [] }
        let mirror = Mirror(reflecting: value)
        let directlyHidden = mirror.children.contains {
            $0.label == "modifier"
                && String(reflecting: Swift.type(of: $0.value)) == "SwiftUI._HiddenModifier"
        }
        let hidden = hiddenByAncestor || directlyHidden
        if value is Text { return hidden ? [] : embeddedStrings(in: value) }
        return mirror.children.flatMap {
            unhiddenTextStrings(in: $0.value, hiddenByAncestor: hidden, depth: depth + 1)
        }
    }

    private func embeddedStrings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap {
            embeddedStrings(in: $0.value, depth: depth + 1)
        }
    }
}
