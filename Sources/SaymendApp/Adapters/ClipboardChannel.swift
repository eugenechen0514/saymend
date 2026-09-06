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

    /// 暫時寫入結束時要放回去的東西：使用者的內容，或被暫時擠開的救援文字。
    private enum RestoreTarget {
        case user(Items)
        case rescue(String)
    }

    private struct Lease {
        let id: Int
        /// 本 lease 寫完當下的 changeCount：收尾時不相等＝別人（使用者、目標 App）動過，不寫回。
        let writeChangeCount: Int
        /// 安全窗終點：在此之前假設目標 App 還沒讀走，任何新寫入都得等到它過去。
        let deadline: TimeInterval
        let target: RestoreTarget
    }

    private let pasteboard: any SystemPasteboard
    private let settleDelay: TimeInterval
    private let timer: any ClipboardTimer
    private var activeLease: Lease?
    private var nextLeaseID = 0
    /// 最後一次落地的救援與當時的 changeCount：相等＝剪貼簿仍是它；不等＝使用者已覆寫、往前走了。
    private var landedRescue: (text: String, changeCount: Int)?

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
        let target = snapshotTarget()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(target)
            throw InserterError.postFailed
        }
        nextLeaseID += 1
        let lease = Lease(id: nextLeaseID, writeChangeCount: pasteboard.changeCount,
                          deadline: timer.now + settleDelay, target: target)
        activeLease = lease
        do {
            try body()
        } catch {
            // 事件沒送成：依 TextInserter 原子契約同步還原，錯誤原樣往外拋（呼叫端退到 keystroke 通道）
            activeLease = nil
            restore(target)
            throw error
        }
        timer.schedule(after: settleDelay) { [weak self] in self?.finish(lease) }
    }

    /// 暫時清空並讀取（Cmd+C 選取備援）：保存 → clear → body（送 Cmd+C、等待目標 App 寫入）→ 讀回 → 同步還原。
    /// 目標 App 的寫入是預期中的 foreign write，收尾照樣還原；沒有 300ms 排程（整段同步）。
    func withTransientRead(_ body: () -> Void) -> String? {
        settle()
        let target = snapshotTarget()
        pasteboard.clearContents()
        nextLeaseID += 1
        let lease = Lease(id: nextLeaseID, writeChangeCount: pasteboard.changeCount,
                          deadline: timer.now, target: target)
        activeLease = lease
        body()
        let text = pasteboard.string(forType: .string)
        finish(lease, allowingForeignWrite: true)
        return text
    }

    /// 救援（失敗路徑的最後手段）：立即落地，**不保存使用者原本的內容**——單一 slot、R 必須佔住，
    /// 而且沒有任何訊號能告訴我們 R 已被取回（Cmd+V 不改 changeCount），U 沒有合法的自動還原時機。
    /// 落地後只有使用者自己的寫入會取代它：後續 paste 只把它暫時擠開、收尾放回。
    func rescue(_ text: String) {
        settle()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            landedRescue = nil                      // 沒寫成就不能宣稱它在剪貼簿裡
            return
        }
        landedRescue = (text, pasteboard.changeCount)
    }

    /// 使用者主動複製（History 分頁）：覆寫並清除救援紀錄——呼叫端在此之前已用 `rescueStillInClipboard` 提示過。
    func copyForUser(_ text: String) {
        settle()
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        landedRescue = nil
    }

    /// 自救援落地後剪貼簿沒被任何人覆寫 → 該救援文字；否則 nil。
    /// **不知道使用者貼過沒有**（讀取不改 changeCount）——文案只能說「還在剪貼簿」，不能說「還沒取回」。
    var rescueStillInClipboard: String? {
        guard let rescue = landedRescue, rescue.changeCount == pasteboard.changeCount else { return nil }
        return rescue.text
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

    /// 收尾：只有仍是最新 lease（被 settle 內聯收尾過的排程 block 是 no-op）、且剪貼簿仍是它寫的內容時才寫回；
    /// `allowingForeignWrite` 給 Cmd+C 讀取用——目標 App 寫入是預期中的事。
    private func finish(_ lease: Lease, allowingForeignWrite: Bool = false) {
        guard lease.id == activeLease?.id else { return }
        activeLease = nil
        guard allowingForeignWrite || pasteboard.changeCount == lease.writeChangeCount else { return }
        restore(lease.target)
    }

    /// 暫時寫入前決定收尾要放回什麼：剪貼簿此刻是救援文字就放回它；否則保存使用者內容
    /// （曾落地的救援若已被使用者覆寫，紀錄一併清掉）。
    private func snapshotTarget() -> RestoreTarget {
        if let rescue = landedRescue, rescue.changeCount == pasteboard.changeCount {
            return .rescue(rescue.text)
        }
        landedRescue = nil
        return .user(snapshotItems())
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

    private func restore(_ target: RestoreTarget) {
        switch target {
        case .user(let items):
            restoreItems(items)
            landedRescue = nil
        case .rescue(let text):
            pasteboard.clearContents()
            landedRescue = pasteboard.setString(text, forType: .string) ? (text, pasteboard.changeCount) : nil
        }
    }

    private func restoreItems(_ items: Items) {
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
