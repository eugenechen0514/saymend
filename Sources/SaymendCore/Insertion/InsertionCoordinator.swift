/// 插入協調器：選擇 inserter、記錄 utterance 帳本與**欄位鏡像**、提供尾端替換／session 全文替換／整段退回。
/// 「session 即尾端」（M2 設計裁決 1）：存活 session 的全文永遠是欄位尾端的連續區段。
///
/// **會刪字的操作一律走 verified AX 範圍替換（issue #21／#44）**：Esc 整段退回、潤飾替換、修正、undo、
/// 選取替換、過期尾端回收。缺 anchor／identity／AX 能力、identity 不符、內容不符——任一項就不動欄位，
/// 回 `.unverified`／`.fieldMismatch` 讓呼叫端提示。本型別**沒有任何退格路徑**：TextInserter 只有 insert，
/// 「退化成盲退格」在型別上就不可能。純追加（insertFinalized／insertDetached）永遠照常，與 AX 無關。
public final class InsertionCoordinator {
    public struct UtteranceSnapshot: Equatable {
        public let text: String      // 快照當下的 utterance 全文（回復原文用）
        public let counter: Int      // 插入計數，偵測尾端是否前進
        public var length: Int { text.count }
    }

    /// 尾端替換／session 全文替換／整段退回共用的結果。
    public enum SessionReplaceOutcome: Equatable {
        case replaced
        case tailAdvanced      // 尾端已前進（快照後又有插入）：放棄
        case fieldMismatch     // AX 校驗不符（外力改動欄位、焦點不在起始元素）或兩步之間變動：放棄且呼叫端應凍結
        case unverified        // 無 anchor／identity／AX 能力：無法確認文字位置，**什麼都沒動**，呼叫端只提示、不凍結
    }

    /// 過期尾端回收結果（M10-C）。與另外兩個 outcome 型別分開：語意不同——
    /// 這條路徑失敗時原文完好留在螢幕上，呼叫端只需保留原文並說明原因，不必凍結、也無需急救。
    public enum StaleTailOutcome: Equatable {
        case replaced
        case mismatch       // 欄位已被外力改動，或兩步之間變動：放棄，保留原文
        case unsupported    // 無 AX 範圍能力／無 identity：放棄，保留原文
    }

    /// 選取替換結果（規格 §3.6）。與 SessionReplaceOutcome 分開：語意不同（selectionChanged
    /// ＝放棄且結果進 HUD 供複製；fieldMismatch＝凍結）。
    public enum SelectionReplaceOutcome: Equatable {
        case replaced
        case selectionChanged   // AX 校驗不符或兩步間變動：選取已不是快照當下的樣子，放棄
        case unsupported        // 無 AX 範圍能力／無 identity：呼叫端決定降級方式
    }

    /// 主 inserter 失敗、備援救回時的分類（issue #1 蒐證）。控制流上是「成功」，
    /// 但過去這條路徑什麼都不留，帳面與一次乾淨插入完全無法區分。
    public enum InserterFallback: String, Sendable {
        case pasteToKeystroke     // 長文優先 paste，失敗退 keystroke
        case keystrokeToPaste     // 短文優先 keystroke，失敗退 paste
    }

    /// 純觀察，不影響控制流；nil＝完全不觀察（預設）。
    /// 只在「主失敗、備援成功」時觸發：兩邊都倒是真失敗，走既有 insertFailed 路徑，不由這裡報。
    public var onInserterFallback: ((InserterFallback) -> Void)?

    private let keystroke: any TextInserter
    private let paste: any TextInserter
    private let rangeReplacer: (any SessionRangeReplacing)?
    private let pasteThreshold: Int

    public private(set) var currentUtteranceText = ""
    public var currentUtteranceLength: Int { currentUtteranceText.count }
    private var insertCounter = 0

