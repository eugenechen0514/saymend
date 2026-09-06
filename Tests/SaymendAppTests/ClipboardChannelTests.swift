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
}
