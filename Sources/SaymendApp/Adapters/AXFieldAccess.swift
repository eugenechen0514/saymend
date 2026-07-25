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
}

/// 聚焦欄位快照：secure 偵測＋游標錨位（UTF-16）
final class AXFieldReader: FieldContextProviding {
    private let profiles: (any AppProfileStore)?
    private let clipboardFallback = ClipboardSelectionReader()

    init(profiles: (any AppProfileStore)? = nil) {
        self.profiles = profiles
    }

    func snapshot() -> FieldContext {
        guard let element = AXFieldAccess.focusedElement() else { return FieldContext() }
        var context = FieldContext(hasFocusedElement: true)
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            context.isSecure = true
            return context
        }
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
}

/// AX 範圍替換：讀值校驗 → 設 AXSelectedTextRange → 設 AXSelectedText。
final class AXInserter: SessionRangeReplacing {
    func verifyRange(location: Int, expected: String) -> RangeReplaceResult {
        guard let element = AXFieldAccess.focusedElement(),
              let value = AXFieldAccess.stringValue(of: element) else {
            return .unsupported
        }
        return Self.rangeMatches(value: value, location: location, expected: expected)
    }

    func replaceVerifiedRange(location: Int, expected: String, with newText: String) -> RangeReplaceResult {
        replace(location: location, expected: expected, with: newText, caret: .collapseToNewEnd)
    }

    func replaceVerifiedRangePreservingCaret(location: Int, expected: String,
                                             with newText: String) -> RangeReplaceResult {
        replace(location: location, expected: expected, with: newText, caret: .preserve)
    }

    /// 替換後游標怎麼放。兩種模式共用同一套「讀值校驗→設範圍→設文字」，
    /// 差別只在最後一步——分開寫兩份實作遲早會漂移。
    private enum CaretPolicy {
        case collapseToNewEnd   // 被替換的就是尾端：收到新文字尾端
        case preserve           // 中段改寫：把原游標放回同一個相對位置
    }

    private func replace(location: Int, expected: String, with newText: String,
                         caret policy: CaretPolicy) -> RangeReplaceResult {
        guard let element = AXFieldAccess.focusedElement(),
              let value = AXFieldAccess.stringValue(of: element) else {
            return .unsupported
        }
        let check = Self.rangeMatches(value: value, location: location, expected: expected)
        guard check == .replaced else { return check }

        // 必須在設 AXSelectedTextRange 之前讀——那個設值本身就會覆蓋掉游標位置
        let caretBefore: Int? = policy == .preserve ? Self.caretLocation(of: element) : nil

        var range = CFRange(location: location, length: expected.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
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
        // preserve＝依 caretAfterReplacement 平移；讀不到原游標就退回 collapse，不因此讓替換失敗。
        let target: Int
        switch policy {
        case .collapseToNewEnd:
            target = location + newText.utf16.count
        case .preserve:
            target = caretBefore.map {
                caretAfterReplacement(current: $0, location: location,
                                      oldLength: expected.utf16.count, newLength: newText.utf16.count)
            } ?? (location + newText.utf16.count)
        }
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
