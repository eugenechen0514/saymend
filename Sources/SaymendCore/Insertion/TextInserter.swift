/// 文字插入介面（規格 §4.6 的 M1 子集）。
/// M1 只有「游標處插入」與「尾端退格」；範圍替換（AXInserter）屬 M2。
///
/// **原子契約（issue #38）**：兩個方法都必須「拋錯＝一個字都沒動、正常回傳＝全部送出」，
/// 中途不得留下部分進度。InsertionCoordinator 的兩條路徑直接依賴這一點：
/// `insertWithFallback` 在主 inserter 拋錯後**全量**重送給備援；`deleteAndRetype` 把
/// `deleteBackward` 放在鐵律回復的 do 區塊之外、拋錯直接往上傳。若實作違反契約，
/// 前者會留下「前綴＋完整文字」、後者會留下刪了一半的欄位。
/// 已知平台邊界：CGEvent.post 沒有 delivery acknowledgment，目標 App 靜默丟事件仍無法偵測；
/// 契約只涵蓋「實作自己半途 throw」這種可觀察的部分進度。
public protocol TextInserter: AnyObject {
    func insert(_ text: String) throws
    func deleteBackward(count: Int) throws
}

public enum InserterError: Error, Equatable {
    case unsupported
    case postFailed
    case replaceFailedRestored     // 替換失敗，但原文已回復（鐵律守住）
    case lostText(String)          // 原文救不回來；呼叫端以剪貼簿急救
}
