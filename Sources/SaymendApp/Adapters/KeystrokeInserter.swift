import CoreGraphics
import Foundation
import SaymendCore

/// CGEvent 合成鍵入（規格 §4.6 KeystrokeInserter）。
/// 相容性最廣；每事件最多 20 個 UTF-16 unit（TypingChunker 保證不切斷字位）。
final class KeystrokeInserter: TextInserter {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private static let deleteKeyCode: CGKeyCode = 51

    /// 本 App 合成事件的識別標記（Global Constraints）："SPEK"。
    /// HotkeyMonitor 據此把自家鍵入排除在「使用者活動」之外，避免自我凍結。
    static let syntheticMarker: Int64 = 0x5350454B

    func insert(_ text: String) throws {
        for chunk in TypingChunker.chunks(of: text, maxUTF16: 20) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
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
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)   // 3ms 間隔，避免部分 App 丟事件
        }
    }

    func deleteBackward(count: Int) throws {
        guard count > 0 else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: false) else {
                throw InserterError.postFailed
            }
            // 同上：避免實際按住的右 Cmd 讓退格變成 Cmd+Delete
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)
        }
    }
}