    // MARK: session 級狀態（issue #44）
    // 由 controller 在 ledger begin／archive 時設定與清除；延續窗 resume 只呼叫 reset()，這些都不動。
    private var sessionAnchor: Int?
    private var sessionIdentity: FieldIdentity?
    private var initialText = ""
    /// **欄位鏡像**：本 session 從 anchor 起實際寫在欄位上的文字。每個物理寫入都在本型別內同步更新——
    /// 所有寫入都經這裡，不會漏站。與 `SessionLedger.sessionText` 的差別：鏡像含尚未落定（潤飾在途）的 raw
    /// 與進行中的 utterance；Esc 退回以它為 expected，才能在潤飾在途時也退得掉（issue #21 的 1.5 秒窗口）。
    public private(set) var displayedText = ""
    /// Esc 有沒有東西可退：鏡像已偏離 session 起始原文
    public var hasRetractableText: Bool { displayedText != initialText }

    public init(keystroke: any TextInserter,
                paste: any TextInserter,
                rangeReplacer: (any SessionRangeReplacing)? = nil,
                pasteThreshold: Int = 12) {
        self.keystroke = keystroke
        self.paste = paste
        self.rangeReplacer = rangeReplacer
        self.pasteThreshold = pasteThreshold
    }

    /// 新 session：anchor／identity 來自 reader 同一次 snapshot（與 ledger 相同來源），
    /// initialText＝選取即目標的原選取（鏡像從它開始），一般聽寫為空。
    public func beginSession(anchor: Int?, identity: FieldIdentity?, initialText: String = "") {
        sessionAnchor = anchor
        sessionIdentity = identity
        self.initialText = initialText
        displayedText = initialText
        currentUtteranceText = ""
    }

    /// session 封存：清掉所有 session 級狀態
    public func endSession() {
        sessionAnchor = nil
        sessionIdentity = nil
        initialText = ""
        displayedText = ""
        currentUtteranceText = ""
    }

    /// 延續窗 resume：同一 session，只清進行中的 utterance；鏡像、anchor、identity 都不動
    public func reset() {
        currentUtteranceText = ""
    }

    // MARK: - 純追加（永遠照常）

    /// finalized 片段上屏。主 inserter 失敗時換另一個（規格 §5.2 逐層降級）。
    public func insertFinalized(_ text: String) throws {
        guard !text.isEmpty else { return }
        try insertWithFallback(text)
        currentUtteranceText += text
        displayedText += text
        insertCounter += 1
    }

    /// 緩衝模式（選取即目標，M3 設計裁決 1）：finalized 只記帳不上屏。
    /// 不動 insertCounter、不動鏡像——螢幕上什麼都沒發生。
    public func accumulateFinalized(_ text: String) {
        currentUtteranceText += text
    }

    /// 緩衝模式的 Esc：清掉帳本。螢幕上本來就沒有字，發任何鍵盤事件都是錯的。
    public func clearCurrentUtterance() {
        currentUtteranceText = ""
    }

    /// 不掛 utterance 帳本的直接插入：緩衝後續句落地用。
    /// 走 insertWithFallback（長度門檻選 paste／keystroke），成功即 counter 前進、鏡像追加。
    public func insertDetached(_ text: String) throws {
        guard !text.isEmpty else { return }
        try insertWithFallback(text)
        displayedText += text
        insertCounter += 1
    }

    /// 零長度、現時 counter 的指令快照（零副作用，不動 currentUtteranceText）。
    /// 緩衝 undo 專用：緩衝句從未上屏、無指令話語可退，但 counter 必須是「現在」的值。
    public func currentTailSnapshot() -> UtteranceSnapshot {
        UtteranceSnapshot(text: "", counter: insertCounter)
    }

    /// 關閉目前 utterance 帳本並開新的；回傳舊帳本快照供潤飾／修正使用。不動鏡像——字還在螢幕上。
    public func snapshotAndBeginNext() -> UtteranceSnapshot {
        let snap = UtteranceSnapshot(text: currentUtteranceText, counter: insertCounter)
        currentUtteranceText = ""
        return snap
    }

    // MARK: - 會刪字的操作（verified AX 專屬）

