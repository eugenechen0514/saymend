import AppKit
import CoreGraphics
import SaymendCore

/// 剪貼簿貼上（規格 §4.6 PasteInserter）：保存剪貼簿 → 寫入 → Cmd+V → 延遲還原。
/// 長文字最快。M1 已知取捨：還原採 300ms 非同步，期間使用者手動 Cmd+V 會貼到我們的文字。
final class PasteInserter: TextInserter {
    private let channel: any KeyEventChannel
    private let pasteboard: NSPasteboard
    private static let vKeyCode: CGKeyCode = 9

    init(channel: any KeyEventChannel = CGKeyEventChannel(), pasteboard: NSPasteboard = .general) {
        self.channel = channel
        self.pasteboard = pasteboard
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

        // 保存既有內容（逐 item 逐 type 複製 data）
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        channel.post(down)
        channel.post(up)

        // 等目標 App 讀走剪貼簿後還原
        let pasteboard = self.pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }
    }

    func deleteBackward(count: Int) throws {
        throw InserterError.unsupported   // 貼上路徑不做刪除；協調器一律用 keystroke 退格
    }
}
