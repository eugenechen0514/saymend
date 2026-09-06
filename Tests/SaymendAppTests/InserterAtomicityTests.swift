import AppKit
import CoreGraphics
import Testing
import SaymendCore
@testable import SaymendApp

/// 假事件通道：可在第 N 次建構回 nil，並記錄每一次 post，但絕不真的送進系統事件佇列。
/// 建構成功時回真的 CGEvent（source 為 nil 即可，建構不需要輔助使用權限），
/// 讓 inserter 對事件做的 flags／userData／unicode 設定照常生效、可被斷言。
final class FakeKeyEventChannel: KeyEventChannel {
    /// 第幾次 makeKeyEvent 回 nil（1-based）；nil＝永不失敗
    var failAtConstruction: Int? = nil
    private(set) var constructions = 0
    private(set) var posted: [CGEvent] = []
    /// 第一次 post 發生時，已經建構了幾個事件——直接量測「先全部建好、再開始送」這個性質
    private(set) var constructionsAtFirstPost: Int? = nil

    func makeKeyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent? {
        constructions += 1
        if constructions == failAtConstruction { return nil }
        return CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown)
    }

    func post(_ event: CGEvent) {
        if constructionsAtFirstPost == nil { constructionsAtFirstPost = constructions }
        posted.append(event)
    }
}

/// 假剪貼簿（issue #41）：儲存交給包起來的真 NSPasteboard，只攔截 `setString` 讓它回 false 且不寫入——
/// 模擬 pasteboard server 拒絕寫入。其餘操作原樣轉發，所以「還原」是否真的發生可以從底層 NSPasteboard 讀回來驗。
final class SetStringFailingPasteboard: SystemPasteboard {
    let backing: NSPasteboard
    private(set) var setStringAttempts = 0
    init(backing: NSPasteboard) { self.backing = backing }
    var changeCount: Int { backing.changeCount }
    var pasteboardItems: [NSPasteboardItem]? { backing.pasteboardItems }
    func clearContents() -> Int { backing.clearContents() }
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        setStringAttempts += 1
        return false
    }
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { backing.writeObjects(objects) }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String? { backing.string(forType: dataType) }
}

/// issue #38：inserter 的失敗必須是原子的——拋錯＝一個事件都沒送出，正常回傳＝全部送出。
/// 舊實作在迴圈裡逐次建構 CGEvent，第 N 次失敗時前 N−1 個已不可逆地送出，
/// 呼叫端只拿到一個沒有 progress 資訊的 postFailed，無從回滾。
///
/// 每條測試只驗一件事：失敗測試以 `Issue.record` 守住「不該成功卻成功」，成功測試不含 catch——
/// 避免同一個 do/catch 同時扮演兩種角色、門檻選錯時退化成永遠只驗其中一邊。
@Suite struct InserterAtomicityTests {

    // MARK: insert — 每個 chunk 一組 down/up，全部建好才開始 post

    @Test func insertThrowsWithZeroPostsWhenAMiddleChunkFailsToBuild() {
        let channel = FakeKeyEventChannel()
        // 100 個 ASCII → TypingChunker 切 5 段（每段 20 UTF-16）→ 10 次建構。
        // 讓第 3 段的 down（第 5 次）失敗：舊實作此時前 2 段的 4 個事件已送出。
        channel.failAtConstruction = 5
        let inserter = KeystrokeInserter(channel: channel)
        let text = String(repeating: "a", count: 100)
        #expect(TypingChunker.chunks(of: text, maxUTF16: 20).count == 5)
        do {
            try inserter.insert(text)
            Issue.record("第 5 次建構會失敗，insert 不該正常回傳")
        } catch {
            #expect(channel.posted.isEmpty, "拋錯就必須一個事件都沒送出；實際送了 \(channel.posted.count) 個")
        }
    }

    @Test func insertBuildsEveryChunkBeforeTheFirstPost() throws {
        let channel = FakeKeyEventChannel()
        let inserter = KeystrokeInserter(channel: channel)
        try inserter.insert(String(repeating: "a", count: 100))   // 5 段
        // 舊實作逐段「建→送」，第一次 post 時只建了 2 個。
        #expect(channel.constructionsAtFirstPost == 10)
        #expect(channel.posted.count == 10)
    }

