import SwiftUI

/// SwiftUI view tree 的反射檢視（測試專用）。
/// 不只找 opaque tree 裡的任意 String：該字串必須位在真正的 `Text` storage，
/// 且祖先不能有 SwiftUI `_HiddenModifier`。這個 seam 精確守 `.id(text)` 與 `.hidden()`，
/// 不宣稱取代 screenshot test 判斷 opacity、遮擋等一般像素可見性。
enum ViewTreeInspection {
    /// 未被 `.hidden()` 遮住的 `Text` 內容字串。
    static func unhiddenTextStrings(in value: Any,
                                    hiddenByAncestor: Bool = false,
                                    depth: Int = 0) -> [String] {
        // GeneralSettingsTab.body 的完整樹很深（Form → Section → 條件式 → onChange 鏈），40 層不夠
        guard depth < 120 else { return [] }
        let mirror = Mirror(reflecting: value)
        let hidden = hiddenByAncestor || isDirectlyHidden(mirror)
        if value is Text { return hidden ? [] : embeddedStrings(in: value) }
        return mirror.children.flatMap {
            unhiddenTextStrings(in: $0.value, hiddenByAncestor: hidden, depth: depth + 1)
        }
    }

    /// 樹裡是否存在**未被 hidden 的**某型別（以 `String(reflecting:)` 全名比對）。
    static func containsUnhiddenType(named expected: String,
                                     in value: Any,
                                     hiddenByAncestor: Bool = false,
                                     depth: Int = 0) -> Bool {
        guard depth < 120 else { return false }
        let mirror = Mirror(reflecting: value)
        let hidden = hiddenByAncestor || isDirectlyHidden(mirror)
        if String(reflecting: Swift.type(of: value)) == expected { return !hidden }
        return mirror.children.contains {
            containsUnhiddenType(named: expected, in: $0.value, hiddenByAncestor: hidden, depth: depth + 1)
        }
    }

    /// 樹裡第一顆 `Button<Text>` 的 action closure——用來真的按下去（issue #42：分支邏輯要被測試鎖住）。
    /// SwiftUI 把它存成 `ButtonAction { closure: @MainActor () -> () }`。
    /// alert 的 `actions:` closure 內的按鈕不在這棵樹裡（尚未被求值），拿不到是預期的。
    static func firstButtonAction(in value: Any, depth: Int = 0) -> (@MainActor () -> Void)? {
        guard depth < 120 else { return nil }
        if value is Button<Text> {
            guard let action = Mirror(reflecting: value).children.first(where: { $0.label == "action" })?.value
            else { return nil }
            return Mirror(reflecting: action).children
                .compactMap { $0.value as? @MainActor () -> Void }
                .first
        }
        for child in Mirror(reflecting: value).children {
            if let action = firstButtonAction(in: child.value, depth: depth + 1) { return action }
        }
        return nil
    }

    private static func isDirectlyHidden(_ mirror: Mirror) -> Bool {
        mirror.children.contains {
            $0.label == "modifier"
                && String(reflecting: Swift.type(of: $0.value)) == "SwiftUI._HiddenModifier"
        }
    }

    private static func embeddedStrings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap {
            embeddedStrings(in: $0.value, depth: depth + 1)
        }
    }
}
