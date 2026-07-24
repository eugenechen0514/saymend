import Foundation

/// 以路徑為 key 的 single-flight 模型載入（spec §3.1）。actor 序列化狀態，無鎖、無 TOCTOU。
///
/// - **single-flight**：同一模型的並行請求共用同一個 in-flight `Task`，不重複建立 3GB 模型。
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

    public init(loader: @escaping @Sendable (URL) async throws -> Model) { self.loader = loader }

    public func model(for url: URL) async throws -> Model {
        if let c = current, c.url == url { return c.model }
        if let t = inFlight[url] { return try await t.value }        // 併發請求共用同一次載入
        let task = Task { try await loader(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let m = try await task.value      // 擲錯 → defer 清 key、current 不變（不毒化）
        current = (url, m)                // 淘汰舊模型
        return m
    }

    /// 背景預載（best-effort）：錯誤吞掉，由實際辨識時再擲出對應失敗。
    public func preload(_ url: URL) async { _ = try? await model(for: url) }
}
