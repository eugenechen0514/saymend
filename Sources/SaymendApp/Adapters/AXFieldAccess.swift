import AppKit
import ApplicationServices
import SaymendCore

/// AX 聚焦欄位存取（規格 §4.6 AXInserter／§4.7 AXReader 的 M2 子集；§5.3 secure field 偵測）。
/// 與熱鍵共用「輔助使用」權限；range 一律 UTF-16 單位（AX 慣例）。
enum AXFieldAccess {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else { return nil }
        return valueRef as? String
    }

    /// 游標／選取前後的窗口文字（UTF-16 計數，規格 §3.6「無選取時游標前後窗口」與 §4.7 AXReader）。
    /// 邊界落在 surrogate pair 中間時向內讓開，絕不產生半個字。純函式，供單元測試。
    static func contextWindows(value: String, selectionLocation: Int, selectionLength: Int,
                               window: Int) -> (before: String, after: String) {
        let units = Array(value.utf16)
        let loc = min(max(0, selectionLocation), units.count)
        let end = min(max(loc, selectionLocation + max(0, selectionLength)), units.count)
        let before = utf16Slice(units, max(0, loc - window)..<loc)
        let after = utf16Slice(units, end..<min(units.count, end + window))
        return (before, after)
    }

    /// UTF-16 區段轉字串；起訖若切在 surrogate pair 中間就向內收（trail 開頭前移、lead 結尾回退）。
    private static func utf16Slice(_ units: [UInt16], _ range: Range<Int>) -> String {
        var lower = range.lowerBound
        var upper = range.upperBound
        if lower < units.count, UTF16.isTrailSurrogate(units[lower]) { lower += 1 }
        if upper > lower, upper - 1 < units.count, UTF16.isLeadSurrogate(units[upper - 1]) { upper -= 1 }
        guard lower < upper else { return "" }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// 單一範圍的螢幕外接矩形（kAXBoundsForRangeParameterizedAttribute，CG 座標原點左上）。
    static func boundsForRange(element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var rectRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element, kAXBoundsForRangeParameterizedAttribute as CFString,
                  rangeValue, &rectRef) == .success,
              let rectValue = rectRef, CFGetTypeID(rectValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(rectValue as! AXValue, .cgRect, &rect),
              rect.width.isFinite, rect.height.isFinite, !rect.isNull,
              rect.height > 0 else { return nil }        // 零高＝App 回了假值，寧可不畫
        return rect
    }

    /// index 所在行號（kAXLineForIndexParameterizedAttribute）
    private static func lineForIndex(element: AXUIElement, index: Int) -> Int? {
        var idx = index
        guard let param = CFNumberCreate(kCFAllocatorDefault, .intType, &idx) else { return nil }
        var lineRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element, kAXLineForIndexParameterizedAttribute as CFString,
                  param, &lineRef) == .success,
              let number = lineRef as? Int else { return nil }
        return number
    }

    /// 行號的 UTF-16 範圍（kAXRangeForLineParameterizedAttribute）
    private static func rangeForLine(element: AXUIElement, line: Int) -> CFRange? {
        var l = line
        guard let param = CFNumberCreate(kCFAllocatorDefault, .intType, &l) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element, kAXRangeForLineParameterizedAttribute as CFString,
                  param, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// 範圍的逐行矩形（規格 §3.5：多行 span 逐行查詢逐行畫）。
    /// 鐵律：任何一步失敗、迴圈不前進、超過 maxLines 沒畫完 → 回 nil，呼叫端立刻隱藏／降級。
    /// 單行欄位（不支援行查詢）退化為整段一顆矩形。
    static func lineRects(element: AXUIElement, location: Int, utf16Length: Int,
                          maxLines: Int = 40) -> [CGRect]? {
        guard utf16Length > 0 else { return [] }
        let end = location + utf16Length
        // 行查詢不可用（如 NSTextField 單行欄位）：整段一顆
        guard lineForIndex(element: element, index: location) != nil else {
            return boundsForRange(element: element, location: location, length: utf16Length).map { [$0] }
        }
        var rects: [CGRect] = []
        var cursor = location
        var lines = 0
        while cursor < end {
            guard lines < maxLines,
                  let line = lineForIndex(element: element, index: cursor),
                  let lineRange = rangeForLine(element: element, line: line) else { return nil }
            let lineEnd = lineRange.location + lineRange.length
            let subEnd = min(end, lineEnd)
            guard subEnd > cursor else { return nil }    // 不前進＝App 回了矛盾值，放棄
            guard let rect = boundsForRange(element: element, location: cursor, length: subEnd - cursor) else {
                return nil
            }
            rects.append(rect)
            cursor = subEnd
            lines += 1
        }
        return rects
    }

    /// 聚焦元素的螢幕外接框（CG 座標原點左上）。AX 讀不到 value 的元素（canvas/Electron）
    /// 常仍可讀 position/size——OCR 備援（規格 §4.7）靠這個框決定截圖區域。
    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &point),
              AXValueGetValue(sv as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// 密碼欄位（§5.3）subrole 判定的三態結果。
    /// 舊寫法把「問不出來」與「問到了、不是密碼欄」壓成同一個布林，於是 AX 逾時會 fail open；
    /// 而 `isSecure` 是規格 §5.3 的總閘門（不錄音、不送 LLM、不寫歷史、不開 session），
    /// 誤判成 false 的代價是把使用者唸出的密碼送上雲端 provider 並寫進歷史 DB。
    /// issue #37 把 AX 訊息 timeout 收到 0.2 秒之後，這條路徑才真的打得到，故必須分辨。
    enum SecureVerdict: Equatable {
        case secure          // 問到了，subrole 就是密碼欄
        case notSecure       // 問到了、不是密碼欄；或元素本來就沒有 subrole 這個屬性
        case unknown         // 查詢沒完成（對方 busy／無回應）——這不是答案
    }

    /// `AXError.cannotComplete` 的 header 定義正是「messaging failed in some way or because the
    /// application with which the function is communicating is busy or unresponsive」，也就是逾時，
    /// 只有它算 `unknown`。其餘錯誤（attributeUnsupported／noValue／notImplemented…）維持既有寬鬆行為：
    /// 那些是「問到了，元素沒有這個屬性」，大量非 AX-rich 欄位本來就落在這裡，
    /// 一律 fail closed 會讓聽寫在這些 App 內整個失效（issue #21 的既有契約）。
    static func secureVerdict(error: AXError, subrole: String?) -> SecureVerdict {
        switch error {
        case .success:
            return subrole == (kAXSecureTextFieldSubrole as String) ? .secure : .notSecure
        case .cannotComplete:
            return .unknown
        default:
            return .notSecure
        }
    }

    /// 讀 kAXSubroleAttribute，把 `AXError` 與（成功時的）subrole 一起交出去——
    /// 呼叫端要靠 error 分辨逾時，不能只看有沒有拿到字串。
    static func readSubrole(of element: AXUIElement) -> (AXError, String?) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref)
        return (error, ref as? String)
    }
}

