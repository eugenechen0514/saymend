import Foundation
import Testing
import SaymendCore
@testable import SaymendApp

@Suite struct ModelLoadStatusTextTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - 經過時間

    @Test func elapsedFormatsAsMinutesAndSeconds() {
        #expect(ModelLoadStatusText.elapsed(0) == "0:00")
        #expect(ModelLoadStatusText.elapsed(9) == "0:09")
        #expect(ModelLoadStatusText.elapsed(75) == "1:15")
        #expect(ModelLoadStatusText.elapsed(631) == "10:31")
    }

    /// 實測有一次載到 1297 秒（21 分 37 秒），而那不是上界——超過一小時完全可能，
    /// 屆時「77:12」讀起來會讓人以為是秒數。
    @Test func elapsedGrowsAnHourFieldWhenNeeded() {
        #expect(ModelLoadStatusText.elapsed(3599) == "59:59")
        #expect(ModelLoadStatusText.elapsed(3600) == "1:00:00")
        #expect(ModelLoadStatusText.elapsed(3600 + 62) == "1:01:02")
    }

    /// 負值（時鐘被往回調）不得印出「-1:-30」這種東西。
    @Test func elapsedClampsNegativeToZero() {
        #expect(ModelLoadStatusText.elapsed(-90) == "0:00")
    }

    // MARK: - 階段清單

    @Test func finishedStageShowsItsDuration() {
        let p = ModelLoadProgress(finished: [.init(stage: .textDecoder, seconds: 104.21)],
                                  currentStage: nil, currentStageStartedAt: nil)
        #expect(ModelLoadStatusText.stageLine(.textDecoder, progress: p, previous: nil, now: t0)
                == "✓ 文字解碼器　1:44")
    }

    /// 耗時未知的階段仍要標成已完成，只是不編一個數字出來。
    @Test func finishedStageWithoutDurationOmitsTheNumber() {
        let p = ModelLoadProgress(finished: [.init(stage: .featureExtractor, seconds: nil)],
                                  currentStage: nil, currentStageStartedAt: nil)
        #expect(ModelLoadStatusText.stageLine(.featureExtractor, progress: p, previous: nil, now: t0)
                == "✓ 特徵擷取器")
    }

    @Test func currentStageShowsElapsedAndLastTimeAsReference() {
        let p = ModelLoadProgress(finished: [], currentStage: .audioEncoder,
                                  currentStageStartedAt: t0.addingTimeInterval(-265))
        let prev = CompletedLoad(total: 631, stages: [.audioEncoder: 527])
        #expect(ModelLoadStatusText.stageLine(.audioEncoder, progress: p, previous: prev, now: t0)
                == "⟳ 音訊編碼器　4:25（上次 8:47）")
    }

    /// 沒有上次紀錄就不附參照——**不得編造**。第一次載入顯示「（上次 0:00）」比不顯示更糟。
    @Test func currentStageWithoutHistoryHasNoReference() {
        let p = ModelLoadProgress(finished: [], currentStage: .audioEncoder,
                                  currentStageStartedAt: t0.addingTimeInterval(-265))
        #expect(ModelLoadStatusText.stageLine(.audioEncoder, progress: p, previous: nil, now: t0)
                == "⟳ 音訊編碼器　4:25")
    }

    @Test func pendingStageIsListedWithoutNumbers() {
        let p = ModelLoadProgress(finished: [], currentStage: .textDecoder,
                                  currentStageStartedAt: t0)
        #expect(ModelLoadStatusText.stageLine(.tokenizer, progress: p, previous: nil, now: t0)
                == "· tokenizer")
    }

    /// 沒有進度資料時（套件升級改掉 log 字串），四個階段都該是待辦樣子，
    /// 而不是把某一個猜成「正在載」。
    @Test func noProgressMeansEveryStageIsPending() {
        for stage in ModelLoadStage.allCases {
            let line = ModelLoadStatusText.stageLine(stage, progress: nil, previous: nil, now: t0)
            #expect(line == "· \(stage.label)")
        }
    }

    // MARK: - 示警門檻

    /// 3 倍不是隨手訂的：實測同機同模型的冷載入散佈就有 2.4 倍（543s → 1297s），
    /// 訂 2 倍會誤殺合法載入，而誤殺的代價（使用者認定模型壞了）比晚示警嚴重得多。
    @Test func warnsOnlyBeyondThreeTimesTheLastRun() {
        #expect(!ModelLoadStatusText.shouldWarn(elapsed: 600, previousTotal: 543))
        #expect(!ModelLoadStatusText.shouldWarn(elapsed: 1297, previousTotal: 543))  // 2.4 倍：實測過
        #expect(!ModelLoadStatusText.shouldWarn(elapsed: 1629, previousTotal: 543))  // 剛好 3 倍
        #expect(ModelLoadStatusText.shouldWarn(elapsed: 1630, previousTotal: 543))
    }

    /// 沒有歷史時沒有任何依據，只剩一個絕對地板。
    @Test func withoutHistoryOnlyTheAbsoluteFloorApplies() {
        #expect(!ModelLoadStatusText.shouldWarn(elapsed: 1799, previousTotal: nil))
        #expect(ModelLoadStatusText.shouldWarn(elapsed: 1801, previousTotal: nil))
    }

    /// 上次是 0（不該發生，但 UserDefaults 什麼都可能被寫進去）不得讓門檻塌成 0，
    /// 否則每一次載入從第一秒就在示警。
    @Test func zeroPreviousTotalFallsBackToTheFloor() {
        #expect(!ModelLoadStatusText.shouldWarn(elapsed: 60, previousTotal: 0))
        #expect(ModelLoadStatusText.shouldWarn(elapsed: 1801, previousTotal: 0))
    }

    /// 示警文案**不得斷言它死了**——我們分不出來，那正是本票的前提。
    @Test func warningDoesNotClaimTheLoadIsDead() {
        let w = ModelLoadStatusText.warning(previousTotal: 527)
        #expect(w.contains("8:47"), "要附上參照數字：\(w)")
        #expect(w.contains("無法從 App 內中止"), "要說清楚為什麼卸載沒用：\(w)")
        #expect(!w.contains("已當機") && !w.contains("已死"), "不得斷言：\(w)")
    }
}
