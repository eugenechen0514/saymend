import AppKit
import Testing
import SaymendCore
@testable import SaymendApp

/// 假計時器（issue #42）：`schedule` 只收集 block、`wait` 記錄秒數並撥動 `now`——與真實情況一致：
/// 主執行緒 usleep 期間主佇列不會跑，排程 block 要等 `fireDue()` 才觸發。
final class FakeClipboardTimer: ClipboardTimer {
    var now: TimeInterval = 0
    private(set) var waits: [TimeInterval] = []
    private var scheduled: [(fireAt: TimeInterval, block: () -> Void)] = []
    var scheduledCount: Int { scheduled.count }

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        scheduled.append((now + seconds, block))
    }

    func wait(_ seconds: TimeInterval) {
        waits.append(seconds)
        now += seconds
    }

    /// 觸發所有到期的 block（依排程順序），模擬主佇列在 `now` 時刻被排空。
    func fireDue() {
        let due = scheduled.filter { $0.fireAt <= now }
        scheduled.removeAll { $0.fireAt <= now }
        due.forEach { $0.block() }
    }
}

/// 每條測試用自己的私有具名 pasteboard，不碰 .general，也不互相干擾。
private func makePasteboard(seed: String) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.clipboard.\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString(seed, forType: .string)
    return pb
}

/// issue #42：四個寫剪貼簿的出口收攏到一個 channel。這裡直接測 channel 的規則；
/// 真正呼叫點（PasteInserter／ClipboardSelectionReader）另在各自的測試打。
@Suite struct ClipboardChannelTests {

    // MARK: transient write（paste）

