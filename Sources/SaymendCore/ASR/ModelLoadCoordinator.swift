import Foundation

/// 模型載入狀態（供設定頁顯示與引擎決定要不要先報「載入模型中…」）。
public enum ModelLoadState: Sendable {
    case idle       // 未載入（含已卸載）
    case loading    // 載入中（首次含 ANE 編譯，可能數分鐘）
    case loaded     // 已在記憶體，辨識可立即開始
}

/// 以路徑為 key 的 single-flight 模型載入（spec §3.1）。actor 序列化狀態，無鎖、無 TOCTOU。
///
/// - **single-flight**：同一模型的並行請求共用同一個 in-flight `Task`，不重複建立 3GB 模型。
/// - **序列化重載**：不同 key 的載入也一律排隊，同時最多一個 loader 在跑。否則使用者連點兩個
///   模型時兩份 3GB 會同時載入＝峰值記憶體無上界；排隊後峰值壓到「1 個載入中 ＋ 1 個快取」。
///   排隊亦使完成順序＝發起順序，於是**最後發起的載入才會成為 current**——慢的過期 preload
///   不會後來居上把使用者剛選的模型蓋掉。
/// - **有界快取**：只保留最近載入的一個模型——載入新 key 即淘汰舊的，讓 ARC 釋放記憶體，
///   避免多次切換模型累積數個 3GB pipe 而 OOM。
/// - **失敗不毒化**：in-flight 擲錯時以 `defer` 清掉該 key，下次呼叫會重新載入。
///
/// 泛型 `Model: Sendable`：真實情境為 `WhisperKitModelActor`（actor 即 Sendable，可安全跨界回傳）；
/// 單測以 `Model = String` ＋計數 loader 驗行為，不需 WhisperKit。
public actor ModelLoadCoordinator<Model: Sendable> {
    private let loader: @Sendable (URL) async throws -> Model
    private var current: (url: URL, model: Model)?
    private var inFlight: [URL: Task<Model, Error>] = [:]
    /// 排隊鏈尾：新載入等它完成才開跑（同時最多一個 loader）
    private var chainTail: Task<Void, Never>?
    /// 卸載世代：unload 遞增。載入完成時世代不符＝這份結果已過期，不得寫回 current。
    private var epoch = 0

    /// 卸載後等待舊排隊鏈的寬限期（見 `unload()`）。只在卸載後生效，正常排隊仍是無限期嚴格序列化。
    private let queueGrace: Duration

    public init(queueGrace: Duration = .seconds(60),
                loader: @escaping @Sendable (URL) async throws -> Model) {
        self.queueGrace = queueGrace
        self.loader = loader
    }

    private func cacheKey(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    public func state(for url: URL) -> ModelLoadState {
        let key = cacheKey(url)
        if let c = current, c.url == key { return .loaded }
        if inFlight[key] != nil { return .loading }
        return .idle
    }

    /// 卸載目前模型：放掉 current 讓 ARC 釋放（3GB），並取消在途載入。
    ///
    /// **best-effort**：WhisperKit 的載入未必能中途停（同 NEW-3），被取消的載入可能仍會跑完；
    /// 但 epoch 保證它跑完後**不會**把模型塞回 current，狀態一致性守得住。
    ///
    /// **排隊鏈不清空，但改成有時限地等它。** 清空會讓卸載後的新載入與仍在跑的舊載入重疊，
    /// 峰值記憶體失去上界；不清空又有致命的出口問題：載入若**永不返回**
    /// （實機 2026-07-28：App 閒置 20 小時、0% CPU、模型從未進記憶體，設定頁卻一直是
    /// 「載入中…」），鏈尾永遠不會完成，之後每一次載入都排在死掉的前置者後面——連
    /// 「卸載再載入」這個唯一的自救動作都失效，整個離線引擎永久壞死且沒有出口。
    ///
    /// 折衷：使用者按下卸載＝明確要求全部停手。肯回應取消的載入會在瞬間收工，等它不花成本、
    /// 序列化不變式完好；不肯停的載入等滿寬限期就放行，用一次短暫的記憶體重疊換回可復原性。
    /// **寬限期只在卸載後生效**——正常的連續換模型仍是無限期嚴格序列化，那才是不變式真正
    /// 要防的情境（連點兩個模型讓兩份 3GB 同時載入）。
    public func unload() {
        epoch &+= 1
        current = nil
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
        if let old = chainTail {
            let grace = queueGrace
            chainTail = Task { await Self.awaitBounded(old, grace: grace) }
        }
    }

    /// 等 `task` 完成，但最多等 `grace`。時限到就返回，不再理會它。
    ///
    /// 不用 `withTaskGroup`：group 在 closure 返回時會隱式等待所有子任務，而
    /// `await task.value` **不理會取消**——前置者永不返回時那個子任務也永遠不結束，
    /// group 於是卡在原地，等於沒有時限。
    private static func awaitBounded(_ task: Task<Void, Never>, grace: Duration) async {
        let signal = OneShotSignal()
        Task { await task.value; await signal.fire() }
        Task { try? await Task.sleep(for: grace); await signal.fire() }   // 保證訊號一定會響
        await signal.wait()
    }

    public func model(for url: URL) async throws -> Model {
        // symlink 與實體路徑是同一個模型，正規化後才當 key（REV #8）
        let key = cacheKey(url)
        if let c = current, c.url == key { return c.model }
        if let t = inFlight[key] { return try await t.value }        // 併發請求共用同一次載入
        let predecessor = chainTail
        let startEpoch = epoch
        let task = Task { [loader] in
            await predecessor?.value                                 // 排隊：前一個載入結束才輪到自己
            return try await loader(key)
        }
        inFlight[key] = task
        chainTail = Task { _ = try? await task.value }               // 成功或失敗都放行下一個
        // 只有自己還掛在該 key 上時才清：unload 後若已有新的載入接手，不可誤刪它
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        let m = try await task.value      // 擲錯 → defer 清 key、current 不變（不毒化）
        guard epoch == startEpoch else { return m }   // 中途被卸載：結果照給呼叫者，但不進快取
        current = (key, m)                // 淘汰舊模型；排隊使最後發起者最後寫入＝latest-wins
        return m
    }

    /// 背景預載（best-effort）：錯誤吞掉，由實際辨識時再擲出對應失敗。
    public func preload(_ url: URL) async { _ = try? await model(for: url) }
}

/// 一次性訊號：任一方先 `fire()` 就放行所有等待者，後續 `fire()` 無作用。
/// 供 `awaitBounded` 把「等前置者」與「等計時器」兩條路併成一個可返回的等待點。
private actor OneShotSignal {
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
