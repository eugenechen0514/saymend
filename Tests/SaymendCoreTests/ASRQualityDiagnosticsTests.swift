import Foundation
import Testing
import WhisperKit
@testable import SaymendCore

/// 辨識品質診斷（issue #10）。
///
/// **這批測試守的不是某個功能，而是一批未來才會被拿來做決定的資料的可信度。**
/// 欄位接反、聚合取錯邊、記錯錨點——沒有任何一個會有執行期徵兆，只會在幾週後
/// 拿樣本訂門檻時，讓訂出來的門檻擋掉使用者真的講的話。
@Suite struct ASRQualityDiagnosticsTests {

    // MARK: - 聚合：取最壞值

    @Test func emptySegmentsProduceNoQuality() {
        #expect(TranscriptQuality(segments: []) == nil)
    }

    /// 取最壞值而非平均。WhisperKit 的門檻是**逐片段**套用的，
    /// 平均會把一個爛片段稀釋掉——那正是幻覺最可能藏身的地方。
    @Test func aggregateTakesWorstOfEachMetricIndependently() throws {
        let q = try #require(TranscriptQuality(segments: [
            .init(avgLogprob: -0.20, compressionRatio: 1.4),
            .init(avgLogprob: -0.95, compressionRatio: 1.1),   // 對數機率最低者
            .init(avgLogprob: -0.35, compressionRatio: 2.8),   // 壓縮比最高者
        ]))
        // 兩個極值刻意落在**不同**片段：若聚合是「先挑最差的片段再取它的兩個值」，
        // 這裡會有一邊對不上。
        #expect(q.minAvgLogprob == -0.95)
        #expect(q.maxCompressionRatio == 2.8)
        #expect(q.segmentCount == 3)
    }

    /// 極值落在第一個片段：`dropFirst` 的迴圈若把種子寫成固定值（0、-∞）就會漏掉它
    @Test func aggregateIncludesTheFirstSegment() throws {
        let q = try #require(TranscriptQuality(segments: [
            .init(avgLogprob: -0.99, compressionRatio: 3.3),
            .init(avgLogprob: -0.10, compressionRatio: 1.0),
        ]))
        #expect(q.minAvgLogprob == -0.99)
        #expect(q.maxCompressionRatio == 3.3)
    }

    @Test func singleSegmentKeepsItsOwnNumbers() throws {
        let q = try #require(TranscriptQuality(segments: [
            .init(avgLogprob: -0.42, compressionRatio: 1.31),
        ]))
        #expect(q.minAvgLogprob == -0.42)
        #expect(q.maxCompressionRatio == 1.31)
        #expect(q.segmentCount == 1)
    }

    // MARK: - 欄位對應：接反了沒有任何徵兆

    /// 兩個欄位都是 Float、名字相近，接反不會有編譯或執行期錯誤，
    /// 只會讓幾週後累積出來的樣本全部無效。刻意用**正負號分得開**的值。
    @Test func segmentQualityMapsWhisperKitFieldsWithoutSwapping() {
        let segment = TranscriptionSegment(text: "測試", temperature: 0.5,
                                           avgLogprob: -0.73, compressionRatio: 2.15,
                                           noSpeechProb: 0.9)
        let q = WhisperKitModelActor.quality(of: segment)
        #expect(q.avgLogprob == -0.73)
        #expect(q.compressionRatio == 2.15)
    }

    // MARK: - 增量切分

    /// 新定稿的品質只取新增那幾個片段——連同已發過的一起算，
    /// 會讓早先某個爛片段永遠拖著後面每一筆診斷。
    @Test func newlyConfirmedQualityTakesOnlyTheNewSegments() {
        let a = TranscriptSegmentQuality(avgLogprob: -0.1, compressionRatio: 1.0)
        let b = TranscriptSegmentQuality(avgLogprob: -0.2, compressionRatio: 2.0)
        let c = TranscriptSegmentQuality(avgLogprob: -0.3, compressionRatio: 3.0)
        #expect(WhisperKitEngine.newlyConfirmedQuality(previousCount: 1, current: [a, b, c]) == [b, c])
    }

    @Test func newlyConfirmedQualityFromZeroTakesEverything() {
        let a = TranscriptSegmentQuality(avgLogprob: -0.1, compressionRatio: 1.0)
        let b = TranscriptSegmentQuality(avgLogprob: -0.2, compressionRatio: 2.0)
        #expect(WhisperKitEngine.newlyConfirmedQuality(previousCount: 0, current: [a, b]) == [a, b])
    }

    /// 片段數變少＝套件重寫了已定稿的內容。文字那條路在此保守地整段當新增
    /// （`newlyConfirmed`），品質必須跟著整組回傳，否則兩邊涵蓋的範圍會對不上。
    @Test func newlyConfirmedQualityFallsBackToAllWhenSegmentsShrank() {
        let a = TranscriptSegmentQuality(avgLogprob: -0.1, compressionRatio: 1.0)
        #expect(WhisperKitEngine.newlyConfirmedQuality(previousCount: 5, current: [a]) == [a])
    }

    // MARK: - 控制器：診斷列寫在哪裡

    /// 診斷錨在**定稿當下**，不等話語閉合、不等語言模型回應。
    /// 實機 id=116 那筆幻覺只留下一列 `insertSkipped`、沒有 outcome 列
    /// （潤飾回來時 session 已封存、historySessionID 已清空）——
    /// 掛在話語或 outcome 上，最需要的樣本恰好記不到。
    @MainActor
    @Test func finalizedWithQualityWritesDiagnosticImmediately() {
        let history = FakeHistory()
        let (c, _, _, _, _, _) = makeController(history: history)
        c.hotkeyPressed(at: 10.0)
        // 兩個值刻意取二進位可精確表示的數（-7/8、5/2）：Float 存進 Double 欄位是無損的，
        // 但 `-0.88` 這個 Double 字面值與 `Float(-0.88)` 本來就不相等，用它斷言只會測到浮點表示法。
        c.handleTranscript(.finalized("请不吝点赞 订阅 转发",
                                      quality: .init(minAvgLogprob: -0.875,
                                                     maxCompressionRatio: 2.5,
                                                     segmentCount: 2)),
                           at: 10.5)
        // 話語尚未閉合、潤飾尚未回來——此刻就必須已經有診斷列
        #expect(history.exchanges.isEmpty)
        #expect(history.diagnostics.count == 1)
        #expect(history.diagnostics[0].finalizedText == "请不吝点赞 订阅 转发")
        #expect(history.diagnostics[0].minAvgLogprob == -0.875)
        #expect(history.diagnostics[0].maxCompressionRatio == 2.5)
        #expect(history.diagnostics[0].segmentCount == 2)
        #expect(history.diagnostics[0].sessionID == history.sessions[0].id)
    }

    /// 沒有品質資料就不寫列。系統內建引擎與遠端 Whisper 都給不出這兩個數字，
    /// 寫一堆空值只會在統計時混進假樣本。
    @MainActor
    @Test func finalizedWithoutQualityWritesNoDiagnostic() {
        let history = FakeHistory()
        let (c, _, _, _, _, _) = makeController(history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("系統引擎給的字"), at: 10.5)
        #expect(history.diagnostics.isEmpty)
    }

    /// 診斷記的是使用者說的話，隱私閘門與歷史完全一致
    @MainActor
    @Test func diagnosticsRespectHistoryDisabled() {
        let history = FakeHistory()
        let (c, _, _, _, _, _) = makeController(history: history)
        c.settings.historyEnabled = false
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("字", quality: .init(minAvgLogprob: -0.5,
                                                          maxCompressionRatio: 1.2,
                                                          segmentCount: 1)),
                           at: 10.5)
        #expect(history.diagnostics.isEmpty)
    }

    /// 釘住 `settings.historyEnabled` 這個條件**本身**。
    ///
    /// 上一條是「開場前就關」，那條路徑 `historySessionID` 根本不會建立，單靠
    /// `let hid = historySessionID` 就擋住了——把開關檢查整個刪掉它照樣綠（已用變異驗證）。
    /// 唯有「session 已有 ID、聽寫中途 toggle off」才真正依賴這個條件。
    @MainActor
    @Test func diagnosticsStopWhenHistoryDisabledMidSession() {
        let history = FakeHistory()
        let (c, _, _, _, _, _) = makeController(history: history)
        c.hotkeyPressed(at: 10.0)                        // historyEnabled 預設 true → session ID 建立
        #expect(c.settings.historyEnabled)
        c.handleTranscript(.finalized("關閉前", quality: .init(minAvgLogprob: -0.5,
                                                            maxCompressionRatio: 1.2,
                                                            segmentCount: 1)),
                           at: 10.5)
        #expect(history.diagnostics.count == 1)          // 前提：這條路本來是通的
        c.settings.historyEnabled = false                // 聽寫中途關閉歷史
        c.handleTranscript(.finalized("關閉後", quality: .init(minAvgLogprob: -0.6,
                                                            maxCompressionRatio: 1.3,
                                                            segmentCount: 1)),
                           at: 11.0)
        #expect(history.diagnostics.map(\.finalizedText) == ["關閉前"])
    }

    /// **密碼欄位一個字都不能留。** 診斷列會把定稿文字原樣落進資料庫，
    /// 寫在密碼欄位守衛之前，等於在密碼欄位裡留下一份使用者說的話。
    @MainActor
    @Test func secureFieldLeavesNoDiagnostic() {
        let history = FakeHistory()
        let reader = FakeFieldReader()
        let (c, _, _, _, _, _) = makeController(fieldReader: reader, history: history)
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0)
        c.hotkeyPressed(at: 10.0)                        // 一般欄位起手：session 正常開
        #expect(!history.sessions.isEmpty)
        reader.context = FieldContext(hasFocusedElement: true, isSecure: true)
        c.handleTranscript(.finalized("我的密碼是",
                                      quality: .init(minAvgLogprob: -0.3,
                                                     maxCompressionRatio: 1.1,
                                                     segmentCount: 1)),
                           at: 10.5)
        #expect(history.diagnostics.isEmpty)
    }
}
