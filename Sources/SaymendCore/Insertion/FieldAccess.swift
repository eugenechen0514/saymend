/// 聚焦欄位快照（熱鍵按下瞬間取得，規格 §3.6）。
/// selectedRange／caretLocation 一律 UTF-16 單位（AX 慣例）；contextBefore/After 是游標（或選取）
/// 前後的窗口文字，僅作 LLM 語境，不參與任何範圍計算。
/// Core 只定義介面與值型別；真 AX 實作在 app target 的 AXFieldAccess.swift。
public struct FieldContext: Equatable, Sendable {
    public struct SelectedRange: Equatable, Sendable {
        public var location: Int   // UTF-16
        public var length: Int     // UTF-16
        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public var hasFocusedElement: Bool
    public var isSecure: Bool
    public var caretLocation: Int?
    public var selectedRange: SelectedRange?
    public var selectedText: String?
    public var contextBefore: String?
    public var contextAfter: String?
    /// 前景 App（規格 §4.7 FrontAppInfo；App 端 AXFieldReader 以 NSWorkspace 填入）
    public var frontAppBundleID: String?
    public var frontAppName: String?

    public init(hasFocusedElement: Bool = false,
                isSecure: Bool = false,
                caretLocation: Int? = nil,
                selectedRange: SelectedRange? = nil,
                selectedText: String? = nil,
                contextBefore: String? = nil,
                contextAfter: String? = nil,
                frontAppBundleID: String? = nil,
                frontAppName: String? = nil) {
        self.hasFocusedElement = hasFocusedElement
        self.isSecure = isSecure
        self.caretLocation = caretLocation
        self.selectedRange = selectedRange
        self.selectedText = selectedText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.frontAppBundleID = frontAppBundleID
        self.frontAppName = frontAppName
    }

    /// 選取即目標的門檻：range 有長度且真的讀到了文字。
    /// 只有 range 沒有文字＝AX 讀值失敗，寧可當無選取（走一般聽寫），不可對讀不到的目標動手。
    public var hasSelection: Bool {
        guard let r = selectedRange, r.length > 0,
              let t = selectedText, !t.isEmpty else { return false }
        return true
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
