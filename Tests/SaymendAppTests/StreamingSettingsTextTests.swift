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

    /// 不只找 opaque tree 裡的任意 String：該字串必須位在真正的 `Text` storage，
    /// 且祖先不能有 SwiftUI `_HiddenModifier`。因此 `.id(text)` metadata 與 `.hidden()` 都不算。
    @MainActor @Test func streamingControlsContainVisibleTradeoffText() {
        let suite = "stream-copy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let controls = GeneralSettingsTab(settings: settings).streamBehaviorControls
        #expect(visibleTextStrings(in: controls).contains(StreamingSettingsText.requiredSegmentsTradeoff))
    }

    private func visibleTextStrings(in value: Any,
                                    hiddenByAncestor: Bool = false,
                                    depth: Int = 0) -> [String] {
        guard depth < 40 else { return [] }
        let typeName = String(reflecting: Swift.type(of: value))
        let hidden = hiddenByAncestor || typeName.contains("_HiddenModifier")
        if value is Text { return hidden ? [] : embeddedStrings(in: value) }
        return Mirror(reflecting: value).children.flatMap {
            visibleTextStrings(in: $0.value, hiddenByAncestor: hidden, depth: depth + 1)
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
