import AppKit
import CoreGraphics
import SpeeckinkCore

/// 剪貼簿貼上（規格 §4.6 PasteInserter）：保存剪貼簿 → 寫入 → Cmd+V → 延遲還原。
/// 長文字最快。M1 已知取捨：還原採 300ms 非同步，期間使用者手動 Cmd+V 會貼到我們的文字。
final class PasteInserter: TextInserter {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private static let vKeyCode: CGKeyCode = 9

    func insert(_ text: String) throws {
        let pasteboard = NSPasteboard.general
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

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false) else {
            throw InserterError.postFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // 等目標 App 讀走剪貼簿後還原
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
