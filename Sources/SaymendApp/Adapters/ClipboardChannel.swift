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
    /// 不用 `Thread.sleep`：那會把 HotkeyMonitor 的 event tap 一起卡住，連我們自己剛送的合成 Cmd+V 都送不到目標 App。
    func wait(_ seconds: TimeInterval) { EventTapFriendlyWait.wait(seconds) }
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

    /// 救援（失敗路徑的最後手段）：立即落地，**不保存使用者原本的內容**——R 必須佔住，
    /// 而且沒有任何訊號能告訴我們 R 已被取回（Cmd+V 不改 changeCount），U 沒有合法的自動還原時機。
    /// 落地後只有使用者自己的寫入會取代它：後續 paste 只把它暫時擠開、收尾放回。
    ///
    /// 同一輪累積（修訂 issue #42 取捨 4 的單一 slot、後者取代前者）：剪貼簿此刻仍是我方上一份救援時，
    /// 新片段**直接串接在後面、不加分隔符**——這些片段本來就會依序落進同一個欄位形成連續文字。
    /// 使用者一貼過或複製過別的東西 changeCount 就前進，`rescueStillInClipboard` 變 nil，下一次自然重新開始一輪；
    /// 這條規則因此不需要任何 session 訊號。`settle()` 之後才讀是必要的（見 `rescueInClipboardBeforeWriting`）。
    func rescue(_ text: String) {
        settle()
        let accumulated = (rescueStillInClipboard ?? "") + text
        // 沒寫成：剪貼簿已放回累積前的舊救援，不能宣稱新的全文在剪貼簿裡（restore 已重新記下舊救援）
        guard overwrite(with: accumulated) else { return }
        landedRescue = (accumulated, pasteboard.changeCount)
    }

    /// 使用者主動複製（History 分頁）：覆寫——呼叫端在此之前已用 `rescueStillInClipboard` 提示過。
    /// 寫入讓 changeCount 前進，救援紀錄自然失效，不必另外清。
    func copyForUser(_ text: String) {
        settle()
        _ = overwrite(with: text)
    }

    /// 要覆寫剪貼簿之前問「會蓋掉救援嗎」：先把在途 paste 收尾（它可能正暫時擠開救援，此刻 changeCount 不符），
    /// 再看。直接讀 `rescueStillInClipboard` 會在那 300ms 內漏判、跳過確認就覆寫。
    func rescueInClipboardBeforeWriting() -> String? {
        settle()
        return rescueStillInClipboard
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
        if allowingForeignWrite || pasteboard.changeCount == lease.writeChangeCount {
            restore(lease.target)
            return
        }
        // 別人動過：放了內容就讓步。只是被清空（剪貼簿管理器的定時清除之類）而被擠開的是救援時，
        // 沒有東西可以讓步——救援不放回就沒了，放回去。使用者內容則維持不寫回（清空可能正是其意圖）。
        if case .rescue = lease.target, (pasteboard.pasteboardItems ?? []).isEmpty {
            restore(lease.target)
        }
    }

    /// 覆寫（救援、使用者複製）：保存 → clear → setString；寫不進去就同步放回原本的東西——
    /// 與 #41 同型：失敗不得留下「舊的清掉了、新的沒進去」的兩頭皆空。回傳是否寫成。
    private func overwrite(with text: String) -> Bool {
        let target = snapshotTarget()
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) { return true }
        restore(target)
        return false
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
