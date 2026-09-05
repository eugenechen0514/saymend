/// 文字插入介面（規格 §4.6）。**只有「游標處插入」**——欄位上任何刪字／改寫都必須走 `SessionRangeReplacing`
/// 的 verified AX 範圍替換（issue #21／#44）。本 protocol 刻意沒有退格：讓「盲退格」在型別上就不可能，
/// 而不是靠每個呼叫端記得檢查。
///
/// **原子契約（issue #38）**：`insert` 必須「拋錯＝一個字都沒動、正常回傳＝全部送出」，中途不得留下部分進度。
/// `InsertionCoordinator.insertWithFallback` 在主 inserter 拋錯後**全量**重送給備援，依賴的就是這一點；
/// 若實作違反契約，欄位會拿到「前綴＋完整文字」。
/// 已知平台邊界：CGEvent.post 沒有 delivery acknowledgment，目標 App 靜默丟事件仍無法偵測；
/// 契約只涵蓋「實作自己半途 throw」這種可觀察的部分進度。
public protocol TextInserter: AnyObject {
    func insert(_ text: String) throws
}

public enum InserterError: Error, Equatable {
    case postFailed     // 事件建構失敗、寫入剪貼簿失敗：依原子契約，一個字都沒動
}
