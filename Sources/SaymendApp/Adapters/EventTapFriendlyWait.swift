import Foundation
import CoreFoundation

/// 主執行緒上的短暫同步等待，但**不讓 HotkeyMonitor 的 event tap 停擺**（issue #42）。
///
/// tap 掛在 main run loop、`.headInsertEventTap`：main 一 `Thread.sleep`／`usleep`，整個 session 的鍵盤與滑鼠事件
/// 都卡在我們的 callback 前面——包含我們自己剛送出的合成 Cmd+V／Cmd+C。等目標 App 讀走剪貼簿卻把它要收的
/// 事件一起卡住，等了等於沒等；熱鍵放開的時間戳也會被拖晚，tap／hold 誤判。
///
/// 做法：跑在私有 run loop mode。只有明確加進這個 mode 的 source（HotkeyMonitor 的 tap）會被服務；
/// 主佇列（MainActor 任務、`DispatchQueue.main.async`）與 UI 都不會在等待期間執行——呼叫端不會被重入。
/// mode 裡沒有任何 source 時（tap 未啟動）`CFRunLoopRunInMode` 立刻回 `.finished`，退回 `Thread.sleep`。
enum EventTapFriendlyWait {
    static let mode = CFRunLoopMode("io.saymend.event-tap-friendly-wait" as CFString)

    static func wait(_ seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            if CFRunLoopRunInMode(mode, remaining, false) == .finished {
                Thread.sleep(forTimeInterval: remaining)
                return
            }
        }
    }
}
