import CoreGraphics
import Foundation
import SaymendCore

/// CGEvent 合成鍵入（規格 §4.6 KeystrokeInserter）。
/// 相容性最廣；每事件最多 20 個 UTF-16 unit（TypingChunker 保證不切斷字位）。
final class KeystrokeInserter: TextInserter {
    private let channel: any KeyEventChannel
    private static let deleteKeyCode: CGKeyCode = 51

    /// 本 App 合成事件的識別標記（Global Constraints）："SPEK"。
    /// HotkeyMonitor 據此把自家鍵入排除在「使用者活動」之外，避免自我凍結。
    static let syntheticMarker: Int64 = 0x5350454B

    init(channel: any KeyEventChannel = CGKeyEventChannel()) {
        self.channel = channel
    }

    func insert(_ text: String) throws {
        // 所有 chunk 的事件先建好再送（issue #38）：若第 N 段的建構失敗，前 N−1 段尚未送出，
        // 呼叫端的 fallback 才能安全重送完整文字，不會留下「前綴＋完整文字」。
        var events: [(down: CGEvent, up: CGEvent)] = []
        for chunk in TypingChunker.chunks(of: text, maxUTF16: 20) {
            var units = Array(chunk.utf16)
            guard let down = channel.makeKeyEvent(virtualKey: 0, keyDown: true),
                  let up = channel.makeKeyEvent(virtualKey: 0, keyDown: false) else {
                throw InserterError.postFailed
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // 清空修飾旗標：熱鍵是「按住右 Cmd」，combinedSessionState 會把實際按住的修飾鍵
            // 疊到合成事件上（鍵入變 Cmd+A 全選、退格變 Cmd+Delete 刪到行首），必須顯式歸零。
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            events.append((down, up))
        }
        for event in events {
            channel.post(event.down)
            channel.post(event.up)
            usleep(3000)   // 3ms 間隔，避免部分 App 丟事件
        }
    }

    func deleteBackward(count: Int) throws {
        guard count > 0 else { return }
        // 先建立唯一可能失敗的一組事件，再開始送出（issue #38）。舊版在迴圈裡逐次建立：
        // 第 N 次失敗時前 N−1 個 Backspace 已不可逆地送出，呼叫端卻只拿到一個沒有 progress 的
        // throw，無從回滾。同一 CGEvent 可重複 post；如此本函式要嘛一字未動便 throw，
        // 要嘛送完要求的 count。
        guard let down = channel.makeKeyEvent(virtualKey: Self.deleteKeyCode, keyDown: true),
              let up = channel.makeKeyEvent(virtualKey: Self.deleteKeyCode, keyDown: false) else {
            throw InserterError.postFailed
        }
        // 同上：避免實際按住的右 Cmd 讓退格變成 Cmd+Delete
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        for _ in 0..<count {
            channel.post(down)
            channel.post(up)
            usleep(3000)
        }
    }
}