/// Session-bound AX element registry（issue #43）。FieldIdentity 是 opaque token；真正的 identity 以 **CFEqual**
/// 比較保留的 AXUIElement——不能用 CFHash（hash collision 會把同 App 的另一欄誤認為原欄），也不能用 Swift `===`
/// （同一元素每次 `AXUIElementCopyAttributeValue` 回的是新 wrapper）。
/// AXFieldReader 與 FeedbackCoordinator 共用同一個實例，兩邊對同一元素拿到同一個 token；引用計數見 FieldIdentityRegistry。
final class AXFieldRegistry {
    private let registry = FieldIdentityRegistry<AXUIElement>(areEqual: { CFEqual($0, $1) })

    func identity(for element: AXUIElement) -> FieldIdentity { registry.identity(for: element) }
    func matches(_ identity: FieldIdentity, element: AXUIElement) -> Bool { registry.matches(identity, element: element) }
    func element(for identity: FieldIdentity) -> AXUIElement? { registry.element(for: identity) }
    func release(_ identity: FieldIdentity?) { registry.release(identity) }
    /// 仍有持有者的 entry 數。用來釘住「閘門不得替焦點元素多留持有者」這條 lease 不變式（issue #43／#37）。
    var entryCount: Int { registry.count }
}

/// 聚焦欄位快照：secure 偵測＋游標錨位（UTF-16）＋元素 identity token
final class AXFieldReader: FieldContextProviding {
    private let profiles: (any AppProfileStore)?
    private let registry: AXFieldRegistry
    private let clipboardFallback = ClipboardSelectionReader()
    /// subrole 讀取可注入只為了讓 secure 三態判定（含逾時重試）有單元測試；production 用預設值。
    private let readSubrole: (AXUIElement) -> (AXError, String?)
    /// `focusedElement` 可注入只為了讓 `fieldGate` 這道閘門有單元測試（比照 AXInserter）；production 用預設值。
    private let focusedElement: () -> AXUIElement?

