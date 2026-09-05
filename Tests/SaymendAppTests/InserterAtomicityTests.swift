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

/// issue #38：inserter 的失敗必須是原子的——拋錯＝一個事件都沒送出，正常回傳＝全部送出。
/// 舊實作在迴圈裡逐次建構 CGEvent，第 N 次失敗時前 N−1 個已不可逆地送出，
/// 呼叫端只拿到一個沒有 progress 資訊的 postFailed，無從回滾。
///
/// 每條測試只驗一件事：失敗測試以 `Issue.record` 守住「不該成功卻成功」，成功測試不含 catch——
/// 避免同一個 do/catch 同時扮演兩種角色、門檻選錯時退化成永遠只驗其中一邊。
@Suite struct InserterAtomicityTests {

    // MARK: deleteBackward — 新實作只建一組 down/up（恰 2 次建構），再重複 post count 次

    @Test func deleteBackwardThrowsWithZeroPostsWhenDownConstructionFails() {
        let channel = FakeKeyEventChannel()
        channel.failAtConstruction = 1              // down 建構失敗
        let inserter = KeystrokeInserter(channel: channel)
        do {
            try inserter.deleteBackward(count: 5)
            Issue.record("第 1 次建構會失敗，deleteBackward 不該正常回傳")
        } catch {
            #expect(channel.posted.isEmpty, "拋錯就必須一個事件都沒送出；實際送了 \(channel.posted.count) 個")
        }
    }

    @Test func deleteBackwardThrowsWithZeroPostsWhenUpConstructionFails() {
        let channel = FakeKeyEventChannel()
        channel.failAtConstruction = 2              // down 已建好，up 建構失敗
        let inserter = KeystrokeInserter(channel: channel)
        do {
            try inserter.deleteBackward(count: 5)
            Issue.record("第 2 次建構會失敗，deleteBackward 不該正常回傳")
        } catch {
            #expect(channel.posted.isEmpty, "拋錯就必須一個事件都沒送出；實際送了 \(channel.posted.count) 個")
        }
    }

    @Test func deleteBackwardBuildsOnePairThenPostsCountTimes() throws {
        let channel = FakeKeyEventChannel()
        let inserter = KeystrokeInserter(channel: channel)
        try inserter.deleteBackward(count: 5)
        // 建構次數與 count 無關，是原子性成立的機制：所有會失敗的步驟都發生在第一次 post 之前。
        // 舊實作每輪迴圈重建，這裡會是 10。
        #expect(channel.constructions == 2)
        #expect(channel.constructionsAtFirstPost == 2)
        #expect(channel.posted.count == 10)
    }

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
        let inserter = PasteInserter(channel: channel, pasteboard: pb)
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
}
