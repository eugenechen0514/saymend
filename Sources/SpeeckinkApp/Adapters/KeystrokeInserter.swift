import CoreGraphics
import Foundation
import SpeeckinkCore

/// CGEvent 合成鍵入（規格 §4.6 KeystrokeInserter）。
/// 相容性最廣；每事件最多 20 個 UTF-16 unit（TypingChunker 保證不切斷字位）。
final class KeystrokeInserter: TextInserter {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private static let deleteKeyCode: CGKeyCode = 51

    func insert(_ text: String) throws {
        for chunk in TypingChunker.chunks(of: text, maxUTF16: 20) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw InserterError.postFailed
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
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
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)
        }
    }
}