    // MARK: PasteInserter — 事件建好才碰剪貼簿

    /// 每條測試用自己的私有具名 pasteboard，不碰 .general，也不互相干擾。
    private func makePasteboard(seed: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(seed, forType: .string)
        return pb
    }

    @Test func pasteInsertLeavesClipboardUntouchedWhenEventConstructionFails() {
        let channel = FakeKeyEventChannel()
        channel.failAtConstruction = 1
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        let changeCountBefore = pb.changeCount
        let inserter = PasteInserter(channel: channel, clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()))
        do {
            try inserter.insert("聽寫文字")
            Issue.record("第 1 次建構會失敗，insert 不該正常回傳")
        } catch {
            #expect(pb.string(forType: .string) == "使用者原本的剪貼簿",
                    "舊實作先 clearContents+setString 再建事件，失敗時使用者剪貼簿已被覆寫且永不還原")
            #expect(pb.changeCount == changeCountBefore)
            #expect(channel.posted.isEmpty)
        }
    }

    /// issue #41：`setString` 回 false 時剪貼簿已被 clearContents 清空。舊版不檢查回傳值，照常送 Cmd+V、
    /// 照常正常回傳——貼進去的是空剪貼簿，帳本卻以為文字在畫面上，之後潤飾會盲退格吃掉使用者的字。
    /// 依原子契約：必須**同步**還原剪貼簿（不能等 300ms 排程）、拋錯、一個事件都不送。
    @Test func pasteInsertRestoresClipboardAndThrowsWhenSetStringFails() {
        let channel = FakeKeyEventChannel()
        let backing = makePasteboard(seed: "使用者原本的剪貼簿")
        let pb = SetStringFailingPasteboard(backing: backing)
        let inserter = PasteInserter(channel: channel, clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()))
        do {
            try inserter.insert("聽寫文字")
            Issue.record("setString 回 false，insert 不該正常回傳")
        } catch {
            #expect(pb.setStringAttempts == 1)
            #expect(backing.string(forType: .string) == "使用者原本的剪貼簿",
                    "剪貼簿必須在拋錯前同步還原；實際：\(backing.string(forType: .string) ?? "nil")")
            #expect(channel.posted.isEmpty, "不得送出 Cmd+V")
        }
    }

    // MARK: PasteInserter × ClipboardChannel（issue #42）——在真正的呼叫點驗證兩個交錯

    /// ②-b：連續兩次 paste（第二次在第一次的 300ms 內）。舊版第二次保存到的是第一次寫進去的 A1，
    /// 兩次還原後剪貼簿＝A1、使用者的 U 消失。
    @Test func consecutivePasteInsertsInsideTheWindowGiveTheUsersClipboardBack() throws {
        let channel = FakeKeyEventChannel()
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        let timer = FakeClipboardTimer()
        let inserter = PasteInserter(channel: channel, clipboard: ClipboardChannel(pasteboard: pb, timer: timer))
        try inserter.insert("A1")
        timer.now = 0.1
        try inserter.insert("A2")
        #expect(channel.posted.count == 4)
        #expect(timer.waits.count == 1, "第二次必須先等第一次的安全窗；實際 \(timer.waits)")
        timer.now = 0.6
        timer.fireDue()
        #expect(pb.string(forType: .string) == "使用者原本的剪貼簿", "舊版這裡會是 A1")
    }

    /// ②-a：paste 後 300ms 內失敗路徑呼叫救援。舊版 paste 的還原排程會把救援內容洗回 U。
    @Test func rescueInsideAPasteWindowIsNotOverwrittenByThePasteRestore() throws {
        let channel = FakeKeyEventChannel()
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        let timer = FakeClipboardTimer()
        let clipboard = ClipboardChannel(pasteboard: pb, timer: timer)
        let inserter = PasteInserter(channel: channel, clipboard: clipboard)
        try inserter.insert("A")
        timer.now = 0.25
        clipboard.rescue("救援內容")
        timer.now = 0.3
        timer.fireDue()
        #expect(pb.string(forType: .string) == "救援內容", "舊版這裡會被還原成使用者原本的剪貼簿")
        #expect(clipboard.rescueStillInClipboard == "救援內容")
    }
}
