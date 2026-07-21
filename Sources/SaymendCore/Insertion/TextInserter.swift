/// 文字插入介面（規格 §4.6 的 M1 子集）。
/// M1 只有「游標處插入」與「尾端退格」；範圍替換（AXInserter）屬 M2。
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
