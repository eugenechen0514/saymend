import AppKit
import CoreGraphics
import SaymendCore

/// 剪貼簿貼上（規格 §4.6 PasteInserter）：透過 ClipboardChannel 暫時寫入 → Cmd+V → 安全窗後由 channel 還原。
/// 長文字最快。M1 已知取捨：還原採 300ms 非同步，期間使用者手動 Cmd+V 會貼到我們的文字。
/// 保存／還原／與其他出口的協調全在 channel（issue #42）；這裡只負責事件。
final class PasteInserter: TextInserter {
    private let channel: any KeyEventChannel
    private let clipboard: ClipboardChannel
    private static let vKeyCode: CGKeyCode = 9

    init(channel: any KeyEventChannel = CGKeyEventChannel(),
         clipboard: ClipboardChannel = .general) {
        self.channel = channel
        self.clipboard = clipboard
    }

    func insert(_ text: String) throws {
        // 唯一會失敗的步驟先做（issue #38）：舊版先 clearContents＋setString 再建事件，
        // 建構失敗直接 throw，還原排程永遠不會被安排——使用者的剪貼簿被聽寫文字取代且永不回復。
        // 事件建好之後才碰剪貼簿，拋錯就保證剪貼簿一個 byte 都沒動。
        guard let down = channel.makeKeyEvent(virtualKey: Self.vKeyCode, keyDown: true),
              let up = channel.makeKeyEvent(virtualKey: Self.vKeyCode, keyDown: false) else {
            throw InserterError.postFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: KeystrokeInserter.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: KeystrokeInserter.syntheticMarker)

        // 寫入失敗（issue #41）由 channel 同步還原並拋 postFailed，Cmd+V 不會送出；呼叫端退到 keystroke 通道。
        try clipboard.withTransientWrite(text) {
            channel.post(down)
            channel.post(up)
        }
    }
}
