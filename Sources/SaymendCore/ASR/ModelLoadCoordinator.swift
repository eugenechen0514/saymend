import Foundation

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

    public init(loader: @escaping @Sendable (URL) async throws -> Model) { self.loader = loader }

    public func model(for url: URL) async throws -> Model {
        // symlink 與實體路徑是同一個模型，正規化後才當 key（REV #8）
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        if let c = current, c.url == key { return c.model }
        if let t = inFlight[key] { return try await t.value }        // 併發請求共用同一次載入
        let predecessor = chainTail
        let task = Task { [loader] in
            await predecessor?.value                                 // 排隊：前一個載入結束才輪到自己
            return try await loader(key)
        }
        inFlight[key] = task
        chainTail = Task { _ = try? await task.value }               // 成功或失敗都放行下一個
        defer { inFlight[key] = nil }
        let m = try await task.value      // 擲錯 → defer 清 key、current 不變（不毒化）
        current = (key, m)                // 淘汰舊模型；排隊使最後發起者最後寫入＝latest-wins
        return m
    }

    /// 背景預載（best-effort）：錯誤吞掉，由實際辨識時再擲出對應失敗。
    public func preload(_ url: URL) async { _ = try? await model(for: url) }
}
