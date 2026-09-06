import AppKit
import SaymendCore

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

/// 剪貼簿計時 seam（issue #42）：排程延遲收尾、同步等待、讀時鐘。
/// 抽出來只為了讓 300ms 安全窗的交錯能在測試裡確定性重現。
protocol ClipboardTimer: AnyObject {
    var now: TimeInterval { get }
    /// 主佇列延遲執行（真實實作＝`DispatchQueue.main.asyncAfter`）。
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void)
    /// 同步阻塞目前執行緒。
    func wait(_ seconds: TimeInterval)
}

final class MainQueueClipboardTimer: ClipboardTimer {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }
    func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

/// 剪貼簿的唯一寫入口（issue #42）：paste 的暫時寫入、Cmd+C 備援的暫時清空、失敗路徑的救援、History 分頁的複製
/// 全部經過這裡，彼此才知道對方存在。舊版四個出口各自 clear＋setString、各自排 300ms 還原，互相覆蓋——
/// paste 的延遲還原會把救援內容洗掉，連續兩次 paste 會把使用者原本的剪貼簿洗成我方文字。
///
/// 規則只有一條所有權：`activeLease` 是唯一在途的暫時寫入；收尾（`finish`）只在剪貼簿仍是它寫的內容時才寫回。
/// **只在 main thread 使用**，不加鎖。
final class ClipboardChannel {
    static let general = ClipboardChannel(pasteboard: NSPasteboard.general)

    typealias Items = [[NSPasteboard.PasteboardType: Data]]

    private struct Lease {
        let id: Int
        /// 本 lease 寫完當下的 changeCount：收尾時不相等＝別人（使用者、目標 App）動過，不寫回。
        let writeChangeCount: Int
        /// 安全窗終點：在此之前假設目標 App 還沒讀走，任何新寫入都得等到它過去。
        let deadline: TimeInterval
        let target: Items
    }

    private let pasteboard: any SystemPasteboard
    private let settleDelay: TimeInterval
    private let timer: any ClipboardTimer
    private var activeLease: Lease?
    private var nextLeaseID = 0

    init(pasteboard: any SystemPasteboard, settleDelay: TimeInterval = 0.3,
         timer: any ClipboardTimer = MainQueueClipboardTimer()) {
        self.pasteboard = pasteboard
        self.settleDelay = settleDelay
        self.timer = timer
    }

    /// 暫時寫入（paste）：保存 → clear → setString → body（送 Cmd+V）→ 安全窗後收尾還原。
    /// setString 失敗（#41）：剪貼簿此刻已被清空，**同步**還原、拋 `postFailed`、body 不執行、不排程。
    func withTransientWrite(_ text: String, _ body: () throws -> Void) throws {
        settle()
        let target = snapshotItems()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(target)
            throw InserterError.postFailed
        }
        nextLeaseID += 1
        let lease = Lease(id: nextLeaseID, writeChangeCount: pasteboard.changeCount,
                          deadline: timer.now + settleDelay, target: target)
        activeLease = lease
        try body()
        timer.schedule(after: settleDelay) { [weak self] in self?.finish(lease) }
    }

    // MARK: - 內部

    /// 任何新的剪貼簿動作之前：若有 paste 在途，等它的安全窗走完並收尾——新寫入才不會在目標 App 讀走前把它蓋掉，
    /// 第二次保存到的也才是使用者的內容而不是我方上一次寫的文字（issue #42 ②-b）。
    /// 同步阻塞 main thread 最多 settleDelay，只在「上一個 paste 的 300ms 內又有出口動作」時發生。
    /// 使用者已在窗內寫過別的東西時等也救不回在途 paste，直接收尾（收尾會因 changeCount 不符而不寫回）。
    private func settle() {
        guard let lease = activeLease else { return }
        if pasteboard.changeCount == lease.writeChangeCount {
            let remaining = lease.deadline - timer.now
            if remaining > 0 { timer.wait(remaining) }
        }
        finish(lease)
    }

    /// 收尾：只有仍是最新 lease、且剪貼簿仍是它寫的內容時才寫回。
    private func finish(_ lease: Lease) {
        guard lease.id == activeLease?.id else { return }
        activeLease = nil
        guard pasteboard.changeCount == lease.writeChangeCount else { return }
        restore(lease.target)
    }

    /// 逐 item 逐 type 複製 data（沿用 PasteInserter／ClipboardSelectionReader 既有做法）。
    private func snapshotItems() -> Items {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private func restore(_ items: Items) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let objects: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(objects)
    }
}
