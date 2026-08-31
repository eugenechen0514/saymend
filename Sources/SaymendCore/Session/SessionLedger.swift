/// Session 帳本（規格 §3.3／§3.4）：持有 session 全文、版本堆疊與凍結狀態。
/// 純值型別，不碰任何系統 API；「怎麼物理改寫欄位」是 InsertionCoordinator 的事。
public struct SessionLedger {
    public struct UndoStep: Equatable {
        public let from: String
        public let to: String
        fileprivate let fromEscapeRetainedText: String
        fileprivate let toEscapeRetainedText: String
    }

    private struct Version {
        let text: String
        let escapeRetainedText: String
    }

    public private(set) var sessionText = ""
    /// 聽寫階段開始前由本階段掌控的原文；一般 tail 是空字串，選取即目標則是原選取。
    /// issue #21 的 Esc 全階段退回以此為終點，不可拿 `sessionText` 猜起點。
    public private(set) var initialText = ""
    public private(set) var frozen = false
    public private(set) var axAnchor: Int?
    public private(set) var fieldIdentity: FieldIdentity?
    public private(set) var isActive = false
    /// session 世代：每次 begin 遞增（延續窗 resume 不會 begin，故不變）。
    /// controller 的在途 LLM outcome 以此判別歸屬——archive→begin 後，舊世代 outcome 一律丟棄。
    public private(set) var generation = 0
    private var versions: [Version] = []
    /// 關閉「Esc 一併退掉已潤飾文字」時要留下的 polished-only mirror。
    /// 它不能存「最後一次完整 session snapshot」：若 A degraded、B polished，完整 snapshot 是 A+B，
    /// 會把未潤飾 A 一起留下。append／replace 兩種 commit 必須分開表達。
    private var escapeRetainedPolishedText = ""

    public init() {}

    public var canUndo: Bool { !versions.isEmpty }

    /// 開新 session。呼叫端在聽寫啟動時提供 AX 起點錨位（讀不到給 nil）。
    /// initialText＝選取即目標模式的種子（規格 §3.6）：sessionText 起始即為
    /// 使用者選取的原文，首次 commit 後 undo 便回到它；一般聽寫維持空字串。
    public mutating func begin(axAnchor: Int?, fieldIdentity: FieldIdentity? = nil,
                               initialText: String = "") {
        sessionText = initialText
        self.initialText = initialText
        versions = []
        escapeRetainedPolishedText = initialText
        frozen = false
        isActive = true
        self.axAnchor = axAnchor
        self.fieldIdentity = fieldIdentity
        generation &+= 1
    }

    /// 全文潤飾／修正落定：舊狀態進 undo stack，新全文全部取得 polished 身分。
    public mutating func commit(_ newFullText: String) {
        pushCurrentVersion()
        sessionText = newFullText
        escapeRetainedPolishedText = newFullText
    }

    /// new_content 落定：欄位與 session 皆追加，但 Esc opt-out 只把這次真的 polished 文字
    /// 追加進 retained mirror；先前 `.degraded`／keepRaw 的 raw 不會被順帶洗成 polished。
    public mutating func appendPolished(_ text: String) {
        pushCurrentVersion()
        sessionText += text
        escapeRetainedPolishedText += text
    }

    /// 有效 outcome 無法改寫而保留 raw：照既有契約建立 undo 版本，但不授予 polished 身分。
    public mutating func commitRaw(_ newFullText: String) {
        pushCurrentVersion()
        sessionText = newFullText
    }

    /// tail 的 .degraded 專用鏡像校準（規格 §1.2 A4）：raw 已由 ASR 上屏且存在於欄位，
    /// ledger 的欄位鏡像必須同步，否則下一句的 context、field mismatch 與 history 會和
    /// 實際欄位分歧。但這是「對已觀察到之 raw 的鏡像校準」，不是接受 LLM outcome——
    /// 因此不推入版本堆疊，也不改 polished-only mirror。
    public mutating func synchronizeObservedTail(_ fullText: String) {
        sessionText = fullText
    }

    /// 回上一版。文字與 polished-only mirror 必須一起回去；否則 undo 後的 Esc opt-out
    /// 會保留一份已不在欄位中的未來版本。
    public mutating func undo() -> UndoStep? {
        guard let previous = versions.popLast() else { return nil }
        let step = UndoStep(from: sessionText, to: previous.text,
                            fromEscapeRetainedText: escapeRetainedPolishedText,
                            toEscapeRetainedText: previous.escapeRetainedText)
        sessionText = previous.text
        escapeRetainedPolishedText = previous.escapeRetainedText
        return step
    }

    /// 物理 undo 失敗、欄位已回復 `step.from` 時，把剛 pop 的版本與兩份 mirror 一起補回。
    public mutating func restoreFailedUndo(_ step: UndoStep) {
        versions.append(Version(text: step.to, escapeRetainedText: step.toEscapeRetainedText))
        sessionText = step.from
        escapeRetainedPolishedText = step.fromEscapeRetainedText
    }

    /// Esc 的物理退回終點。關閉「一併退掉已潤飾文字」時只保留 polished-only mirror；
    /// `.degraded`、keepRaw、仍在途與正在說的 raw 一樣退掉。開啟時回到聽寫開始前。
    public func escapeRetractionTarget(includingPolishedText: Bool) -> String {
        includingPolishedText ? initialText : escapeRetainedPolishedText
    }

    /// 凍結：文字定稿，此後不得再對欄位做任何程式化改寫（規格 §3.4）。
    public mutating func freeze() {
        frozen = true
    }

    /// 封存：session 結束，清空全部狀態。
    public mutating func archive() {
        sessionText = ""
        initialText = ""
        versions = []
        escapeRetainedPolishedText = ""
        frozen = false
        isActive = false
        axAnchor = nil
        fieldIdentity = nil
    }

    private mutating func pushCurrentVersion() {
        versions.append(Version(text: sessionText,
                                escapeRetainedText: escapeRetainedPolishedText))
    }
}
