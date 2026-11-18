import Foundation
import Testing
@testable import SaymendCore

/// 正式環境唯一的 `HUDScheduling`（issue #61）：要真的在主佇列**延遲**觸發，不得同步執行。
/// 比照 `MainQueueClipboardTimerTests.scheduleFiresOnTheMainQueueAfterTheDelay`，但「不得同步」改用
/// 區塊內讀「schedule 回來了沒」判定——不靠時序，不會因為測試執行緒被搶占而 flaky。
@Suite struct MainQueueHUDSchedulerTests {
    /// 非 MainActor：主佇列的 block 要由主執行緒排空，測試在別的執行緒等它。
    @Test func scheduleFiresOnTheMainQueueAfterTheDelay() {
        let fired = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var scheduleReturned = false
        var ranBeforeScheduleReturned = false
        var firedOnMain = false
        var elapsed: Double = 0
        let start = DispatchTime.now().uptimeNanoseconds
        MainQueueHUDScheduler().schedule(after: 0.02) {
            lock.withLock {
                ranBeforeScheduleReturned = !scheduleReturned
                firedOnMain = Thread.isMainThread
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            }
            fired.signal()
        }
        lock.withLock { scheduleReturned = true }
        #expect(fired.wait(timeout: .now() + 2) == .success, "0.02s 後應在主佇列觸發")
        lock.withLock {
            #expect(!ranBeforeScheduleReturned, "不得同步執行：schedule 回來之前區塊不得已經跑過")
            #expect(firedOnMain)
            #expect(elapsed >= 0.019, "要延遲 0.02s 才觸發；實際 \(elapsed)s")
        }
    }
}