    /// 選取範圍替換（規格 §3.6）：AX 專屬——選取在欄位中段。
    /// 校驗不符或兩步間變動一律放棄（selectionChanged）：AX 失敗可能留下活選取，
    /// 任何 keystroke 收尾都會把選取吃掉（同 M2 終審「兩通道不混用」finding）。
    public func replaceSelection(location: Int, expected: String, with newText: String) -> SelectionReplaceOutcome {
        guard let ax = rangeReplacer, let identity = sessionIdentity else { return .unsupported }
        switch ax.verifyRange(fieldIdentity: identity, location: location, expected: expected) {
        case .unsupported: return .unsupported
        case .mismatch: return .selectionChanged
        case .replaced:
            guard ax.replaceVerifiedRange(fieldIdentity: identity, location: location,
                                          expected: expected, with: newText) == .replaced else {
                return .selectionChanged
            }
            insertCounter += 1
            currentUtteranceText = ""
            displayedText = newText            // 選取即 session 起點：整個鏡像就是它
            return .replaced
        }
    }

    /// 回收「已不在尾端」的潤飾（M10-C）。
    /// A 後面已經接了 B，這裡以絕對範圍帶校驗替換，並保留游標（後續串流插入才不會落在句子中間）。
    /// 校驗不符＝欄位被外力改動，放棄（鐵律：不覆蓋使用者的修改）。
    /// **刻意不遞增 insertCounter**：中段改寫沒有改變「誰是尾端」，遞增會讓後續句子的快照
    /// 對不上而被迫也走這條慢路徑——它們其實仍在尾端，正常的 replaceTail 就能處理。
    public func replaceStaleTail(_ snap: UtteranceSnapshot,
                                 at location: Int,
                                 with newText: String) -> StaleTailOutcome {
        guard let ax = rangeReplacer, let identity = sessionIdentity else { return .unsupported }
        // 零長度快照沒有可校驗的錨——那樣的「替換」等於在算出來的位置盲插，寧可放棄
        guard !snap.text.isEmpty else { return .mismatch }
        switch ax.verifyRange(fieldIdentity: identity, location: location, expected: snap.text) {
        case .unsupported: return .unsupported
        case .mismatch:    return .mismatch
        case .replaced:
            guard ax.replaceVerifiedRangePreservingCaret(fieldIdentity: identity, location: location,
                                                         expected: snap.text, with: newText) == .replaced else {
                return .mismatch   // 兩步之間變動：放棄，原文留在螢幕上
            }
            if let anchor = sessionAnchor {
                replaceInMirror(utf16Offset: location - anchor, expected: snap.text, with: newText)
            }
            return .replaced
        }
    }

    /// 以潤飾後文字替換快照的 utterance（尾端未前進才執行）。
    /// 快照必在鏡像尾端：counter 相符＝快照後沒有任何寫入。位置＝anchor + 鏡像長度 − 快照長度（UTF-16）。
    public func replaceTail(_ snap: UtteranceSnapshot, with newText: String) -> SessionReplaceOutcome {
        guard snap.counter == insertCounter else { return .tailAdvanced }
        if snap.text.isEmpty { return newText.isEmpty ? .replaced : .unverified }   // 空對空＝沒事可做；空快照無錨可驗
        guard let ax = rangeReplacer, let anchor = sessionAnchor, let identity = sessionIdentity else {
            return .unverified
        }
        // 以 UTF-16 比對鏡像尾端：String 的 hasSuffix／removeLast 是字位語意（且會做 canonical equivalence），
        // 跨 utterance 的組字（前一句尾 "e"、下一句只有 "\u{301}"）會讓字位邊界對不上；AX 範圍本來就是 UTF-16。
        // 鏡像若對不上快照（不該發生的漂移），寧可判 mismatch 不動欄位，不要用錯的位置去驗。
        let mirror = Array(displayedText.utf16), tail = Array(snap.text.utf16)
        guard mirror.count >= tail.count, Array(mirror[(mirror.count - tail.count)...]) == tail else {
            return .fieldMismatch
        }
        let location = anchor + mirror.count - tail.count
        return performVerifiedReplace(ax, identity: identity, location: location,
                                      expected: snap.text, with: newText) {
            // 前綴是合法字串（鏡像＝前綴＋快照的逐 unit 串接），切在快照起點不會留下孤立 surrogate
            self.displayedText = String(decoding: mirror[..<(mirror.count - tail.count)], as: UTF16.self) + newText
        }
    }

