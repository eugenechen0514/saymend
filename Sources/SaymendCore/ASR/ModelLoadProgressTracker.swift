import Foundation
import OSLog
import WhisperKit

/// 一趟載入到目前為止的進度（issue #17）。
public struct ModelLoadProgress: Equatable, Sendable {
    /// 已完成的階段。`seconds` 為 nil＝該則訊息本身沒帶耗時（特徵擷取器那一則就沒有）。
    public struct FinishedStage: Equatable, Sendable {
        public let stage: ModelLoadStage
        public let seconds: TimeInterval?
        public init(stage: ModelLoadStage, seconds: TimeInterval?) {
            self.stage = stage
            self.seconds = seconds
        }
    }

    public let finished: [FinishedStage]
    /// 正在載的階段；nil＝還沒進到任何階段，或剛結束一個、下一個還沒開始。
    public let currentStage: ModelLoadStage?
    /// **該階段**開始的時刻，不是整趟載入開始的時刻。混用會讓最長的那一段
    /// （音訊編碼器，實測 527 秒）顯示成從頭算起，數字直接翻倍。
    public let currentStageStartedAt: Date?

    public init(finished: [FinishedStage], currentStage: ModelLoadStage?,
                currentStageStartedAt: Date?) {
        self.finished = finished
        self.currentStage = currentStage
        self.currentStageStartedAt = currentStageStartedAt
    }
}

/// 一趟走完的載入（issue #17）：寫進 `ModelLoadHistory` 當下次的參照。
public struct CompletedLoad: Equatable, Sendable {
    public let total: TimeInterval
    public let stages: [ModelLoadStage: TimeInterval]
    public init(total: TimeInterval, stages: [ModelLoadStage: TimeInterval]) {
        self.total = total
        self.stages = stages
    }
}

/// 把 WhisperKit 的 log 訊息累積成載入進度（issue #17）。
///
/// **為什麼需要它**：載入期間 App 的 CPU 幾乎是 0%（工作在 CoreML／ANE 側的外部 process），
/// 記憶體也不是單調上升。「合法地載了十分鐘」與「已經死掉」在外部沒有任何可觀察的差別，
/// 而一個往上跳的碼表在兩種情況下都一樣會跳。階段轉換才是活著的訊號。
///
/// **process-wide**：`Logging.shared` 是套件的 singleton，攔截點只有一個，所以本型別也只該有
/// 一份實例。載入由 `ModelLoadCoordinator` 序列化，正常情況下同時只有一趟在跑；
/// 唯一的例外是卸載後寬限期放行的重疊（見 `ModelLoadCoordinator.unload()`），
/// 那時兩趟的訊息會交錯進來。後果是進度顯示錯亂，不是資料損毀，且該情境本身就是罕見的自救路徑。
///
/// callback 可能來自任何執行緒，狀態一律以 `NSLock` 保護（比照 `WhisperKitEngine.stateLock`）。
public final class ModelLoadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let forward: (@Sendable (String) -> Void)?

    private var sawAnyMilestone = false
    private var finished: [ModelLoadProgress.FinishedStage] = []
    private var currentStage: ModelLoadStage?
    private var currentStageStartedAt: Date?
    private var completed: CompletedLoad?

    /// - Parameter forward: 每一則訊息都會原樣送到這裡，**包含認不得的**。
    ///   裝了 callback 之後套件就不再寫系統 logger，這裡不轉發等於把開發者查錯用的資料弄不見。
    public init(now: @escaping @Sendable () -> Date = Date.init,
                forward: (@Sendable (String) -> Void)? = nil) {
        self.now = now
        self.forward = forward
    }

    /// 吃一則 WhisperKit 的 log 訊息。這是本型別唯一的輸入，也是單測的接縫——
    /// 測試不需要 WhisperKit，更不需要真的載一顆 3GB 模型。
    public func ingest(_ message: String) {
        forward?(message)
        guard let event = WhisperLoadLogParser.event(from: message) else { return }
        lock.lock()
        defer { lock.unlock() }
        sawAnyMilestone = true
        switch event {
        case .loadBegan:
            resetLocked()
        case .stageBegan(let s):
            currentStage = s
            currentStageStartedAt = now()
        case .stageFinished(let s, let secs):
            finished.append(.init(stage: s, seconds: secs))
            currentStage = nil
            currentStageStartedAt = nil
        case .loadFinished(let total):
            var stages: [ModelLoadStage: TimeInterval] = [:]
            for f in finished { if let secs = f.seconds { stages[f.stage] = secs } }
            completed = CompletedLoad(total: total, stages: stages)
            currentStage = nil
            currentStageStartedAt = nil
        }
    }

    /// 目前的進度；**從未認出任何里程碑時回 nil**。
    ///
    /// 「沒有進度資料」與「進度為空」是兩件事：設定頁靠這個差別決定要不要顯示階段清單。
    /// 套件升級把訊息字串全改掉時，這裡會一直是 nil，UI 自然退回純碼表——那是刻意的降級路徑。
    public func snapshot() -> ModelLoadProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard sawAnyMilestone else { return nil }
        return ModelLoadProgress(finished: finished,
                                 currentStage: currentStage,
                                 currentStageStartedAt: currentStageStartedAt)
    }

    /// 新的一趟載入開始。
    ///
    /// 與 `Loading models...` 這則訊息重複是刻意的：字串解析可能因套件升級而失效，
    /// 但「新的一趟開始了」這件事 loader 自己知道，不該外包給 log 字串。
    public func beginLoad() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    /// 最近一趟**走完**的載入；沒有收到總結訊息就是 nil。
    ///
    /// 不拿階段時間硬湊 total 冒充：湊出來的數字會被寫進歷史，下一次載入就拿一個假的參照
    /// 去嚇使用者，而使用者無從得知那是估的。
    public func completedLoad() -> CompletedLoad? {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    /// 掛上套件的 log 攔截點。`Logging.shared` 是 singleton，最後一個呼叫者勝出。
    public func installAsWhisperKitLogSink() {
        Logging.updateCallback { [weak self] message in self?.ingest(message) }
    }

    private func resetLocked() {
        sawAnyMilestone = true
        finished = []
        currentStage = nil
        currentStageStartedAt = nil
        completed = nil
    }
}


/// 跑一趟載入並做完該做的紀錄（issue #17）。
///
/// 抽成泛型純函式**是為了測得到**：真實路徑要載一顆 3GB 模型才跑得動，而這裡的四件事
/// （重置追蹤器、成功才寫歷史、無論成敗都調回 log 等級、失敗不留半筆）任何一件錯了，
/// 都不會有編譯或執行期徵兆——只會讓使用者幾週後看到一個錯的「上次耗時」。
public enum ModelLoadRun {
    public static func perform<M>(url: URL,
                                  tracker: ModelLoadProgressTracker,
                                  history: ModelLoadHistory,
                                  onFinish: @Sendable () -> Void,
                                  make: @Sendable (URL) async throws -> M) async throws -> M {
        tracker.beginLoad()
        defer { onFinish() }                    // 擲錯也要跑：log 等級不能停在載入期的 .debug
        let model = try await make(url)
        // 沒收到總結訊息就沒有可信的耗時（套件升級改了字串時就會這樣），此時什麼都不寫——
        // 寧可下次沒有參照，也不要一個編出來的參照。
        if let done = tracker.completedLoad() { history.record(done, for: url) }
        return model
    }
}