    @Test func transientWriteRestoresTheUsersClipboardAfterTheSettleWindow() throws {
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        var bodyRan = false
        try channel.withTransientWrite("聽寫文字") {
            bodyRan = true
            #expect(pb.string(forType: .string) == "聽寫文字", "body 執行時剪貼簿必須已是要貼的文字")
        }
        #expect(bodyRan)
        #expect(pb.string(forType: .string) == "聽寫文字", "安全窗內不得還原（目標 App 可能還沒讀走）")
        #expect(timer.scheduledCount == 1)
        #expect(timer.waits.isEmpty, "沒有前一個 transient 在途，不該等待")
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "使用者原本的剪貼簿")
    }

    /// ②-a 的另一半：使用者在安全窗內自己複製了東西，收尾不得把它蓋回去。
    @Test func settleLeavesAForeignWriteAlone() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A") {}
        pb.clearContents()
        pb.setString("使用者窗內複製的 X", forType: .string)
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "使用者窗內複製的 X")
    }

    /// #41 契約沿用：setString 回 false 時剪貼簿已被清空，必須**同步**還原、拋錯、body 不執行、不排程。
    @Test func setStringFailureRestoresSynchronouslyThrowsAndSchedulesNothing() {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing)
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        var bodyRan = false
        do {
            try channel.withTransientWrite("A") { bodyRan = true }
            Issue.record("setString 回 false，withTransientWrite 不該正常回傳")
        } catch {
            #expect(error as? InserterError == .postFailed)
            #expect(!bodyRan, "剪貼簿沒寫成就不能送 Cmd+V")
            #expect(backing.string(forType: .string) == "U",
                    "必須在拋錯前同步還原；實際：\(backing.string(forType: .string) ?? "nil")")
            #expect(timer.scheduledCount == 0)
        }
    }

    // MARK: settle——任何新動作前先把在途的 paste 收尾

    /// ②-b：舊版第二次 paste「保存」到的是第一次寫進去的 A1，兩次還原後剪貼簿＝A1、使用者的 U 消失。
    /// 新規則：第二次先等第一次的安全窗走完並還原 U，再保存——保存到的就是 U。
    @Test func secondTransientWriteInsideTheWindowSettlesTheFirstBeforeSaving() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A1") {}
        timer.now = 0.1
        var seenAtBody: String?
        try channel.withTransientWrite("A2") { seenAtBody = pb.string(forType: .string) }
        #expect(seenAtBody == "A2")
        #expect(timer.waits.count == 1)
        #expect(abs((timer.waits.first ?? 0) - 0.2) < 1e-9, "等到第一次的安全窗結束（剩 0.2s）；實際 \(timer.waits)")
        timer.now = 0.6
        timer.fireDue()                                  // 兩個排程 block 都觸發：第一個已被內聯收尾，是 no-op
        #expect(pb.string(forType: .string) == "U", "舊版這裡會是 A1")
    }

    /// 被 settle 內聯收尾過的第一個排程 block 稍後觸發時，第二次 paste 仍在途：它必須是 no-op，
    /// 不得把第二個 lease 撞掉——否則接下來的第三次寫入以為沒有在途 paste，不等就覆寫。
    @Test func aStaleScheduledFinishDoesNotDropTheNewerLease() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A1") {}
        timer.now = 0.1
        try channel.withTransientWrite("A2") {}           // 等 0.2 → now 0.3，A2 的窗到 0.6
        timer.fireDue()                                   // A1 的 block（0.3 到期）觸發：必須 no-op
        #expect(pb.string(forType: .string) == "A2", "A2 仍在安全窗內，不得被還原")
        timer.now = 0.35
        try channel.withTransientWrite("A3") {}
        #expect(timer.waits.count == 2 && abs((timer.waits.last ?? 0) - 0.25) < 1e-9,
                "第三次必須等 A2 的窗（剩 0.25s）；實際 \(timer.waits)")
        timer.now = 1
        timer.fireDue()
        #expect(pb.string(forType: .string) == "U")
    }

    /// 安全窗已過但排程 block 還沒跑（主佇列忙）：不等待，直接內聯收尾。
    @Test func settleDoesNotWaitWhenTheWindowAlreadyElapsed() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A1") {}
        timer.now = 0.5
        try channel.withTransientWrite("A2") {}
        #expect(timer.waits.isEmpty)
        timer.now = 0.8
        timer.fireDue()
        #expect(pb.string(forType: .string) == "U")
    }

    /// 使用者已在窗內複製了別的東西：等也救不回在途 paste，且不得寫回——第二次保存到的是使用者的新內容。
    @Test func settleDoesNotWaitAfterAForeignWriteAndKeepsIt() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A1") {}
        pb.clearContents()
        pb.setString("X", forType: .string)
        timer.now = 0.1
        try channel.withTransientWrite("A2") {}
        #expect(timer.waits.isEmpty)
        timer.now = 0.6
        timer.fireDue()
        #expect(pb.string(forType: .string) == "X")
    }

    // MARK: rescue——失敗路徑的最後手段，立即落地、之後只被使用者覆寫

    /// ②-a：舊版 paste 的 300ms 還原會把救援內容 R 洗回 U。新規則：救援先等安全窗走完（收尾還原 U），
    /// 立即落地 R；之後原排程 block 觸發是 no-op，R 留著。
    @Test func rescueInsideTheWindowSettlesThenLandsAndSurvivesTheScheduledRestore() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A") {}
        timer.now = 0.05
        channel.rescue("救援 R", round: 1)
        #expect(abs((timer.waits.first ?? 0) - 0.25) < 1e-9 && timer.waits.count == 1,
                "先等在途 paste 的安全窗（剩 0.25s）；實際 \(timer.waits)")
        #expect(pb.string(forType: .string) == "救援 R", "救援必須立即落地")
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "救援 R", "舊版這裡會被還原成 U")
        #expect(channel.rescueStillInClipboard == "救援 R")
    }

    /// 救援落地後又有 paste：R 只在安全窗內被 A 暫時擠開，收尾放回的是 R 而不是更早的 U。
    @Test func transientWriteAfterALandedRescuePutsTheRescueBack() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("救援 R", round: 1)
        try channel.withTransientWrite("A") { #expect(pb.string(forType: .string) == "A") }
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "救援 R")
        #expect(channel.rescueStillInClipboard == "救援 R", "放回之後仍要認得它是救援內容")
    }

    /// 「還在剪貼簿」只承諾「自落地後沒被任何人覆寫」：使用者複製了別的東西就不再是。
    @Test func rescueStillInClipboardIsNilOnceAnyoneOverwritesIt() throws {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("救援 R", round: 1)
        #expect(channel.rescueStillInClipboard == "救援 R")
        pb.clearContents()
        pb.setString("X", forType: .string)
        #expect(channel.rescueStillInClipboard == nil)
    }

    /// History 分頁的複製是使用者主動覆寫：救援紀錄清掉。
    @Test func copyForUserOverwritesAndClearsTheRescueRecord() throws {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("救援 R", round: 1)
        channel.copyForUser("歷史文字 H")
        #expect(pb.string(forType: .string) == "歷史文字 H")
        #expect(channel.rescueStillInClipboard == nil)
    }

    /// 取捨 3（PR 揭露）：救援→窗內 paste→窗內使用者複製 X→收尾：不寫回 R，X 是使用者最後一次明確意圖。
    @Test func foreignWriteDuringAPasteThatDisplacedARescueWinsOverTheRescue() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("救援 R", round: 1)
        try channel.withTransientWrite("A") {}
        pb.clearContents()
        pb.setString("X", forType: .string)
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "X")
        #expect(channel.rescueStillInClipboard == nil)
    }

    /// 取捨 3 的邊界：窗內剪貼簿只是被**清空**（剪貼簿管理器的定時清除之類），沒有任何新內容取代 R——
    /// 沒有東西可以讓步，收尾就把 R 放回去。只對「別人放了內容」讓步。
    @Test func aPureClearDuringAPasteThatDisplacedARescueGetsTheRescueBack() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("救援 R", round: 1)
        try channel.withTransientWrite("A") {}
        pb.clearContents()
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "救援 R")
        #expect(channel.rescueStillInClipboard == "救援 R")
    }

    /// 同樣的純清空若擠開的是使用者內容 U：維持不寫回——U 沒有救援那種「不落地就沒了」的分量，
    /// 而清空可能正是使用者（或其工具）的意圖。
    @Test func aPureClearDuringAPasteThatDisplacedUserContentStaysEmpty() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A") {}
        pb.clearContents()
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == nil)
    }

    /// 救援寫不進去：不能宣稱它在剪貼簿裡，也不能讓剪貼簿兩頭皆空——使用者原本的內容要還在。
    @Test func rescueThatFailsToWriteIsNotReportedAndLeavesTheClipboardAsItWas() {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing)
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("救援 R", round: 1)
        #expect(channel.rescueStillInClipboard == nil)
        #expect(backing.string(forType: .string) == "U", "clear 之後寫不進去必須同步還原；實際 \(backing.string(forType: .string) ?? "nil")")
    }

    /// 收尾要把被擠開的救援放回去、卻寫不進去：剪貼簿此刻是空的（clear 之後寫失敗，沒有東西可以再放回），
    /// 至少不能宣稱救援還在——否則 History 分頁會為一份不存在的救援跳確認、使用者以為它安全存放。
    @Test func failingToPutTheRescueBackDoesNotClaimItIsStillThere() throws {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing, failingAttempts: [3])   // 第 3 次＝收尾放回 R
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("救援 R", round: 1)                              // 第 1 次
        try channel.withTransientWrite("A") {}                // 第 2 次
        timer.now = 0.3
        timer.fireDue()                                       // 第 3 次：失敗
        #expect(pb.setStringAttempts == 3)
        #expect(channel.rescueStillInClipboard == nil)
        #expect(backing.string(forType: .string) == nil, "已知限制：clear 後寫不進去，剪貼簿留空（PR 揭露）")
    }

    /// 使用者主動複製寫不進去：同上，剪貼簿維持原樣。
    @Test func copyForUserThatFailsToWriteLeavesTheClipboardAsItWas() {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing)
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.copyForUser("歷史文字 H")
        #expect(backing.string(forType: .string) == "U")
    }

    /// History 分頁按下複製時：救援可能正被在途 paste 暫時擠開（此刻 changeCount 不符），
    /// 直接看 `rescueStillInClipboard` 會漏判、跳過確認就覆寫。要寫之前的判斷必須先 settle。
    @Test func rescueInClipboardBeforeWritingSettlesTheInFlightPasteFirst() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("救援 R", round: 1)
        try channel.withTransientWrite("A") {}
        timer.now = 0.1
        #expect(channel.rescueStillInClipboard == nil, "前提：此刻剪貼簿是 A，直接看會漏判")
        #expect(channel.rescueInClipboardBeforeWriting() == "救援 R")
        #expect(timer.waits.count == 1 && abs((timer.waits.first ?? 0) - 0.2) < 1e-9, "實際 \(timer.waits)")
        #expect(pb.string(forType: .string) == "救援 R", "settle 收尾已把 R 放回")
    }

    // MARK: rescue 累積——同一輪救援串接（issue #42 取捨 4 修訂）；round 邊界見下一節

    /// 連續兩次救援、中間沒人動剪貼簿：第二段接在第一段後面（無分隔符），不是取代它。
    /// 舊規則是單一 slot、後者取代前者——#37 之後救援會常態化，一段話講三句就只剩最後一句。
    @Test func aSecondRescueAppendsToTheFirstWhenTheClipboardIsStillOurs() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 1)
        channel.rescue("乙", round: 1)
        #expect(pb.string(forType: .string) == "甲乙", "同一輪救援必須串接；實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲乙")
    }

    /// 使用者中途複製了別的東西：changeCount 前進、那一輪結束，下一次救援重新開始，
    /// 不得把使用者那份或更早的救援黏上去。
    @Test func aRescueAfterTheUserCopiedSomethingStartsAFreshRound() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 1)
        pb.clearContents()
        pb.setString("使用者複製的 X", forType: .string)
        channel.rescue("乙", round: 1)
        #expect(pb.string(forType: .string) == "乙", "新的一輪只有新片段；實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "乙")
    }

    /// 累積要跨得過 paste 的暫時擠開／放回：收尾把救援放回後，下一次救援仍接在它後面而不是重新開始。
    @Test func accumulationSurvivesAPasteThatDisplacedAndRestoredTheRescue() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("甲", round: 1)
        try channel.withTransientWrite("A") {}
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "甲", "前提：收尾把救援放回")
        channel.rescue("乙", round: 1)
        #expect(pb.string(forType: .string) == "甲乙", "實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲乙")
    }

    /// 累積寫不進去：不得兩頭皆空——剪貼簿要維持累積前的舊救援，且仍認得它，
    /// 而且這一輪還沒結束：再下一段仍接得在舊救援後面（失敗那段本身靜默遺失，見 PR 揭露）。
    @Test func aFailedAccumulationKeepsThePreviousRescueInTheClipboard() {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing, failingAttempts: [2])   // 第 2 次＝寫入「甲乙」
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 1)
        channel.rescue("乙", round: 1)
        #expect(pb.setStringAttempts == 3, "第 3 次是失敗後放回舊救援；實際 \(pb.setStringAttempts)")
        #expect(backing.string(forType: .string) == "甲", "實際 \(backing.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲")
        channel.rescue("丙", round: 1)
        #expect(backing.string(forType: .string) == "甲丙",
                "失敗後這一輪要接得下去，不能退回單一 slot；實際 \(backing.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲丙")
    }

    /// `rescue` 必須先 `settle()` 再讀 `rescueStillInClipboard`：paste 仍在途時剪貼簿是 paste 寫的內容、
    /// changeCount 與 `landedRescue` 不符，先讀就會判成「不是我方的」而把前一段整個丟掉。
    /// 救援落在上一個 paste 的 300ms 安全窗內不是邊角情況——既有的
    /// `rescueInsideTheWindowSettlesThenLandsAndSurvivesTheScheduledRestore` 就是為這個時序寫的。
    /// 與 `accumulationSurvivesAPasteThatDisplacedAndRestoredTheRescue` 的差別：那條先 `fireDue()`
    /// 把 lease 收乾淨了，`settle()` 是 no-op，踏不進這條分支。
    @Test func accumulationWorksWhileAPasteIsStillInFlight() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("甲", round: 1)
        try channel.withTransientWrite("A") {}
        timer.now = 0.1
        #expect(pb.string(forType: .string) == "A", "前提：paste 仍在途，救援被暫時擠開")
        channel.rescue("乙", round: 1)
        #expect(pb.string(forType: .string) == "甲乙",
                "settle 要先把救援放回才讀得到它；實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲乙")
    }

    /// 已知取捨（本次修訂帶進來的行為退步）：Cmd+V 是讀取、不推進 changeCount，我們看不見使用者貼過，
    /// 所以下一段照樣接上去。逐句貼上的使用者會在欄位裡拿到重複的前段——
    /// 舊的「後者取代前者」在這個流程反而是對的。釘成已知行為，免得下次被當 bug 亂改。
    /// 要真的分辨得出來，得在救援落地時另記「已提示過使用者」的 session 訊號，不在本次修訂範圍。
    @Test func pastingBetweenRescuesStillAccumulatesSoTheUserSeesTheEarlierPartTwice() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        var pastedIntoTheField = ""
        channel.rescue("句一", round: 1)
        let afterFirstRescue = pb.changeCount
        pastedIntoTheField += pb.string(forType: .string) ?? ""      // 使用者第一次 Cmd+V＝讀取
        #expect(pb.changeCount == afterFirstRescue, "讀取不推進 changeCount，我們無從得知使用者貼過")
        channel.rescue("句二", round: 1)
        pastedIntoTheField += pb.string(forType: .string) ?? ""      // 使用者第二次 Cmd+V
        #expect(pastedIntoTheField == "句一句一句二",
                "逐句貼上會拿到重複的前段；實際 \(pastedIntoTheField)")
    }

    /// 三段累積：`landedRescue` 必須記成累積後的全文，只記最後一段的話第三次會接錯。
    @Test func threeRescuesInARowAccumulateInOrder() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 1)
        channel.rescue("乙", round: 1)
        channel.rescue("丙", round: 1)
        #expect(pb.string(forType: .string) == "甲乙丙", "實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲乙丙")
    }

    // MARK: rescue 的 session 邊界——round token（PR #56 review 修訂）

    /// 不同輪不串接：changeCount 單獨不足以界定「同一輪」——Cmd+V 是讀取、不推進 changeCount，
    /// 所以「使用者在 session A 收到救援→貼上→開始 session B→B 又救援」在剪貼簿眼中毫無變化，
    /// 只看 changeCount 會把 B 黏在 A 後面（issue #45 的場景每次都踩）。round 不同就覆寫。
    @Test func aRescueFromADifferentRoundOverwritesInsteadOfAppending() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 1)
        channel.rescue("乙", round: 2)                  // 中間沒人動剪貼簿，只有輪次換了
        #expect(pb.string(forType: .string) == "乙",
                "跨輪必須覆寫，不得黏上一輪的殘留；實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "乙")
    }

    /// round 必須跨得過 paste 的暫時擠開／放回：收尾把救援放回時若沒把 round 一起還原，
    /// 同一輪的下一段會被誤判成「不同輪」而覆寫掉正在累積的內容。
    @Test func theRoundSurvivesAPasteThatDisplacedAndRestoredTheRescue() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        channel.rescue("甲", round: 1)
        try channel.withTransientWrite("A") {}          // 救援被暫時擠開
        timer.now = 0.3
        timer.fireDue()                                 // 收尾放回救援
        #expect(pb.string(forType: .string) == "甲", "前提：收尾把救援放回")
        channel.rescue("乙", round: 1)
        #expect(pb.string(forType: .string) == "甲乙",
                "round 在 restore 途中掉了就會變成只剩「乙」；實際 \(pb.string(forType: .string) ?? "nil")")
        #expect(channel.rescueStillInClipboard == "甲乙")
    }

    /// 累積寫入失敗後，剪貼簿裡的舊救援連同它的 round 都要保住：這一輪還接得下去。
    @Test func aFailedAccumulationKeepsThePreviousRescueRound() {
        let backing = makePasteboard(seed: "U")
        let pb = SetStringFailingPasteboard(backing: backing, failingAttempts: [2])   // 第 2 次＝寫入「甲乙」
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("甲", round: 7)
        channel.rescue("乙", round: 7)                  // 失敗：放回「甲」（round 7）
        channel.rescue("丙", round: 7)
        #expect(backing.string(forType: .string) == "甲丙",
                "失敗放回時 round 沒保住就會退化成只剩「丙」；實際 \(backing.string(forType: .string) ?? "nil")")
    }

    // MARK: body 拋錯與 Cmd+C 備援讀取

    private struct BodyFailure: Error {}

    /// body（送事件）拋錯：同步還原、清掉 lease、不排程、錯誤原樣往外拋；下一次寫入不用等。
    @Test func bodyThrowingRestoresSynchronouslyAndRethrows() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        do {
            try channel.withTransientWrite("A") { throw BodyFailure() }
            Issue.record("body 拋錯，withTransientWrite 不該正常回傳")
        } catch {
            #expect(error is BodyFailure, "錯誤要原樣往外拋；實際 \(error)")
            #expect(pb.string(forType: .string) == "U")
            #expect(timer.scheduledCount == 0)
        }
        try channel.withTransientWrite("B") {}
        #expect(timer.waits.isEmpty, "失敗的 lease 必須已清掉，不該被當成在途 paste 等待")
    }

    /// Cmd+C 備援：清空 → body（目標 App 寫入選取）→ 讀回 → 同步還原使用者內容。目標 App 的寫入是預期中的 foreign write。
    @Test func transientReadReturnsWhatTheTargetWroteAndRestoresTheUser() {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        let read = channel.withTransientRead {
            #expect(pb.string(forType: .string) == nil, "body 執行時剪貼簿必須已清空，否則讀到的是舊內容")
            pb.clearContents()
            pb.setString("目標 App 的選取 S", forType: .string)
        }
        #expect(read == "目標 App 的選取 S")
        #expect(pb.string(forType: .string) == "U", "讀完必須同步還原")
        #expect(timer.scheduledCount == 0 && timer.waits.isEmpty)
    }

    /// 目標 App 什麼都沒寫（沒有選取）：回 nil，使用者內容照樣還原。
    @Test func transientReadReturnsNilWhenTheTargetWroteNothing() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        let read = channel.withTransientRead {}
        #expect(read == nil)
        #expect(pb.string(forType: .string) == "U")
    }

    /// 讀取撞上在途 paste：先等安全窗、收尾還原 U，再清空讀取——不污染在途 paste，最後仍是 U。
    @Test func transientReadInsideAPasteWindowSettlesFirst() throws {
        let pb = makePasteboard(seed: "U")
        let timer = FakeClipboardTimer()
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: timer)
        try channel.withTransientWrite("A") {}
        timer.now = 0.1
        let read = channel.withTransientRead {
            pb.clearContents()
            pb.setString("S", forType: .string)
        }
        #expect(read == "S")
        #expect(timer.waits.count == 1 && abs((timer.waits.first ?? 0) - 0.2) < 1e-9, "實際 \(timer.waits)")
        #expect(pb.string(forType: .string) == "U")
        timer.now = 0.6
        timer.fireDue()
        #expect(pb.string(forType: .string) == "U")
    }

    /// 剪貼簿是救援文字時做 Cmd+C 備援：讀完放回的是 R，且仍認得它是救援。
    @Test func transientReadWhileARescueIsInClipboardPutsTheRescueBack() {
        let pb = makePasteboard(seed: "U")
        let channel = ClipboardChannel(pasteboard: pb, settleDelay: 0.3, timer: FakeClipboardTimer())
        channel.rescue("救援 R", round: 1)
        let read = channel.withTransientRead {
            pb.clearContents()
            pb.setString("S", forType: .string)
        }
        #expect(read == "S")
        #expect(pb.string(forType: .string) == "救援 R")
        #expect(channel.rescueStillInClipboard == "救援 R")
    }
}
