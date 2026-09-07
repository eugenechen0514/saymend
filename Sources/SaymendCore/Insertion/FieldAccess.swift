/// AX 欄位 identity（issue #21／#43）：綁定 session 起始的那個 element，而不是靠 offset＋文字猜。
/// 兩個欄位 offset 相同、文字相同、卻不是同一個的情況（表單相鄰欄位、maxlength 自動跳格）只有 identity 抓得到。
/// Core 不持有 AXUIElement，只拿 registry 發出的 opaque token；也不拿 hash 冒充 identity。
public struct FieldIdentity: Equatable, Hashable, Sendable {
    public let token: UInt64

    public init(token: UInt64) {
        self.token = token
    }
}

/// Opaque identity registry。production AX（`areEqual` = CFEqual）與測試 fake 共用同一個 token／equality／release seam，
/// 所以「identity 比對永遠 true」這類 mutation 會直接破壞 final-field 測試，不會只測到假實作。
///
/// **引用計數**：reader→ledger 與 FeedbackCoordinator 會各自 pin 同一個 element。不計數的話，先釋放的一方會把
/// 另一方仍在用的 token 弄死（`matches` 變 false → overlay 中途消失，或刪字驗證誤判 fail closed）。
/// 全部持有者釋放後 entry 才移除；此後同一 element 再登記會拿到**新** token——舊 session 殘留的 token
/// 不能對上新 session 的欄位。
public final class FieldIdentityRegistry<Element> {
    private struct Entry {
        let element: Element
        var holders: Int
    }
    private var nextToken: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]
    private let areEqual: (Element, Element) -> Bool

    public init(areEqual: @escaping (Element, Element) -> Bool) {
        self.areEqual = areEqual
    }

    /// 登記（或再登記）一個 element，回傳其 token 並增加一個持有者。
    public func identity(for element: Element) -> FieldIdentity {
        if let key = entries.first(where: { areEqual($0.value.element, element) })?.key {
            entries[key]!.holders += 1
            return FieldIdentity(token: key)
        }
        let token = nextToken
        nextToken &+= 1
        entries[token] = Entry(element: element, holders: 1)
        return FieldIdentity(token: token)
    }

    /// token 是否仍指向與 `element` 相同的元素；已釋放或未知的 token 一律 false。
    public func matches(_ identity: FieldIdentity, element: Element) -> Bool {
        guard let entry = entries[identity.token] else { return false }
        return areEqual(entry.element, element)
    }

    /// token 對應的原始 element（App 端拿它做 AX 查詢）；已釋放回 nil。
    public func element(for identity: FieldIdentity) -> Element? {
        entries[identity.token]?.element
    }

    /// 仍有持有者的 entry 數
    public var count: Int { entries.count }

    /// 減少一個持有者；歸零即移除。nil／未知 token／多釋放皆為 no-op，計數不會變負。
    public func release(_ identity: FieldIdentity?) {
        guard let identity, var entry = entries[identity.token] else { return }
        entry.holders -= 1
        if entry.holders <= 0 {
            entries.removeValue(forKey: identity.token)
        } else {
            entries[identity.token] = entry
        }
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
    /// 聚焦元素的 identity token（issue #43）；nil＝reader 讀不到 element（無 AX）。
    /// 由 App 端 registry 發出，controller 存進 ledger、archive 時經 `releaseFieldIdentity` 歸還。
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

/// 輕量焦點閘門（issue #37 shadow 階段）：每句 finalized 上屏前只需要回答
/// 「現在聚焦的還是不是 session 起始那個元素、是不是密碼欄位」，不需要 range／選取／全文。
/// 換掉完整 snapshot 之後，每句的 AX 屬性讀取從 4–5 次降到 2 次，且不再有「聽寫途中對目前焦點
/// 發合成 Cmd+C」的隱患（snapshot 的選取備援路徑）。
///
/// **`.unknown` 是安全值**：讀不到焦點、或兩邊沒有 identity 可比（無 AX 的 App）都落在這裡，
/// 呼叫端一律當作「照常上屏」——issue #21 的裁定，純追加永遠不得因缺 AX 而停。
public enum FieldGate: Equatable, Sendable {
    /// AX 明確：焦點就是 session 起始那個 element
    case same
    /// AX 明確：焦點已換到別的 element（附現在的前景 App bundleID，供診斷判讀同 App 或跨 App）
    case different(currentAppBundleID: String?)
    /// AX 明確回答：目前焦點就是密碼欄位
    case secure
    /// AX 連續兩次問不出 subrole（逾時），依 #59 fail closed 當密碼欄擋下——
    /// **但這是「不知道」不是「知道」**。行為與 `.secure` 相同，分開只為了讓事後資料
    /// 分得出「真的密碼欄」與「AX 沒回應被誤殺」：後者若在真實世界很頻繁，
    /// 代表 0.2s 的 AX 訊息 timeout 太短、或某些 App 天生慢，是要調整的訊號。
    /// 兩者混成同一個值就永遠量不出這件事。
    case secureUnknown
    /// 讀不到焦點／沒有 identity 可比 → 維持 #21，照常追加
    case unknown
}

public protocol FieldContextProviding: AnyObject {
    func snapshot() -> FieldContext
    /// session archive 時歸還 `snapshot().fieldIdentity` 發出的 token（issue #43）。
    /// registry 有引用計數：FeedbackCoordinator 可能同時持有同一 element 的 token，這裡只減自己那一份。
    func releaseFieldIdentity(_ identity: FieldIdentity?)
    /// 焦點閘門（issue #37）。`sessionIdentity` 是 session 起始登記的那個 element token（nil＝沒有）。
    /// 實作**只能**用 `FieldIdentityRegistry.matches`，不得呼叫 `identity(for:)`——後者會多發一個持有者，
    /// 破壞「每個非 nil token 恰歸還一次」的 lease 不變式（issue #43）。
    func fieldGate(sessionIdentity: FieldIdentity?) -> FieldGate
}

public extension FieldContextProviding {
    /// 沒有 identity 概念的 reader（無 AX、測試 fake）不需要做任何事。
    func releaseFieldIdentity(_ identity: FieldIdentity?) {}

    /// 由 `snapshot()` 推導的預設閘門：對不在意閘門的 reader，行為與「完整 snapshot ＋ 當場歸還 token」
    /// 逐位元相同（同樣一次 snapshot、同樣一次歸還），只是把 secure 與 identity 兩件事一起答出來。
    /// 有能力做輕量查詢的 reader（App 端 AXFieldReader）自行覆寫，省掉整份 snapshot 的跨行程 IPC。
    func fieldGate(sessionIdentity: FieldIdentity?) -> FieldGate {
        let context = snapshot()
        // 閘門用的 token 不採用，當場歸還（issue #43）。nil 不呼叫 reader——比照 controller 的 releaseFieldLease，
        // 讓「每個非 nil token 恰歸還一次」在測試裡乾淨可驗。
        if let current = context.fieldIdentity { releaseFieldIdentity(current) }
        // secure 必須排在 identity 之前：密碼欄位不登記 identity，兩邊都沒有 token 可比。
        // 這裡**給不出 `.secureUnknown`**：`FieldContext.isSecure` 是個布林，snapshot 早已把
        // 「AX 明確說是密碼欄」與「問不出來所以 fail closed」收斂成同一個 true，verdict 已經丟失。
        // 要分辨得由有能力做輕量查詢的 reader（App 端 AXFieldReader）覆寫本方法自行回報。
        if context.isSecure { return .secure }
        guard let sessionIdentity, let current = context.fieldIdentity else { return .unknown }
        return current == sessionIdentity ? .same : .different(currentAppBundleID: context.frontAppBundleID)
    }
}

public enum RangeReplaceResult: Equatable, Sendable {
    case replaced      // 校驗通過且已替換（verify-only 時＝驗證通過）
    case mismatch      // 欄位現值與預期不符（外力改動），或聚焦元素不是 session 起始那個：呼叫端不得再改字
    case unsupported   // 該 App 不支援 AX 讀寫：呼叫端 fail closed，**沒有** keystroke 退路（issue #44）
}

/// AX 範圍操作。location 與 expected 的長度一律以 **UTF-16 單位**計（AX 慣例）；
/// FieldContext.caretLocation 亦同——這些數值只在 AX 路徑內流動，不與 grapheme 計數混用。
///
/// 每個操作都帶 session 起始欄位的 `fieldIdentity`（issue #43／#44）：實作必須先確認**現在聚焦的元素**
/// 就是那個 identity（CFEqual），不是才回 `.mismatch`——同 App 內的焦點切換（Tab、maxlength 自動跳格）
/// 不會觸發使用者活動偵測，offset＋文字剛好相同的另一個欄位只有 identity 抓得到。
public protocol SessionRangeReplacing: AnyObject {
    /// 只驗證不動手：.replaced＝identity 與文字都通過。
    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult
    /// 替換後把游標收到新文字尾端（維持「session 即尾端、游標相對」的前提）。
    /// 被替換的那段就是尾端時用這個。
    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int, expected: String,
                              with newText: String) -> RangeReplaceResult
    /// 同上，但替換後把游標放回「同一個相對位置」（見 `caretAfterReplacement`）。
    /// session **中段**回溯改寫專用：後面還接著別的文字，游標若被收到被替換段落的尾端，
    /// 後續串流插入會落在句子中間、直接毀文。
    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int, expected: String,
                                             with newText: String) -> RangeReplaceResult
}
