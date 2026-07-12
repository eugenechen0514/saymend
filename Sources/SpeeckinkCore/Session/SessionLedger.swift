/// Session 帳本（規格 §3.3／§3.4）：持有 session 全文、版本堆疊與凍結狀態。
/// 純值型別，不碰任何系統 API；「怎麼物理改寫欄位」是 InsertionCoordinator 的事。
public struct SessionLedger {
    public private(set) var sessionText = ""
    public private(set) var frozen = false
    public private(set) var axAnchor: Int?
    public private(set) var isActive = false
    private var versions: [String] = []

    public init() {}

    public var canUndo: Bool { !versions.isEmpty }

    /// 開新 session。呼叫端在聽寫啟動時提供 AX 起點錨位（讀不到給 nil）。
    public mutating func begin(axAnchor: Int?) {
        sessionText = ""
        versions = []
        frozen = false
        isActive = true
        self.axAnchor = axAnchor
    }

    /// 新內容落定與修正落定共用：把舊全文推入版本堆疊、換上新全文。
    public mutating func commit(_ newFullText: String) {
        versions.append(sessionText)
        sessionText = newFullText
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
    }
}
