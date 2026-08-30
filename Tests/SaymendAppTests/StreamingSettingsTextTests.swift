import Testing
import SaymendCore
@testable import SaymendApp

@Suite struct StreamingSettingsTextTests {
    /// 預設值與取捨要一起說清楚：只釘其中一邊，文案與實際行為日後仍可能分岔。
    @Test func requiredSegmentsTradeoffExplainsTheUnchangedDefault() {
        #expect(WhisperStreamingOptions.packageDefault.requiredSegmentsForConfirmation == 2)
        #expect(StreamingSettingsText.requiredSegmentsTradeoff ==
            "數值 1 通常會讓文字在說話時更快上屏，但只留一個片段等待後文修正，錯字可能較早鎖進定稿。"
            + "數值 2 以上保留更多後文，較穩定；典型短句可能主要到結束時才集中上屏。")
    }
}
