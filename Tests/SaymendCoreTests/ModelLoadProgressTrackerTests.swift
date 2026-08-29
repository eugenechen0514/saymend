import Foundation
import Testing
@testable import SaymendCore

/// 可控時鐘：測試自己推進，不睡真實時間（比照 `DictationController` 的 `now:` 注入慣例）
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1000)
    var now: @Sendable () -> Date { { self.lock.lock(); defer { self.lock.unlock() }; return self.t } }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func append(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite struct ModelLoadProgressTrackerTests {

    /// 從未收到任何訊息時是 nil。「沒有進度資料」與「進度為空」是兩件事——
    /// 設定頁靠這個差別決定要不要顯示階段清單，用空值假裝有資料會憑空多出一份四階段清單。
    @Test func snapshotIsNilBeforeAnyMessage() {
        #expect(ModelLoadProgressTracker(now: Date.init).snapshot() == nil)
    }

    @Test func stagesAdvanceInOrder() {
        let c = TestClock()
        let t = ModelLoadProgressTracker(now: c.now)

        t.ingest("Loading models...")
        #expect(t.snapshot()?.currentStage == nil)            // 開始了，但還沒進到任何階段
        #expect(t.snapshot()?.finished.isEmpty == true)

        t.ingest("Loading text decoder")
        #expect(t.snapshot()?.currentStage == .textDecoder)
        #expect(t.snapshot()?.currentStageStartedAt == c.now())

        c.advance(104.21)
        t.ingest("Loaded text decoder in 104.21s")
        #expect(t.snapshot()?.currentStage == nil)            // 階段結束就不該還顯示「正在載」
        #expect(t.snapshot()?.finished == [.init(stage: .textDecoder, seconds: 104.21)])

        t.ingest("Loading audio encoder")
        #expect(t.snapshot()?.currentStage == .audioEncoder)
        #expect(t.snapshot()?.finished.count == 1)            // 已完成的不會被下一階段沖掉
    }

    /// 階段開始的時刻要是**該階段**開始的時刻，不是整趟載入開始的時刻——
    /// 兩者混用會讓最長的那一段（音訊編碼器）顯示成從頭算起，數字直接翻倍。
    @Test func stageStartIsTheStageNotTheWholeRun() {
        let c = TestClock()
        let t = ModelLoadProgressTracker(now: c.now)
        t.ingest("Loading models...")
        let runStart = c.now()
        c.advance(60)
        t.ingest("Loading audio encoder")
        #expect(t.snapshot()?.currentStageStartedAt == runStart.addingTimeInterval(60))
    }

    /// 連續兩個「開始」中間沒有「結束」時，起點仍要換成後者的。
    ///
    /// 這不是假想情境：只要套件哪次升級把某一則 `Loaded X` 改掉，解析器就會少收一則結束，
    /// 於是兩個開始背靠背進來。此時若沿用前一階段的起點，音訊編碼器那一段
    /// （實測最久，527 秒）顯示的就是從頭算起的秒數——正好是最需要準的那一格最不準。
    @Test func consecutiveStageBeginsMoveTheStartForward() {
        let c = TestClock()
        let t = ModelLoadProgressTracker(now: c.now)
        t.ingest("Loading models...")
        t.ingest("Loading text decoder")
        c.advance(104)
        t.ingest("Loading audio encoder")            // 少了 `Loaded text decoder in …`
        #expect(t.snapshot()?.currentStage == .audioEncoder)
        #expect(t.snapshot()?.currentStageStartedAt == c.now())
    }

    /// 第二趟載入不得帶著上一趟的殘骸。
    @Test func loadBeganResetsPreviousRun() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loading text decoder")
        t.ingest("Loaded text decoder in 1.0s")
        t.ingest("Loading models...")
        #expect(t.snapshot()?.finished.isEmpty == true)
        #expect(t.snapshot()?.currentStage == nil)
    }

    /// `beginLoad()` 是 loader 明確的重置點。存在的理由：字串解析可能因套件升級而失效，
    /// 但「新的一趟開始了」這件事 loader 自己知道，不該外包給 log 字串。
    @Test func beginLoadResetsWithoutRelyingOnLogStrings() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loading models...")
        t.ingest("Loaded text decoder in 1.0s")
        t.ingest("Loaded models for whisper size: x in 2.0s")
        t.beginLoad()
        #expect(t.snapshot()?.finished.isEmpty == true)
        #expect(t.completedLoad() == nil)                     // 上一趟的成績也要清掉
    }

    /// 完成後要交得出「每階段各花多久、總共多久」——那是寫進歷史當下次參照的原料。
    @Test func completedLoadCarriesTotalAndStages() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loading models...")
        t.ingest("Loaded text decoder in 104.21s")
        t.ingest("Loaded audio encoder in 526.64s")
        t.ingest("Loaded models for whisper size: large-v3 in 631.34s")
        let done = t.completedLoad()
        #expect(done?.total == 631.34)
        #expect(done?.stages[.textDecoder] == 104.21)
        #expect(done?.stages[.audioEncoder] == 526.64)
    }

    /// 沒收到總結就沒有完整的一趟——不得拿階段時間硬湊出一個 total 冒充。
    /// 湊出來的數字會被寫進歷史，下一次載入就拿一個假的參照去嚇使用者。
    @Test func noCompletedLoadWithoutTheTotalMessage() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loading models...")
        t.ingest("Loaded text decoder in 104.21s")
        #expect(t.completedLoad() == nil)
    }

    /// 沒帶耗時的那一則（特徵擷取器）仍要計入已完成，只是耗時未知。
    @Test func stageWithoutSecondsStillCounts() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loaded feature extractor")
        #expect(t.snapshot()?.finished == [.init(stage: .featureExtractor, seconds: nil)])
    }

    /// 只收到認不得的訊息時，snapshot 仍要是 nil。
    ///
    /// 這是刻意的降級路徑：套件升級把字串全改掉時，UI 要退回純碼表，
    /// 而不是顯示一份永遠停在「四個階段都還沒開始」的假清單。
    @Test func snapshotStaysNilWhenNothingIsRecognised() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Running on Mac")
        t.ingest("Some future message we do not know")
        #expect(t.snapshot() == nil)
    }

    /// 耗時未知的階段不得以 0 混進歷史。0 會被當成「上次只花了 0:00」，
    /// 於是示警門檻（上次的 3 倍）瞬間就被跨過，每一次載入都在示警。
    @Test func stageWithUnknownSecondsIsNotRecordedAsZero() {
        let t = ModelLoadProgressTracker(now: Date.init)
        t.ingest("Loading models...")
        t.ingest("Loaded feature extractor")          // 這一則不帶耗時
        t.ingest("Loaded models for whisper size: x in 3.0s")
        #expect(t.completedLoad()?.stages[.featureExtractor] == nil)
        #expect(t.completedLoad()?.total == 3.0)
    }

    /// 訊息要原樣轉發，**認不得的也要**。裝了 callback 之後套件就不再寫系統 logger
    /// （`Logging.log`：`if let callback { callback(m) } else { logger.log(...) }`），
    /// 只轉發認得的等於把開發者查錯用的其餘資料弄不見。
    @Test func everyMessageIsForwardedIncludingUnrecognisedOnes() {
        let box = MessageBox()
        let t = ModelLoadProgressTracker(now: Date.init, forward: { box.append($0) })
        t.ingest("Loading models...")
        t.ingest("Running on Mac")
        #expect(box.all == ["Loading models...", "Running on Mac"])
    }
}

