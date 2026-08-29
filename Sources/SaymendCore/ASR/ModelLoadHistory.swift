import Foundation

/// 每顆模型載入**最久**花過多久（issue #17）。
///
/// **為什麼需要它**：階段轉換證明模型還活著，但回答不了「還要多久」。同一台機器、同一顆
/// large-v3_turbo，實測冷載入是 543 秒／631 秒／1297 秒——差 2.4 倍。使用者需要的不是
/// 一個絕對數字，而是一個參照：「上次這一步花了 8:47，現在 4:25」比「4:25」有用得多。
///
/// 也是示警門檻的依據來源（見 `ModelLoadStatusText.shouldWarn`）。沒有紀錄時就沒有依據，此時不編造。
///
/// **記最大值而不是最近一次**——這是實機驗收（2026-08-23）改掉的設計。原本記最近一次，
/// 而 tiny 冷載入 16.88 秒、之後每次暖載入只要 0.5 秒，於是歷史被 0.56 蓋掉。
/// 下次 ANE 快取被系統回收（`~/Library/Caches` 會被回收，也會被第三方清理工具清掉）
/// 而重新冷編譯時，門檻是 `0.56 × 3 = 1.7 秒`——一趟完全合法的 17 秒冷載入會從第 2 秒起
/// 一路示警。暖載入污染冷載入的參照，正是誤殺的來源。
///
/// 代價：一次異常的慢載入會永久墊高參照。這是刻意的取捨——參照要回答的是
/// 「這台機器上這顆模型可能要多久」，而那個問題的答案就是看過的最壞情況。
///
/// 存 UserDefaults 而不進 GRDB 歷史庫：這不是聽寫內容，與隱私開關（`historyEnabled`）無關，
/// 而且它必須在使用者關掉歷史記錄時照樣可用——否則關掉歷史就再也看不到載入參照。
public final class ModelLoadHistory: @unchecked Sendable {
    public static let defaultsKey = "whisperModelLoadHistory"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 落地形狀。階段以 `ModelLoadStage.rawValue` 當 key——未來新增階段時，
    /// 舊版讀到不認得的名字要略過而不是整筆丟掉（見 `last(for:)`）。
    private struct Stored: Codable {
        var total: Double
        var stages: [String: Double]
    }

    /// 記下一趟走完的載入。**逐項取最大值**與既有紀錄合併（見型別說明）。
    public func record(_ load: CompletedLoad, for modelPath: URL) {
        lock.lock()
        defer { lock.unlock() }
        var all = readAllLocked()
        let key = ModelPathKey.string(modelPath)
        let existing = all[key]
        var stages = existing?.stages ?? [:]
        for (stage, seconds) in load.stages {
            stages[stage.rawValue] = max(seconds, stages[stage.rawValue] ?? 0)
        }
        all[key] = Stored(total: max(load.total, existing?.total ?? 0), stages: stages)
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// 看過最久的一趟；沒有紀錄回 nil。**不得回 0 冒充**——UI 會把它顯示成「上次 0:00」，
    /// 而示警門檻是「最久那次的 3 倍」，0 會讓每一次載入從第一秒就在示警。
    public func last(for modelPath: URL) -> CompletedLoad? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = readAllLocked()[ModelPathKey.string(modelPath)] else { return nil }
        var stages: [ModelLoadStage: TimeInterval] = [:]
        for (name, seconds) in stored.stages {
            guard let stage = ModelLoadStage(rawValue: name) else { continue }   // 前向相容
            stages[stage] = seconds
        }
        return CompletedLoad(total: stored.total, stages: stages)
    }

    /// 讀不出來就當成空的。這是使用者的 UserDefaults，什麼都可能被寫進去；
    /// 毀損時要能被下一次 `record` 覆蓋掉而不是永久卡住。
    private func readAllLocked() -> [String: Stored] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        return all
    }
}
