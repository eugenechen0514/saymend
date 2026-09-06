import Foundation
import Testing
@testable import SaymendApp

/// 正式環境唯一的 `ClipboardTimer`：wait 要走 event tap 友善的等待、schedule 要真的在主佇列延遲觸發。
@Suite struct MainQueueClipboardTimerTests {
    @MainActor @Test func waitKeepsSourcesInTheFriendlyModeAlive() {
        var fired = false
        let cfTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { _ in
            fired = true
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), cfTimer, EventTapFriendlyWait.mode)
        defer { CFRunLoopRemoveTimer(CFRunLoopGetMain(), cfTimer, EventTapFriendlyWait.mode) }
        MainQueueClipboardTimer().wait(0.05)
        #expect(fired, "Thread.sleep 會讓 event tap 停擺；wait 必須跑在 EventTapFriendlyWait 的 mode")
    }

    /// 非 MainActor：主佇列的 block 要由主執行緒排空，測試在別的執行緒等它。
    @Test func scheduleFiresOnTheMainQueueAfterTheDelay() {
        let fired = DispatchSemaphore(value: 0)
        var firedOnMain = false
        let timer = MainQueueClipboardTimer()
        var firedSynchronously = true
        timer.schedule(after: 0.02) {
            firedOnMain = Thread.isMainThread
            fired.signal()
        }
        firedSynchronously = false
        #expect(!firedSynchronously)
        #expect(fired.wait(timeout: .now() + 2) == .success, "0.02s 後應在主佇列觸發")
        #expect(firedOnMain)
    }

    @Test func nowAdvancesWithSystemUptime() {
        let timer = MainQueueClipboardTimer()
        let a = timer.now
        Thread.sleep(forTimeInterval: 0.01)
        #expect(timer.now - a >= 0.01)
    }
}
