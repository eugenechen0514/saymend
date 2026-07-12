/// 聚焦欄位快照與 AX 範圍替換的抽象（規格 §4.6／§5.3）。
/// Core 只定義介面與值型別；真 AX 實作在 app target 的 AXFieldAccess.swift。
public struct FieldContext: Equatable, Sendable {
    public var hasFocusedElement: Bool
    public var isSecure: Bool
    public var caretLocation: Int?

    public init(hasFocusedElement: Bool = false, isSecure: Bool = false, caretLocation: Int? = nil) {
        self.hasFocusedElement = hasFocusedElement
        self.isSecure = isSecure
        self.caretLocation = caretLocation
    }
}

public protocol FieldContextProviding: AnyObject {
    func snapshot() -> FieldContext
}

public enum RangeReplaceResult: Equatable, Sendable {
    case replaced      // 校驗通過且已替換（verify-only 時＝驗證通過）
    case mismatch      // 欄位現值與預期不符（外力改動）：呼叫端不得再改字
    case unsupported   // 該 App 不支援 AX 讀寫：退回 keystroke 路徑
}

/// AX 範圍操作。location 與 expected 的長度一律以 **UTF-16 單位**計（AX 慣例）；
/// FieldContext.caretLocation 亦同——這些數值只在 AX 路徑內流動，不與 grapheme 計數混用。
public protocol SessionRangeReplacing: AnyObject {
    /// 只驗證不動手：.replaced＝驗證通過。
    func verifyRange(location: Int, expected: String) -> RangeReplaceResult
    func replaceVerifiedRange(location: Int, expected: String, with newText: String) -> RangeReplaceResult
}
