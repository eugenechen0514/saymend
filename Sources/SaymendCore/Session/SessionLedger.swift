/// Session 帳本（規格 §3.3／§3.4）：持有 session 全文、版本堆疊與凍結狀態。
/// 純值型別，不碰任何系統 API；「怎麼物理改寫欄位」是 InsertionCoordinator 的事。
public struct SessionLedger {
    /// undo 的一步：`from`＝復原前全文、`to`＝復原後全文，供物理替換。
    /// 兩份 polished 鏡像跟著走：物理 undo 失敗時 `restoreFailedUndo` 要把它們一起補回。
    public struct UndoStep: Equatable {
        public let from: String
        public let to: String
        fileprivate let fromPolishedText: String
        fileprivate let toPolishedText: String
    }

    private struct Version {
        let text: String
        let polishedText: String
    }

    public private(set) var sessionText = ""
    /// 聽寫階段開始前由本階段掌控的原文（issue #44）：一般 tail 是空字串，選取即目標是原選取。
    /// Esc 整段退回以此為終點——不是退成空，否則會把使用者的原選取刪掉。
    public private(set) var initialText = ""
    /// **已潤飾文字鏡像**（issue #46）：本 session 裡由 LLM 產出、且已落定在欄位上的文字，依落地順序串接。
    /// 「Esc 一併退掉已潤飾文字」關閉時，Esc 退到這裡而不是 initialText——只退 raw（degraded、keepRaw、
    /// 潤飾在途、正在說的），保留潤飾結果。它不能存「最後一次完整 session 全文」：A degraded、B polished 時
    /// 完整全文是 A+B，會把未潤飾的 A 一起留下——所以追加落定（appendPolished）與全文替換落定（commit）分開表達。
    /// 版本堆疊帶著它一起走：undo 後的 Esc 才不會保留一份已不在欄位上的未來版本。
    public private(set) var polishedText = ""
    public private(set) var frozen = false
    public private(set) var axAnchor: Int?
    /// session 起始欄位的 identity token（issue #43）：與 axAnchor 同為 AX 路徑的錨，
    /// 由 reader 在熱鍵按下時登記、archive 時由 controller 釋放。nil＝reader 沒給（無 AX）。
    public private(set) var fieldIdentity: FieldIdentity?
    public private(set) var isActive = false
    /// session 世代：每次 begin 遞增（延續窗 resume 不會 begin，故不變）。
    /// controller 的在途 LLM outcome 以此判別歸屬——archive→begin 後，舊世代 outcome 一律丟棄。
    public private(set) var generation = 0
    private var versions: [Version] = []

    public init() {}

    public var canUndo: Bool { !versions.isEmpty }

    /// 開新 session。呼叫端在聽寫啟動時提供 AX 起點錨位（讀不到給 nil）。
    /// initialText＝選取即目標模式的種子（規格 §3.6）：sessionText 起始即為
    /// 使用者選取的原文，首次 commit 後 undo 便回到它；一般聽寫維持空字串。
    /// 起始原文本來就不是我們寫的，polished 鏡像也從它開始（Esc 只退 raw 時一樣保留它）。
    public mutating func begin(axAnchor: Int?, fieldIdentity: FieldIdentity? = nil, initialText: String = "") {
        sessionText = initialText
        self.initialText = initialText
        polishedText = initialText
        versions = []
        frozen = false
        isActive = true
        self.axAnchor = axAnchor
        self.fieldIdentity = fieldIdentity
        generation &+= 1
    }

    /// 全文替換落定（修正、選取替換）：把舊全文推入版本堆疊、換上新全文，**整段**取得 polished 身分——
    /// 新全文是 LLM 的產物，先前混在裡面的 raw 已被它改寫掉。
    public mutating func commit(_ newFullText: String) {
        pushCurrentVersion()
        sessionText = newFullText
        polishedText = newFullText
    }

    /// 新內容落定（潤飾追加）：session 全文與 polished 鏡像都追加**這一句**的潤飾結果；
    /// 先前 degraded／keepRaw 留下的 raw 不會被順帶洗成 polished。
    public mutating func appendPolished(_ text: String) {
        pushCurrentVersion()
        sessionText += text
        polishedText += text
    }

    /// 有效 outcome 套用失敗、raw 照留（keepRaw）：照既有契約建立 undo 版本，但不授予 polished 身分。
    public mutating func commitRaw(_ newFullText: String) {
        pushCurrentVersion()
        sessionText = newFullText
    }

    /// tail 的 .degraded 專用鏡像校準（規格 §1.2 A4）：raw 已由 ASR 上屏且存在於欄位，
    /// ledger 的欄位鏡像必須同步，否則下一句的 context、field mismatch 與 history 會和
    /// 實際欄位分歧。但這是「對已觀察到之 raw 的鏡像校準」，不是接受 LLM outcome——
    /// 因此不推入版本堆疊（我們什麼都沒改寫，就沒有東西可以復原），也不動 polished 鏡像。
    public mutating func synchronizeObservedTail(_ fullText: String) {
        sessionText = fullText
        // versions 不變 → canUndo 與 undo stack 不受影響
    }

    /// 回上一版。回傳 (from: 目前全文, to: 上一版全文) 供物理替換；堆疊空回 nil。
    /// polished 鏡像跟著回到上一版。
    public mutating func undo() -> UndoStep? {
        guard let previous = versions.popLast() else { return nil }
        let step = UndoStep(from: sessionText, to: previous.text,
                            fromPolishedText: polishedText, toPolishedText: previous.polishedText)
        sessionText = previous.text
        polishedText = previous.polishedText
        return step
    }

    /// 物理 undo 失敗（欄位仍是 `step.from`）：把剛 pop 的版本補回堆疊、全文與 polished 鏡像都回到復原前。
    /// 呼叫端接著若把指令話語入帳（keepRaw），那是另一版。
    public mutating func restoreFailedUndo(_ step: UndoStep) {
        versions.append(Version(text: step.to, polishedText: step.toPolishedText))
        sessionText = step.from
        polishedText = step.fromPolishedText
    }

    /// Esc 的物理退回終點（issue #46）：一併退掉已潤飾＝回到聽寫開始前；只退 raw＝退到 polished 鏡像。
    public func escapeRetractionTarget(includingPolishedText: Bool) -> String {
        includingPolishedText ? initialText : polishedText
    }

    /// 凍結：文字定稿，此後不得再對欄位做任何程式化改寫（規格 §3.4）。
    public mutating func freeze() {
        frozen = true
    }

    /// 封存：session 結束，清空全部狀態。
    public mutating func archive() {
        sessionText = ""
        initialText = ""
        polishedText = ""
        versions = []
        frozen = false
        isActive = false
        axAnchor = nil
        fieldIdentity = nil
    }

    private mutating func pushCurrentVersion() {
        versions.append(Version(text: sessionText, polishedText: polishedText))
    }
}
