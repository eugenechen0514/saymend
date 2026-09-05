/// Session 帳本（規格 §3.3／§3.4）：持有 session 全文、版本堆疊與凍結狀態。
/// 純值型別，不碰任何系統 API；「怎麼物理改寫欄位」是 InsertionCoordinator 的事。
public struct SessionLedger {
    public private(set) var sessionText = ""
    public private(set) var frozen = false
    public private(set) var axAnchor: Int?
    /// session 起始欄位的 identity token（issue #43）：與 axAnchor 同為 AX 路徑的錨，
    /// 由 reader 在熱鍵按下時登記、archive 時由 controller 釋放。nil＝reader 沒給（無 AX）。
    public private(set) var fieldIdentity: FieldIdentity?
    public private(set) var isActive = false
    /// session 世代：每次 begin 遞增（延續窗 resume 不會 begin，故不變）。
    /// controller 的在途 LLM outcome 以此判別歸屬——archive→begin 後，舊世代 outcome 一律丟棄。
    public private(set) var generation = 0
    private var versions: [String] = []

    public init() {}

    public var canUndo: Bool { !versions.isEmpty }

    /// 開新 session。呼叫端在聽寫啟動時提供 AX 起點錨位（讀不到給 nil）。
    /// initialText＝選取即目標模式的種子（規格 §3.6）：sessionText 起始即為
    /// 使用者選取的原文，首次 commit 後 undo 便回到它；一般聽寫維持空字串。
    public mutating func begin(axAnchor: Int?, fieldIdentity: FieldIdentity? = nil, initialText: String = "") {
        sessionText = initialText
        versions = []
        frozen = false
        isActive = true
        self.axAnchor = axAnchor
        self.fieldIdentity = fieldIdentity
        generation &+= 1
    }

    /// 新內容落定與修正落定共用：把舊全文推入版本堆疊、換上新全文。
    public mutating func commit(_ newFullText: String) {
        versions.append(sessionText)
        sessionText = newFullText
    }

    /// tail 的 .degraded 專用鏡像校準（規格 §1.2 A4）：raw 已由 ASR 上屏且存在於欄位，
    /// ledger 的欄位鏡像必須同步，否則下一句的 context、field mismatch 與 history 會和
    /// 實際欄位分歧。但這是「對已觀察到之 raw 的鏡像校準」，不是接受 LLM outcome——
    /// 因此不推入版本堆疊：我們什麼都沒改寫，就沒有東西可以復原。
    public mutating func synchronizeObservedTail(_ fullText: String) {
        sessionText = fullText
        // versions 不變 → canUndo 與 undo stack 不受影響
    }

    /// 回上一版。回傳 (from: 目前全文, to: 上一版全文) 供物理替換；堆疊空回 nil。
    public mutating func undo() -> (from: String, to: String)? {
        guard let previous = versions.popLast() else { return nil }
        let current = sessionText
        sessionText = previous
        return (from: current, to: previous)
    }

    /// 凍結：文字定稿，此後不得再對欄位做任何程式化改寫（規格 §3.4）。
    public mutating func freeze() {
        frozen = true
    }

    /// 封存：session 結束，清空全部狀態。
    public mutating func archive() {
        sessionText = ""
        versions = []
        frozen = false
        isActive = false
        axAnchor = nil
        fieldIdentity = nil
    }
}
