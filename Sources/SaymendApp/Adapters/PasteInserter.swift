import AppKit
import CoreGraphics
import SaymendCore

/// PasteInserter 用到的剪貼簿操作子集（issue #41）。抽成 protocol 只為了一件事：
/// 讓測試能模擬 `setString` 回 false——真 NSPasteboard 沒辦法被叫失敗，也不能子類化（`pasteboardWithName:` 回的是快取實例）。
/// 方法簽章與 NSPasteboard 完全相同，故 conform 是空實作。
protocol PasteboardChannel: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardChannel {}

/// 剪貼簿貼上（規格 §4.6 PasteInserter）：保存剪貼簿 → 寫入 → Cmd+V → 延遲還原。
/// 長文字最快。M1 已知取捨：還原採 300ms 非同步，期間使用者手動 Cmd+V 會貼到我們的文字。
final class PasteInserter: TextInserter {
    private let channel: any KeyEventChannel
    private let pasteboard: any PasteboardChannel
    private static let vKeyCode: CGKeyCode = 9

    init(channel: any KeyEventChannel = CGKeyEventChannel(),
         pasteboard: any PasteboardChannel = NSPasteboard.general) {
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
        // 寫入失敗（issue #41）：剪貼簿此刻已被清空。舊版不檢查回傳值，照常送 Cmd+V、照常正常回傳——
        // 貼進去的是空剪貼簿，帳本卻以為文字在畫面上，之後潤飾會盲退格吃掉使用者的字。
        // 依 TextInserter 原子契約：**同步**還原（不能等 300ms 排程）、拋錯讓呼叫端退到 keystroke 通道。
        guard pasteboard.setString(text, forType: .string) else {
            Self.restore(saved, to: pasteboard)
            throw InserterError.postFailed
        }

        channel.post(down)
        channel.post(up)

        // 等目標 App 讀走剪貼簿後還原
        let pasteboard = self.pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.restore(saved, to: pasteboard)
        }
    }

    /// 把保存的內容寫回剪貼簿（成功路徑的延遲還原與 setString 失敗的即時還原共用）。
    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: any PasteboardChannel) {
        pasteboard.clearContents()
        for entry in saved {
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            pasteboard.writeObjects([item])
        }
    }
}
