import AppKit
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #71：跨輪救援覆寫上一輪救援時要回報，並把每一輪的救援留在記憶體裡供選單「最近救援」找回。
///
/// 「上一輪的救援還在剪貼簿」的判定沿用 `rescueStillInClipboard`（changeCount 相等）。
/// **判定不了使用者是否貼上過**：Cmd+V 是讀取、不推進 changeCount——所以回報的是「取代了」，不是「沒取回」。
@Suite struct ClipboardRescueReplacementTests {

    private func pasteboard(seed: String = "U") -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.rescue71.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(seed, forType: .string)
        return pb
    }

    /// 時鐘：每讀一次前進 60 秒，讓「最近救援」的時間戳可以逐筆斷言
    private final class StepClock {
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        func next() -> Date { t = t.addingTimeInterval(60); return t }
    }

    private func channel(_ pb: any SystemPasteboard, clock: StepClock = StepClock(),
                         timer: FakeClipboardTimer = FakeClipboardTimer()) -> ClipboardChannel {
        ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer, now: clock.next)
    }

    // MARK: - 回報

    @Test func aFirstRescueReplacesNothing() {
        let c = channel(pasteboard())
        #expect(c.rescue("甲", round: 1) == .landed, "剪貼簿原本是使用者的內容，不是救援")
    }

    @Test func accumulatingWithinARoundReportsAppended() {
        let c = channel(pasteboard())
        c.rescue("甲", round: 1)
        #expect(c.rescue("乙", round: 1) == .appended)
    }

    /// 同一輪、但使用者在兩次救援之間複製過別的東西：鏈斷了，重新開始一份（不是接上、也沒有取代別一輪）
    @Test func theSameRoundAfterTheUserCopiedSomethingStartsAfresh() {
        let c = channel(pasteboard())
        c.rescue("甲", round: 1)
        c.copyForUser("使用者的")
        #expect(c.rescue("乙", round: 1) == .landed)
    }

    /// issue 的失敗情境本身：第一段救援 → 不貼上（剪貼簿沒被動過）→ 第二段救援
    @Test func aRescueOfANewRoundOverAnEarlierRoundsRescueReportsIt() {
        let pb = pasteboard()
        let c = channel(pb)
        c.rescue("第一段", round: 1)
        #expect(c.rescue("第二段", round: 2) == .replacedEarlierRescue)
        #expect(pb.string(forType: .string) == "第二段", "前提：照 #56 跨輪覆寫，不串接")
    }

    /// 使用者在兩段之間自己複製過別的東西（changeCount 前進）：上一段已不在剪貼簿，沒有東西被取代
    @Test func noReplacementWhenTheUserCopiedSomethingInBetween() {
        let pb = pasteboard()
        let c = channel(pb)
        c.rescue("第一段", round: 1)
        pb.clearContents()
        pb.setString("使用者複製的", forType: .string)
        #expect(c.rescue("第二段", round: 2) == .landed)
    }

    /// paste 正把上一輪的救援暫時擠開（300ms 安全窗內）：先收尾放回，那份救援仍是被取代的對象
    @Test func anEarlierRescueTemporarilyDisplacedByAPasteStillCountsAsReplaced() throws {
        let pb = pasteboard()
        let c = channel(pb)
        c.rescue("第一段", round: 1)
        try c.withTransientWrite("貼上中") {}
        #expect(pb.string(forType: .string) == "貼上中", "前提：paste 在途")
        #expect(c.rescue("第二段", round: 2) == .replacedEarlierRescue)
    }

    /// 寫不進剪貼簿：剪貼簿已放回原本那份上一輪的救援，沒有東西被取代——回報 `.notWritten`，
    /// 提示才不會說「已入剪貼簿」（照提示貼上會拿到上一段）
    @Test func aRescueThatFailsToWriteReportsNotWritten() {
        let backing = pasteboard()
        let pb = SetStringFailingPasteboard(backing: backing, failingAttempts: [2])
        let c = channel(pb)
        c.rescue("第一段", round: 1)
        #expect(c.rescue("第二段", round: 2) == .notWritten)
        #expect(backing.string(forType: .string) == "第一段")
    }

    // MARK: - 最近救援

    @Test func recentRescuesKeepOneEntryPerRoundNewestFirstWithTheAccumulatedText() {
        let clock = StepClock()
        let c = channel(pasteboard(), clock: clock)
        c.rescue("甲", round: 1)
        c.rescue("乙", round: 1)
        c.rescue("丙", round: 2)
        #expect(c.recentRescues.map(\.round) == [2, 1])
        #expect(c.recentRescues.map(\.text) == ["丙", "甲乙"], "同一輪存累積後的全文——就是當時剪貼簿裡的那份")
        #expect(c.recentRescues[1].at == Date(timeIntervalSince1970: 1_800_000_120), "時間是該輪最後一次救援")
    }

    /// 同一輪在別輪之後又救了一次（世代過期的緩衝句 outcome 用舊 round 救）：剪貼簿此刻是第 2 輪的，
    /// 第 1 輪接不上去（#56），所以是**另一份**內容——新增一筆，第 1 輪原本那筆（甲）不得被抹掉：
    /// 它可能正是第 2 輪的提示說「可以從選單找回」的那一段。
    @Test func anOlderRoundRescuedAfterANewerOneGetsItsOwnEntry() {
        let c = channel(pasteboard())
        c.rescue("甲", round: 1)
        c.rescue("乙", round: 2)
        c.rescue("丙", round: 1)
        #expect(c.recentRescues.map(\.round) == [1, 2, 1])
        #expect(c.recentRescues.map(\.text) == ["丙", "乙", "甲"])
        #expect(Set(c.recentRescues.map(\.id)).count == 3, "選單以 id 區分，同一輪的兩筆不得撞 id")
    }

    /// 照提示走的流程：從選單把上一段複製回來（鏈斷了）→ 同一輪又救援 → 兩份都要留著
    @Test func breakingTheChainKeepsTheEarlierContentOfTheSameRound() {
        let c = channel(pasteboard())
        c.rescue("A", round: 5)
        c.copyForUser("從選單複製回來的上一段")
        c.rescue("B", round: 5)
        #expect(c.recentRescues.map(\.text) == ["B", "A"])
    }

    /// 寫入失敗的那段記成獨立的一筆，不併進累積鏈：鏈的下一次成功救援以剪貼簿裡的舊內容為底，
    /// 併進去就會把失敗的那段抹掉
    @Test func aFailedWriteIsKeptAsItsOwnEntryAndTheChainCarriesOn() {
        let backing = pasteboard()
        let pb = SetStringFailingPasteboard(backing: backing, failingAttempts: [2])   // 第 2 次＝寫入「甲乙」
        let c = channel(pb)
        c.rescue("甲", round: 1)
        c.rescue("乙", round: 1)
        #expect(c.recentRescues.map(\.text) == ["甲乙", "甲"])
        #expect(c.rescue("丙", round: 1) == .appended, "剪貼簿已放回「甲」，鏈照樣接得上")
        #expect(c.recentRescues.map(\.text) == ["甲丙", "甲乙"], "鏈那一筆更新並移到最前；失敗那筆原樣留著")
    }

    @Test func recentRescuesAreCappedAtFive() {
        let c = channel(pasteboard())
        for round in 1...7 { c.rescue("第\(round)段", round: round) }
        #expect(c.recentRescues.map(\.round) == [7, 6, 5, 4, 3])
        #expect(ClipboardChannel.recentRescueLimit == 5)
    }

    /// 寫不進剪貼簿的那段在任何地方都沒有——選單是唯一能找回它的地方，照樣記
    @Test func aRescueThatFailsToWriteIsStillRecorded() {
        let pb = SetStringFailingPasteboard(backing: pasteboard())
        let c = channel(pb)
        c.rescue("寫不進去的", round: 1)
        #expect(c.recentRescues.map(\.text) == ["寫不進去的"])
    }

    /// 使用者主動複製（歷史分頁、選單本身）不是救援，不進清單
    @Test func copyingForTheUserIsNotARescue() {
        let c = channel(pasteboard())
        c.rescue("甲", round: 1)
        c.copyForUser("歷史分頁複製的")
        #expect(c.recentRescues.map(\.text) == ["甲"])
    }

    // MARK: - 選單文字

    @Test func menuTitleIsTimeAndTheStartOfTheText() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(RecentRescueMenuText.title(text: "欄位切換的那一段", at: at, timeZone: utc) == "08:00  欄位切換的那一段")
    }

    @Test func menuSnippetFlattensWhitespaceAndTruncates() {
        #expect(RecentRescueMenuText.snippet("第一行\n\n第二行   第三") == "第一行 第二行 第三")
        let long = String(repeating: "字", count: 30)
        #expect(RecentRescueMenuText.snippet(long) == String(repeating: "字", count: 24) + "…")
        let exact = String(repeating: "字", count: 24)
        #expect(RecentRescueMenuText.snippet(exact) == exact, "剛好 24 字不加省略號")
    }
}
