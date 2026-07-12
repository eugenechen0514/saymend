/// 文字插入介面（規格 §4.6 的 M1 子集）。
/// M1 只有「游標處插入」與「尾端退格」；範圍替換（AXInserter）屬 M2。
public protocol TextInserter: AnyObject {
    func insert(_ text: String) throws
    func deleteBackward(count: Int) throws
}

public enum InserterError: Error, Equatable {
    case unsupported
    case postFailed
}