    /// 修正／復原用（規格 §3.3）：把「session 全文＋緊隨其後的指令話語」＝整個鏡像，
    /// 一次驗證、一次替換成 newText，全程不發任何鍵盤事件。
    /// 舊契約在 AX unsupported 時退回 keystroke 盲退格——那是 #21 destructive 清單裡唯一的 fail-open 點，
    /// issue #44 封掉：現在回 `.unverified`，呼叫端保留原文並提示。
    public func replaceSession(commandSnapshot: UtteranceSnapshot,
                               with newText: String) -> SessionReplaceOutcome {
        guard commandSnapshot.counter == insertCounter else { return .tailAdvanced }
        guard let ax = rangeReplacer, let anchor = sessionAnchor, let identity = sessionIdentity else {
            return .unverified
        }
        if displayedText.isEmpty && newText.isEmpty { return .replaced }
        return performVerifiedReplace(ax, identity: identity, location: anchor,
                                      expected: displayedText, with: newText) {
            self.displayedText = newText
            self.currentUtteranceText = ""
        }
    }

    /// Esc：把本 session 寫在欄位上的**全部**文字退回 session 起始原文（issue #21）——含已潤飾、
    /// 已修正、潤飾在途的 raw 與進行中的 utterance。沒東西可退時零寫入、安靜回 `.replaced`。
    /// 缺 anchor／identity／AX → `.unverified`；identity 或內容不符 → `.fieldMismatch`。兩者都一個字不動。
    public func retractSession() -> SessionReplaceOutcome {
        guard hasRetractableText else { return .replaced }
        guard let ax = rangeReplacer, let anchor = sessionAnchor, let identity = sessionIdentity else {
            return .unverified
        }
        return performVerifiedReplace(ax, identity: identity, location: anchor,
                                      expected: displayedText, with: initialText) {
            self.displayedText = self.initialText
            self.currentUtteranceText = ""
        }
    }

    // MARK: - 內部

    /// 兩步 AX 替換的共用骨架：verify → replace → 成功才更新鏡像與 counter。
    /// 兩步之間變動一律 fieldMismatch（AX 可能留下活選取；絕不落 keystroke 收尾）。
    private func performVerifiedReplace(_ ax: any SessionRangeReplacing, identity: FieldIdentity,
                                        location: Int, expected: String, with newText: String,
                                        onSuccess: () -> Void) -> SessionReplaceOutcome {
        switch ax.verifyRange(fieldIdentity: identity, location: location, expected: expected) {
        case .unsupported:
            return .unverified
        case .mismatch:
            return .fieldMismatch
        case .replaced:
            guard ax.replaceVerifiedRange(fieldIdentity: identity, location: location,
                                          expected: expected, with: newText) == .replaced else {
                return .fieldMismatch
            }
            onSuccess()
            insertCounter += 1
            return .replaced
        }
    }

    /// 鏡像的中段替換（過期尾端回收用）。位置對不上就不動：鏡像寧可保留舊值，讓之後的 Esc fail closed。
    private func replaceInMirror(utf16Offset: Int, expected: String, with newText: String) {
        let utf16 = displayedText.utf16
        guard utf16Offset >= 0,
              let lower = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex),
              let upper = utf16.index(lower, offsetBy: expected.utf16.count, limitedBy: utf16.endIndex),
              let lo = String.Index(lower, within: displayedText),
              let hi = String.Index(upper, within: displayedText),
              String(displayedText[lo..<hi]) == expected else { return }
        displayedText.replaceSubrange(lo..<hi, with: newText)
    }

    /// 主 inserter 拋錯後**全量**重送給備援。成立的前提是 TextInserter 的原子契約（issue #38）：
    /// 主 inserter 拋錯＝一個字都沒進欄位，重送完整文字才不會留下「前綴＋完整文字」。
    private func insertWithFallback(_ text: String) throws {
        let pasteFirst = text.count >= pasteThreshold
        let primary: any TextInserter = pasteFirst ? paste : keystroke
        let secondary: any TextInserter = pasteFirst ? keystroke : paste
        do {
            try primary.insert(text)
        } catch {
            try secondary.insert(text)   // 這裡再拋＝真失敗，交給呼叫端的 insertFailed 路徑
            onInserterFallback?(pasteFirst ? .pasteToKeystroke : .keystrokeToPaste)
        }
    }
}
