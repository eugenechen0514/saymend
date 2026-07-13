import QuartzCore
import Testing
@testable import SpeeckinkApp

/// 迴歸測試：異動高亮（規格 §3.5「強調高亮＝最近一次異動，2–3 秒淡出」）。
/// 舊實作 refresh() 每個 10Hz poll 丟掉高亮、overlay.show 又全量重建 layer tree，
/// 使黃色高亮只活約一個 poll 週期（~0.1 秒）就被抹掉，遠低於規格。
/// 現改由 FeedbackCoordinator 依牆鐘時間逐 frame 驅動 opacity；淡出曲線抽成純函式在此釘住。
@Suite struct FeedbackHighlightFadeTests {

    @Test func fullyVisibleThroughHoldPhase() {
        #expect(FeedbackCoordinator.highlightOpacity(elapsed: 0) == 1.0)
        #expect(FeedbackCoordinator.highlightOpacity(elapsed: 0.1) == 1.0)   // 舊 bug：0.1s 就被抹掉
        #expect(FeedbackCoordinator.highlightOpacity(elapsed: 1.0) == 1.0)
    }

    @Test func fadesLinearlyAfterHold() {
        let mid = FeedbackCoordinator.highlightOpacity(elapsed: 1.75)        // 淡出中點（hold 1.0 + fade 0.75）
        #expect(mid != nil)
        #expect(abs((mid ?? -1) - 0.5) < 0.001)
    }

    @Test func removedAfterFullDuration() {
        #expect(FeedbackCoordinator.highlightOpacity(elapsed: 2.5) == nil)   // hold 1.0 + fade 1.5 = 2.5s 到頭
        #expect(FeedbackCoordinator.highlightOpacity(elapsed: 3.0) == nil)
    }

    @Test func visibleWellBeyondSinglePollTick() {
        // 迴歸核心：舊實作在第一個 poll tick（~0.1s）高亮就消失；新曲線保證 2 秒後仍看得見
        let at2s = FeedbackCoordinator.highlightOpacity(elapsed: 2.0)
        #expect(at2s != nil)
        #expect((at2s ?? 0) > 0)
    }

    @Test func totalDurationLandsInSpecWindow() {
        // 總時長 = hold + fade，必須落在規格的 2–3 秒
        let total = FeedbackCoordinator.highlightHoldDuration + FeedbackCoordinator.highlightFadeDuration
        #expect(total >= 2.0 && total <= 3.0)
    }
}
