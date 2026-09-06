import AppKit
import CoreGraphics

/// Cmd+C 選取讀取備援（規格 §3.6；M3 互審裁決：只走 profile 白名單，不盲發）。
/// 「暫時清空剪貼簿→合成 Cmd+C→短等→讀取→還原」，保存／還原交給 ClipboardChannel（issue #42）——
/// 撞上在途 paste 時 channel 會先等它的安全窗走完，不會把還沒被目標 App 讀走的文字清掉。
/// 同步阻塞約 120ms，僅白名單 App 承擔。
/// 合成事件鐵律：顯式 flags=[.maskCommand]（使用者正按著熱鍵修飾鍵，combinedSessionState
/// 會疊旗——M2 教訓）＋syntheticMarker（HotkeyMonitor 據此不算使用者活動）。
final class ClipboardSelectionReader {
    private let channel: any KeyEventChannel
    private let clipboard: ClipboardChannel
    private static let cKeyCode: CGKeyCode = 8

    init(channel: any KeyEventChannel = CGKeyEventChannel(), clipboard: ClipboardChannel = .general) {
        self.channel = channel
        self.clipboard = clipboard
    }

    func readSelection() -> String? {
        let text = clipboard.withTransientRead {
            for down in [true, false] {
                guard let event = channel.makeKeyEvent(virtualKey: Self.cKeyCode, keyDown: down) else { continue }
                event.flags = [.maskCommand]
                event.setIntegerValueField(.eventSourceUserData, value: KeystrokeInserter.syntheticMarker)
                channel.post(event)
            }
            usleep(120_000)                          // 等目標 App 寫入剪貼簿
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