@Suite struct ModelLoadRunTests {
    private func makeHistory() -> (ModelLoadHistory, () -> Void) {
        let name = "io.saymend.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (ModelLoadHistory(defaults: d), { d.removePersistentDomain(forName: name) })
    }

    private struct Boom: Error {}

    @Test func recordsHistoryOnSuccess() async throws {
        let (history, cleanup) = makeHistory(); defer { cleanup() }
        let tracker = ModelLoadProgressTracker(now: Date.init)
        let url = URL(filePath: "/m/a")
        let got = try await ModelLoadRun.perform(url: url, tracker: tracker, history: history,
                                                 onFinish: {}) { u in
            tracker.ingest("Loading models...")
            tracker.ingest("Loaded text decoder in 104.21s")
            tracker.ingest("Loaded models for whisper size: large-v3 in 631.34s")
            return u.lastPathComponent
        }
        #expect(got == "a")
        #expect(history.last(for: url)?.total == 631.34)
        #expect(history.last(for: url)?.stages[.textDecoder] == 104.21)
    }

    /// 載入失敗不得留下半筆紀錄——那會變成下一次的參照。
    @Test func doesNotRecordHistoryWhenLoadThrows() async {
        let (history, cleanup) = makeHistory(); defer { cleanup() }
        let tracker = ModelLoadProgressTracker(now: Date.init)
        let url = URL(filePath: "/m/a")
        await #expect(throws: Boom.self) {
            _ = try await ModelLoadRun.perform(url: url, tracker: tracker, history: history,
                                               onFinish: {}) { _ -> String in
                tracker.ingest("Loading models...")
                tracker.ingest("Loaded text decoder in 104.21s")
                throw Boom()
            }
        }
        #expect(history.last(for: url) == nil)
    }

    /// 即使 log 已經吐出「全部載完」，只要載入最後擲錯就不得寫歷史。
    ///
    /// **輸入是合成的**：套件目前的總結訊息（`Core/WhisperKit.swift:441`）是 `loadModels()`
    /// 的最後一行，之後沒有會擲錯的動作，所以真實序列走不到這個組合——上一條
    /// `doesNotRecordHistoryWhenLoadThrows` 因此殺不掉「改用 defer 無條件寫」這個變異。
    /// 但訊息順序是套件的內部細節：哪天總結移到 tokenizer 載入（會擲錯的那一步）之前，
    /// 「載完了然後失敗」就成真。這條把「成功才寫」的意圖釘住，不倚賴套件目前的順序。
    @Test func doesNotRecordHistoryWhenLoadThrowsAfterTheTotalArrived() async {
        let (history, cleanup) = makeHistory(); defer { cleanup() }
        let tracker = ModelLoadProgressTracker(now: Date.init)
        let url = URL(filePath: "/m/a")
        await #expect(throws: Boom.self) {
            _ = try await ModelLoadRun.perform(url: url, tracker: tracker, history: history,
                                               onFinish: {}) { _ -> String in
                tracker.ingest("Loading models...")
                tracker.ingest("Loaded models for whisper size: large-v3 in 631.34s")
                throw Boom()
            }
        }
        #expect(history.last(for: url) == nil)
    }

    /// 收尾動作（把 log 等級調回 .info）**擲錯也要跑**。
    /// 少了它，一次失敗的載入就會讓辨識期一直停在 .debug，每個 token 灌一則訊息。
    @Test func onFinishRunsOnBothSuccessAndFailure() async {
        let (history, cleanup) = makeHistory(); defer { cleanup() }
        let tracker = ModelLoadProgressTracker(now: Date.init)
        let calls = Counter2()

        _ = try? await ModelLoadRun.perform(url: URL(filePath: "/m/a"), tracker: tracker,
                                            history: history,
                                            onFinish: { calls.inc() }) { u in u.lastPathComponent }
        #expect(calls.value == 1)

        _ = try? await ModelLoadRun.perform(url: URL(filePath: "/m/b"), tracker: tracker,
                                            history: history,
                                            onFinish: { calls.inc() }) { _ -> String in throw Boom() }
        #expect(calls.value == 2)
    }

    /// 開跑前要先重置——否則第二趟會把上一趟的成績當成自己的寫進歷史。
    @Test func resetsTrackerBeforeLoading() async throws {
        let (history, cleanup) = makeHistory(); defer { cleanup() }
        let tracker = ModelLoadProgressTracker(now: Date.init)
        tracker.ingest("Loading models...")
        tracker.ingest("Loaded models for whisper size: 上一趟 in 999.0s")

        let url = URL(filePath: "/m/a")
        _ = try await ModelLoadRun.perform(url: url, tracker: tracker, history: history,
                                           onFinish: {}) { u in u.lastPathComponent }
        #expect(history.last(for: url) == nil, "這一趟沒有總結訊息，不得沿用上一趟的 999 秒")
    }
}

private final class Counter2: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func inc() { lock.lock(); v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}
