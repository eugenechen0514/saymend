import Foundation
import Testing
@testable import SaymendApp

/// issue #42：等待期間 event tap 要活著、主佇列不能被排空。
@Suite struct EventTapFriendlyWaitTests {
    /// 加進私有 mode 的 source 在等待期間會被服務——tap 就是這樣的 source。
    @MainActor @Test func servesSourcesRegisteredInItsModeWhileWaiting() {
        var fired = false
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { _ in
            fired = true
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, EventTapFriendlyWait.mode)
        defer { CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, EventTapFriendlyWait.mode) }
        let start = ProcessInfo.processInfo.systemUptime
        EventTapFriendlyWait.wait(0.06)
        #expect(fired, "私有 mode 裡的 timer 必須在等待期間觸發")
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.06, "要等滿指定時間，不能因為處理了事件就提早回來")
    }

    /// 主佇列不排空：呼叫端（MainActor 上的 controller、SwiftUI action）不會在等待期間被重入。
    @MainActor @Test func doesNotDrainTheMainQueueWhileWaiting() {
        var ran = false
        DispatchQueue.main.async { ran = true }
        EventTapFriendlyWait.wait(0.03)
        #expect(!ran, "等待期間不得執行主佇列上的 block")
    }

    /// mode 裡沒有 source 時退回純睡眠，仍要等滿。
    @MainActor @Test func fallsBackToSleepingWhenNothingIsRegistered() {
        let start = ProcessInfo.processInfo.systemUptime
        EventTapFriendlyWait.wait(0.03)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.03)
    }
}
