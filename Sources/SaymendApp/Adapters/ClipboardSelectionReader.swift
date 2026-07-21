import AppKit
import CoreGraphics

/// Cmd+C 選取讀取備援（規格 §3.6；M3 互審裁決：只走 profile 白名單，不盲發）。
/// 「保存剪貼簿→合成 Cmd+C→短等→讀取→還原」。同步阻塞約 120ms，僅白名單 App 承擔。
/// 合成事件鐵律：顯式 flags=[.maskCommand]（使用者正按著熱鍵修飾鍵，combinedSessionState
/// 會疊旗——M2 教訓）＋syntheticMarker（HotkeyMonitor 據此不算使用者活動）。
final class ClipboardSelectionReader {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private static let cKeyCode: CGKeyCode = 8

    func readSelection() -> String? {
        let pasteboard = NSPasteboard.general
        // 保存（逐 item 逐 type 複製 data——同 PasteInserter 模式）
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        pasteboard.clearContents()

        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.cKeyCode, keyDown: down) else { continue }
            event.flags = [.maskCommand]
            event.setIntegerValueField(.eventSourceUserData, value: KeystrokeInserter.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        usleep(120_000)                              // 等目標 App 寫入剪貼簿

        let text = pasteboard.string(forType: .string)

        // 還原
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }

        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
