import ApplicationServices
import OSLog

/// AX 訊息 timeout（issue #37 調查時發現的獨立缺陷，與 TOCTOU 無關）。
///
/// 每一次 `AXUIElementCopyAttributeValue` / `AXUIElementSetAttributeValue` 都是**同步阻塞**的跨行程 IPC，
/// 而我們大量在 main thread 上呼叫它們（每句上屏的讀值與範圍替換、10Hz 的 overlay 座標輪詢）。
/// 沒設 timeout 就吃系統預設（最壞可到秒級），目標 App 一卡住，掛在 main run loop 的熱鍵 event tap
/// 也跟著被拖住——使用者連 Esc 中止都按不動。
///
/// 語意依 `AXUIElement.h` 的 `AXUIElementSetMessagingTimeout` 說明：
/// 「Pass the system-wide accessibility object if you want to set the timeout globally for this process.
///  Setting the timeout on another accessibility object sets it only for that object」，
/// 所以對 system-wide element 設一次即涵蓋本行程之後送出的所有 AX 訊息，不必逐元素設。
enum AXMessagingTimeout {
    /// 出貨預設 0.2 秒：正常 AX 回應在 sub-ms～數 ms 等級，200ms 已遠超正常值（不會誤殺健康的 App），
    /// 又短到卡住的 App 拖不垮熱鍵回應。
    static let defaultSeconds: Float = 0.2

    private static let logger = Logger(subsystem: "io.saymend.app", category: "ax")

    /// 對 system-wide element 設定本行程的全域 AX 訊息 timeout。
    /// 回傳 `AXError` 讓呼叫端看得見失敗——設不起來不影響功能（只是沿用系統預設 timeout），
    /// 所以不 crash、不擋啟動，但一律留下 log，不靜默假裝成功。
    /// element 刻意**不開成參數**：header 說得很清楚，設在非 system-wide 元素上只影響那一顆元素，
    /// 開成參數等於讓「一行就把全域設定退化成單元素設定」變得可能，而測試只驗預設路徑攔不到。
    /// `set` 是唯一的測試 seam；production 一律用預設值。
    @discardableResult
    static func applyGlobally(seconds: Float = defaultSeconds,
                              set: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout) -> AXError {
        // header 明列 timeout 必須為正數；且對 system-wide element 傳 0 是「重置回系統預設」，
        // 正是本函式要避免的狀態，故在送進 C API 之前就擋下。
        guard seconds > 0 else {
            logger.error("AX 訊息 timeout 設定值不合法（\(seconds) 秒），沿用系統預設")
            return .illegalArgument
        }
        let result = set(AXUIElementCreateSystemWide(), seconds)
        if result != .success {
            logger.error("設定 AX 訊息 timeout 失敗（AXError \(result.rawValue)），沿用系統預設")
        }
        return result
    }
}
