import AppKit

/// 系統剪貼簿的操作子集 seam（issue #41 起）。抽成 protocol 只為了一件事：
/// 讓測試能模擬 `setString` 回 false——真 NSPasteboard 沒辦法被叫失敗，也不能子類化（`pasteboardWithName:` 回的是快取實例）。
/// 方法簽章與 NSPasteboard 完全相同，故 conform 是空實作。
protocol SystemPasteboard: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: SystemPasteboard {}
