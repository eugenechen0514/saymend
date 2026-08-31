/// AX 欄位 identity：綁定 session 起始的 process＋element，避免只靠 offset/text
/// 誤把另一個剛好同內容的 focused field 當成原目標（issue #21）。
public struct FieldIdentity: Equatable, Hashable, Sendable {
    /// Registry 發出的 opaque token；Core 不持有 AXUIElement，也不拿 hash 冒充 identity。
    public let token: UInt64

    public init(token: UInt64) {
        self.token = token
    }
}

/// Opaque field identity registry。production AX 與 stateful test fake 共用同一個 token/equality seam；
/// 因此「identity 比對永遠 true」這類 mutation 會直接破壞 final-field 測試，不會只測到假實作。
public final class FieldIdentityRegistry<Element> {
    private var nextToken: UInt64 = 1
    private var elements: [UInt64: Element] = [:]
    private let areEqual: (Element, Element) -> Bool

    public init(areEqual: @escaping (Element, Element) -> Bool) {
        self.areEqual = areEqual
    }

    public func identity(for element: Element) -> FieldIdentity {
        if let existing = elements.first(where: { areEqual($0.value, element) })?.key {
            return FieldIdentity(token: existing)
        }
        let token = nextToken
        nextToken &+= 1
        elements[token] = element
        return FieldIdentity(token: token)
    }

    public func matches(_ identity: FieldIdentity, element: Element) -> Bool {
        guard let original = elements[identity.token] else { return false }
        return areEqual(original, element)
    }

    public func release(_ identity: FieldIdentity?) {
        guard let identity else { return }
        elements.removeValue(forKey: identity.token)
    }
}

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
    public var fieldIdentity: FieldIdentity?
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
                fieldIdentity: FieldIdentity? = nil,
                selectedRange: SelectedRange? = nil,
                selectedText: String? = nil,
                contextBefore: String? = nil,
                contextAfter: String? = nil,
                frontAppBundleID: String? = nil,
                frontAppName: String? = nil) {
        self.hasFocusedElement = hasFocusedElement
        self.isSecure = isSecure
        self.caretLocation = caretLocation
        self.fieldIdentity = fieldIdentity
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
    /// session archive／被新 session 取代時釋放 App-side AX element registry entry。
    func releaseFieldIdentity(_ identity: FieldIdentity?)
}

public extension FieldContextProviding {
    func releaseFieldIdentity(_ identity: FieldIdentity?) {}
}

public enum RangeReplaceResult: Equatable, Sendable {
    case replaced      // 校驗通過且已替換（verify-only 時＝驗證通過）
    case mismatch      // 欄位現值與預期不符（外力改動）：呼叫端不得再改字
    case unsupported   // 該 App 不支援 AX 讀寫；是否可退 keystroke 由各操作的安全政策決定
}

/// AX 範圍操作。location 與 expected 的長度一律以 **UTF-16 單位**計（AX 慣例）；
/// FieldContext.caretLocation 亦同——這些數值只在 AX 路徑內流動，不與 grapheme 計數混用。
public protocol SessionRangeReplacing: AnyObject {
    /// 只驗證不動手：.replaced＝identity 與文字都通過。identity=nil 只供既有／低能力路徑；
    /// issue #21 的 Esc retraction 必須給 session 起始 identity，否則 fail closed。
    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult
    /// 替換後把游標收到新文字尾端（維持「session 即尾端、游標相對」的前提）。
    /// 被替換的那段就是尾端時用這個。
    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int,
                              expected: String, with newText: String) -> RangeReplaceResult
    /// 同上，但替換後把游標放回「同一個相對位置」（見 `caretAfterReplacement`）。
    /// session **中段**回溯改寫專用：後面還接著別的文字，游標若被收到被替換段落的尾端，
    /// 後續串流插入會落在句子中間、直接毀文。
    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int,
                                             expected: String, with newText: String) -> RangeReplaceResult
}
