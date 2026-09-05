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

    func makeKeyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent? {
        constructions += 1
        if constructions == failAtConstruction { return nil }
        return CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown)
    }

    func post(_ event: CGEvent) { posted.append(event) }
}

/// issue #38：inserter 的失敗必須是原子的——拋錯＝一個事件都沒送出，正常回傳＝全部送出。
/// 舊實作在迴圈裡逐次建構 CGEvent，第 N 次失敗時前 N−1 個已不可逆地送出，
/// 呼叫端只拿到一個沒有 progress 資訊的 postFailed，無從回滾。
@Suite struct InserterAtomicityTests {

    @Test func deleteBackwardNeverLeavesPartialProgress() {
        let channel = FakeKeyEventChannel()
        channel.failAtConstruction = 3      // 舊實作：第二輪迴圈的 down 建構失敗，此時已送出 2 個事件
        let inserter = KeystrokeInserter(channel: channel)
        do {
            try inserter.deleteBackward(count: 5)
            #expect(channel.posted.count == 10, "正常回傳就必須送完 5 組 down/up")
        } catch {
            #expect(channel.posted.isEmpty, "拋錯就必須一個事件都沒送出；實際送了 \(channel.posted.count) 個")
        }
    }

    @Test func insertNeverLeavesPartialProgress() {
        let channel = FakeKeyEventChannel()
        // 100 個 ASCII → TypingChunker 切 5 段（每段 20 UTF-16）。
        // 舊實作：第 3 段的 down 建構（第 5 次）失敗時，前 2 段的 4 個事件已送出。
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
