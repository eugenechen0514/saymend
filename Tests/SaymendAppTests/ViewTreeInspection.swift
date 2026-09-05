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
