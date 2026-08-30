import Foundation
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

    /// 不只測孤立常數：直接展開實際的串流控制 view，確認 SettingsView 的 call site
    /// 確實把這段文案交給 SwiftUI。Mirror 只用來讀 opaque `some View` 內的 Text storage。
    @MainActor @Test func streamingControlsIncludeTheTradeoffNote() {
        let suite = "stream-copy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())

        let controls = GeneralSettingsTab(settings: settings).streamBehaviorControls
        #expect(strings(in: controls).contains(StreamingSettingsText.requiredSegmentsTradeoff))
    }

    private func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 30 else { return [] }
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value, depth: depth + 1) }
    }
}
