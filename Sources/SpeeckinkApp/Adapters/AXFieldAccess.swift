import ApplicationServices
import SpeeckinkCore

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
}

/// 聚焦欄位快照：secure 偵測＋游標錨位（UTF-16）
final class AXFieldReader: FieldContextProviding {
    func snapshot() -> FieldContext {
        guard let element = AXFieldAccess.focusedElement() else { return FieldContext() }
        var context = FieldContext(hasFocusedElement: true)
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            context.isSecure = true
            return context
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                context.caretLocation = range.location
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
        guard let element = AXFieldAccess.focusedElement(),
              let value = AXFieldAccess.stringValue(of: element) else {
            return .unsupported
        }
        let check = Self.rangeMatches(value: value, location: location, expected: expected)
        guard check == .replaced else { return check }

        var range = CFRange(location: location, length: expected.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return .unsupported
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef) == .success else {
            // 選取已設但替換失敗：把游標收回範圍尾端，避免使用者下一鍵蓋掉選取
            var caret = CFRange(location: location + expected.utf16.count, length: 0)
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
            }
            return .unsupported
        }
        return .replaced
    }

    /// value 的 [location, location+expected.utf16.count) 是否等於 expected
    private static func rangeMatches(value: String, location: Int, expected: String) -> RangeReplaceResult {
        let utf16 = Array(value.utf16)
        let expectedUnits = Array(expected.utf16)
        guard location >= 0, location + expectedUnits.count <= utf16.count else { return .mismatch }
        return Array(utf16[location..<(location + expectedUnits.count)]) == expectedUnits ? .replaced : .mismatch
    }
}
