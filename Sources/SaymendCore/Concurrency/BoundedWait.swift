import Foundation

/// 一次性訊號：任一方先 `fire()` 就放行所有等待者，後續 `fire()` 無作用。
///
/// 用來把多條「誰先到就算誰」的路徑併成一個可返回的等待點。
/// **不用 `withTaskGroup`**：group 在 closure 返回時會隱式等待所有子任務，而
/// `await task.value` **不理會取消**——前置者永不返回時那個子任務也永遠不結束，
/// group 於是卡在原地，等於沒有時限。
actor OneShotSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// 有界等待的結果。
enum BoundedWaitOutcome: Equatable, Sendable {
    case completed
    case timedOut
    case cancelled
}

/// 等 `work` 完成、等時限到、等自己被取消，誰先到就返回。
///
/// **不中止 `work`。** 呼叫端要的是自己能走，不是把對方殺掉——本專案唯一的使用者是
/// 「等本機模型載入」，而那是 CoreML／ANE 的**同步 XPC 等待**：實機對卡住的 process 取
/// `sample`，920 個取樣全部停在
/// `MLModel loadContentsOfURL → … → -[_ANEClient doLoadModel:] →`
/// `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__ → mach_msg2_trap`。
/// `Task.cancel()` 只設旗標，而那條執行緒不會回到任何 `await` 檢查點。
/// 逾時之後載入會繼續在背景跑完，下一次就能用；假裝殺得掉只會多出一個騙人的 API，
/// 還會白白丟掉已經投入的十分鐘。
///
/// 取消那一路用 `withTaskCancellationHandler` 而不是輪詢 `Task.isCancelled`：
/// `withCheckedContinuation` 本身不是取消點，而輪詢用的 `Task {}` **不繼承取消**，
/// 兩者都救不了掛住的等待。
///
/// - Returns: 誰先到。`work` 在 `.timedOut`／`.cancelled` 之後仍會繼續跑到完。
func awaitBounded(limit: Duration,
                  work: @escaping @Sendable () async -> Void) async -> BoundedWaitOutcome {
    let signal = OneShotSignal()
    let winner = FirstWinner()

    Task {
        await work()
        await winner.set(.completed)
        await signal.fire()
    }
    Task {
        try? await Task.sleep(for: limit)
        await winner.set(.timedOut)
        await signal.fire()
    }

    await withTaskCancellationHandler {
        await signal.wait()
    } onCancel: {
        Task {
            await winner.set(.cancelled)
            await signal.fire()
        }
    }
    return await winner.value
}

/// 記下第一個到達者。先 `set` 再 `fire`，actor 的順序保證讓等待端醒來時一定讀得到。
private actor FirstWinner {
    private var settled: BoundedWaitOutcome?
    func set(_ v: BoundedWaitOutcome) { if settled == nil { settled = v } }
    /// 預設 `.timedOut`：理論上等待端醒來時必然已 settled，萬一沒有，
    /// 「當成逾時」是唯一安全的猜測——它讓呼叫端放棄等待，不會把沒載好的模型帶進辨識。
    var value: BoundedWaitOutcome { settled ?? .timedOut }
}