    init(profiles: (any AppProfileStore)? = nil, registry: AXFieldRegistry,
         readSubrole: @escaping (AXUIElement) -> (AXError, String?) = AXFieldAccess.readSubrole,
         focusedElement: @escaping () -> AXUIElement? = { AXFieldAccess.focusedElement() }) {
        self.profiles = profiles
        self.registry = registry
        self.readSubrole = readSubrole
        self.focusedElement = focusedElement
    }

    func snapshot() -> FieldContext {
        guard let element = focusedElement() else { return FieldContext() }
        return snapshot(of: element)
    }

    /// 每次呼叫都會替 `element` 登記一個持有者（issue #43）：呼叫端要嘛把 `fieldIdentity` 交給 ledger、
    /// 要嘛立即 `releaseFieldIdentity`——否則計數歸不了零，同一元素在新 session 會拿到舊 token。
    /// 密碼欄位不登記：controller 對它不會 begin，登記了就沒人歸還。
    func snapshot(of element: AXUIElement) -> FieldContext {
        var context = FieldContext(hasFocusedElement: true)
        if isSecureField(element) {
            context.isSecure = true
            return context
        }
        context.fieldIdentity = registry.identity(for: element)
        // 前景 App 欄位在 secure 短路之後填（密碼欄位快照維持最小資訊，規格 §4.7 FrontAppInfo）
        context.frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        context.frontAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                context.caretLocation = range.location
                if range.length > 0 {
                    context.selectedRange = .init(location: range.location, length: range.length)
                    var selRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
                       let sel = selRef as? String, !sel.isEmpty {
                        context.selectedText = sel
                    } else if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                              profiles?.profile(for: bundle).cmdCSelectionFallback == true {
                        // 白名單備援（M4 設計裁決 6）：AX 有 range 沒文字（部分 Electron），
                        // 以 Cmd+C 抓選取。仍讀不到＝維持 hasSelection false（一般聽寫）。
                        context.selectedText = clipboardFallback.readSelection()
                    }
                    // 讀到 range 卻讀不到文字＝hasSelection 為 false，自然退回一般聽寫（Task 1 裁決）
                }
                // 前後文窗口（LLM 語境用；讀不到全文就不給，寧缺勿錯）
                if let value = AXFieldAccess.stringValue(of: element) {
                    let w = AXFieldAccess.contextWindows(value: value,
                                                         selectionLocation: range.location,
                                                         selectionLength: range.length,
                                                         window: 240)
                    context.contextBefore = w.before.isEmpty ? nil : w.before
                    context.contextAfter = w.after.isEmpty ? nil : w.after
                }
            }
        }
        return context
    }

    /// §5.3 密碼欄位閘門：三態判定 ＋ 逾時重試一次。
    /// 回 true 代表「是密碼欄」**或**「問不出來」——兩者都必須擋。逾時重試一次是 header 對
    /// `cannotComplete` 的建議做法（"your assistive application can try to call this function again"）；
    /// 重試仍是 unknown 就 fail closed：寧可少一次聽寫，不可在密碼欄裡開 session。
    private func isSecureField(_ element: AXUIElement) -> Bool {
        let first = readSubrole(element)
        var verdict = AXFieldAccess.secureVerdict(error: first.0, subrole: first.1)
        if verdict == .unknown {
            let retry = readSubrole(element)
            verdict = AXFieldAccess.secureVerdict(error: retry.0, subrole: retry.1)
        }
        return verdict != .notSecure
    }

    func releaseFieldIdentity(_ identity: FieldIdentity?) {
        registry.release(identity)
    }

    /// 輕量焦點閘門（issue #37）：只讀「焦點元素」＋「subrole」兩次 AX 屬性，取代原本每句一次的完整
    /// `snapshot(of:)`（subrole／selectedTextRange／selectedText／整份 kAXValue，4–5 次跨行程 IPC，
    /// 而且在有選取＋白名單 App 時還會對目前焦點發一個合成 Cmd+C）。
    ///
    /// **只用 `registry.matches`，絕不呼叫 `identity(for:)`**：後者會多發一個持有者，
    /// 破壞 #43 的 lease 不變式（session 起始那個 token 就再也死不掉）。
    /// 密碼欄位一樣不登記 identity，比照 `snapshot(of:)` 的既有紀律。
    ///
    /// secure 判定與 `snapshot(of:)` **共用同一個 `isSecureField`**（issue #59 的三態＋逾時重試一次＋
    /// 仍問不出來就 fail closed）。兩處各寫一份的話會漂移，而漂移的後果是「開始聽寫時擋得住、
    /// 聽寫途中切進去擋不住」——規格 §5.3 破在中途路徑上。
    func fieldGate(sessionIdentity: FieldIdentity?) -> FieldGate {
        guard let element = focusedElement() else { return .unknown }
        if isSecureField(element) { return .secure }
        guard let sessionIdentity else { return .unknown }
        return registry.matches(sessionIdentity, element: element)
            ? .same
            : .different(currentAppBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}

/// AX 範圍替換：identity 校驗 → 讀值校驗 → 設 AXSelectedTextRange → 設 AXSelectedText。
/// identity 校驗（issue #43／#44）：現在聚焦的元素必須 CFEqual 於 session 起始登記的那個，否則 `.mismatch`——
/// 這是「會刪字的操作一律需要 verified AX」四項檢查裡，唯一能抓到同 App 內焦點切換的一項。
/// `focusedElement` 可注入只為了讓這道閘門有單元測試；production 用預設值。
final class AXInserter: SessionRangeReplacing {
    private let registry: AXFieldRegistry
    private let focusedElement: () -> AXUIElement?

    init(registry: AXFieldRegistry,
         focusedElement: @escaping () -> AXUIElement? = { AXFieldAccess.focusedElement() }) {
        self.registry = registry
        self.focusedElement = focusedElement
    }

    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult {
        guard let element = focusedElement() else { return .unsupported }
        guard registry.matches(fieldIdentity, element: element) else { return .mismatch }
        guard let value = AXFieldAccess.stringValue(of: element) else { return .unsupported }
        return Self.rangeMatches(value: value, location: location, expected: expected)
    }

    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int, expected: String,
                              with newText: String) -> RangeReplaceResult {
        replace(fieldIdentity: fieldIdentity, location: location, expected: expected,
                with: newText, caret: .collapseToNewEnd)
    }

    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int, expected: String,
                                             with newText: String) -> RangeReplaceResult {
        replace(fieldIdentity: fieldIdentity, location: location, expected: expected,
                with: newText, caret: .preserve)
    }

    /// 替換後游標怎麼放。兩種模式共用同一套「讀值校驗→設範圍→設文字」，
    /// 差別只在最後一步——分開寫兩份實作遲早會漂移。
    private enum CaretPolicy {
        case collapseToNewEnd   // 被替換的就是尾端：收到新文字尾端
        case preserve           // 中段改寫：把原游標放回同一個相對位置
    }

    private func replace(fieldIdentity: FieldIdentity, location: Int, expected: String,
                         with newText: String, caret policy: CaretPolicy) -> RangeReplaceResult {
        guard let element = focusedElement() else { return .unsupported }
        guard registry.matches(fieldIdentity, element: element) else { return .mismatch }
        guard let value = AXFieldAccess.stringValue(of: element) else { return .unsupported }
        let check = Self.rangeMatches(value: value, location: location, expected: expected)
        guard check == .replaced else { return check }

        // 必須在設 AXSelectedTextRange 之前讀——那個設值本身就會覆蓋掉游標位置。
        // preserve 讀不到原游標時 **在動任何一個字之前就放棄**：此時唯一的替代是 collapse，
        // 而 collapse 會把游標留在被替換段落的尾端，也就是後續文字的正前方——那正是這條
        // 路徑存在的目的所要防的事（下一個串流插入會落進句子中間）。寧可不潤飾，
        // 也不要留下「文字對了但游標在錯的地方」的狀態；呼叫端會保留原文並說明原因。
        let caretBefore: Int?
        switch policy {
        case .collapseToNewEnd:
            caretBefore = nil
        case .preserve:
            guard let current = Self.caretLocation(of: element) else { return .unsupported }
            caretBefore = current
        }

        var range = CFRange(location: location, length: expected.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .unsupported }   // 行程內轉換，沒送出任何訊息
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            // 與下一條分支對稱：非 .success **不等於**選取沒被設上。AX 是同步 Mach RPC，
            // `cannotComplete` 只代表我方不等了（header：「This does not necessarily mean that the
            // function has failed」），慢但活著的 App 之後仍會把選取套上去。呼叫端此時會把
            // `.unsupported` 轉成 `.fieldMismatch` 並凍結 session，我們不會再寫——欄位裡卻留著一段
            // 活的選取（Esc 退回時那正是整段 session 文字），使用者下一鍵就會整段蓋掉。
            // 同一個 Mach port 上訊息保序，補一次 collapse 會蓋掉遲到的選取；若設範圍是真的失敗，
            // 這次 setCaret 也只是一次注定失敗、無副作用的呼叫。
            Self.setCaret(element, to: location + expected.utf16.count)
            return .unsupported
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef) == .success else {
            // 選取已設但替換失敗：把游標收回範圍尾端，避免使用者下一鍵蓋掉選取
            Self.setCaret(element, to: location + expected.utf16.count)
            return .unsupported
        }
        // 游標釘定（M3 設計裁決 2）：部分 App 替換後把整段新文字留成選取狀態，
        // 後續串流鍵入會把剛替換的字吃掉，故一律顯式 collapse。失敗不影響替換結果。
        // collapseToNewEnd＝新文字尾端，讓「session 即尾端（游標相對）」恢復成立，M2 修正機械得以重用。
        // preserve＝依 caretAfterReplacement 平移（caretBefore 在上面已保證非 nil）。
        let target = caretBefore.map {
            caretAfterReplacement(current: $0, location: location,
                                  oldLength: expected.utf16.count, newLength: newText.utf16.count)
        } ?? (location + newText.utf16.count)
        Self.setCaret(element, to: target)
        return .replaced
    }

    private static func caretLocation(of element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private static func setCaret(_ element: AXUIElement, to location: Int) {
        var caret = CFRange(location: location, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
    }

    /// value 的 [location, location+expected.utf16.count) 是否等於 expected
    private static func rangeMatches(value: String, location: Int, expected: String) -> RangeReplaceResult {
        let utf16 = Array(value.utf16)
        let expectedUnits = Array(expected.utf16)
        guard location >= 0, location + expectedUnits.count <= utf16.count else { return .mismatch }
        return Array(utf16[location..<(location + expectedUnits.count)]) == expectedUnits ? .replaced : .mismatch
    }
}
