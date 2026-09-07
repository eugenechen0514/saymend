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

    /// 純追加（insertFinalized／insertDetached）的結局（issue #37）。
    /// 刻意**不加** `@discardableResult`：每個呼叫點都必須明白表態要怎麼處理「一個字都沒寫」，
    /// 忘了處理就是安靜的資料遺失。
    public enum AppendOutcome: Equatable, Sendable {
        case inserted
        /// AX 明確指出焦點已不在 session 欄位：**一個字都沒寫**，鏡像／counter 都沒動。
        /// 帶現在的前景 App bundleID 供診斷判讀同 App 或跨 App。
        case fieldChanged(currentAppBundleID: String?)
        /// 焦點在密碼欄位，或 AX 連兩次問不出 subrole 而 fail closed（issue #59）：一個字都沒寫。
        /// `subroleUnknown` 分辨「AX 明確說是密碼欄」與「問不出來只好當作是」——
        /// 0.2s timeout 誤殺了多少，量測就靠這一格。
        ///
        /// 刻意與 `fieldChanged` 分成**兩個 case**，而不是給後者加一個 reason 參數：
        /// `switch` 的窮盡性會逼每個呼叫點明白表態，忘了處理是編譯錯誤而不是安靜走錯分支。
        /// 分家還有第二個理由：`fieldChanged` 那組診斷樣本正是之後評估 `CFEqual` 誤判率的**分母**，
        /// 密碼欄位攔阻（永遠正確的攔阻）混進去就把分母弄髒了。
        case secureField(subroleUnknown: Bool)
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
    /// 寫入前的焦點閘門（issue #37）。nil＝沒有閘門＝維持舊行為（照常寫）。
    private let fieldGate: ((FieldIdentity?) -> FieldGate)?

    public private(set) var currentUtteranceText = ""
    public var currentUtteranceLength: Int { currentUtteranceText.count }
    private var insertCounter = 0

    // MARK: session 級狀態（issue #44）
    // 由 controller 在 ledger begin／archive 時設定與清除；延續窗 resume 只呼叫 reset()，這些都不動。
    private var sessionAnchor: Int?
    private var sessionIdentity: FieldIdentity?
    /// **欄位鏡像**：本 session 從 anchor 起實際寫在欄位上的文字。每個物理寫入都在本型別內同步更新——
    /// 所有寫入都經這裡，不會漏站。與 `SessionLedger.sessionText` 的差別：鏡像含尚未落定（潤飾在途）的 raw
    /// 與進行中的 utterance；Esc 退回以它為 expected，才能在潤飾在途時也退得掉（issue #21 的 1.5 秒窗口）。
    public private(set) var displayedText = ""

    public init(keystroke: any TextInserter,
                paste: any TextInserter,
                rangeReplacer: (any SessionRangeReplacing)? = nil,
                pasteThreshold: Int = 12,
                fieldGate: ((FieldIdentity?) -> FieldGate)? = nil) {
        self.keystroke = keystroke
        self.paste = paste
        self.rangeReplacer = rangeReplacer
        self.pasteThreshold = pasteThreshold
        self.fieldGate = fieldGate
    }

    /// 新 session：anchor／identity 來自 reader 同一次 snapshot（與 ledger 相同來源），
    /// initialText＝選取即目標的原選取（鏡像從它開始），一般聽寫為空。
    /// 起始原文本身不用留：Esc 的退回目標由呼叫端從帳本取（issue #46），這裡只需要鏡像。
    public func beginSession(anchor: Int?, identity: FieldIdentity?, initialText: String = "") {
        sessionAnchor = anchor
        sessionIdentity = identity
        displayedText = initialText
        currentUtteranceText = ""
    }

    /// session 封存：清掉所有 session 級狀態
    public func endSession() {
        sessionAnchor = nil
        sessionIdentity = nil
        displayedText = ""
        currentUtteranceText = ""
    }

    /// 延續窗 resume：同一 session，只清進行中的 utterance；鏡像、anchor、identity 都不動
    public func reset() {
        currentUtteranceText = ""
    }

    // MARK: - 純追加（永遠照常）

    /// finalized 片段上屏。主 inserter 失敗時換另一個（規格 §5.2 逐層降級）。
    /// 閘門判定焦點已換時回 `.fieldChanged`、判定是（或可能是）密碼欄時回 `.secureField`：
    /// 兩者都是**一個字都沒寫，帳本／鏡像／counter 都不動**。
    public func insertFinalized(_ text: String) throws -> AppendOutcome {
        guard !text.isEmpty else { return .inserted }
        let outcome = try insertWithFallback(text)
        guard case .inserted = outcome else { return outcome }
        currentUtteranceText += text
        displayedText += text
        insertCounter += 1
        return .inserted
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
    public func insertDetached(_ text: String) throws -> AppendOutcome {
        guard !text.isEmpty else { return .inserted }
        let outcome = try insertWithFallback(text)
        guard case .inserted = outcome else { return outcome }
        displayedText += text
        insertCounter += 1
        return .inserted
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
        // anchor 也在前置條件裡：沒有它就沒辦法同步鏡像，寧可不寫（其他三個會刪字的方法同此）
        guard let ax = rangeReplacer, let anchor = sessionAnchor, let identity = sessionIdentity else { return .unsupported }
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
            replaceInMirror(utf16Offset: location - anchor, expected: snap.text, with: newText)
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

    /// Esc：把本 session 寫在欄位上的**全部**文字（含已潤飾、已修正、潤飾在途的 raw 與進行中的 utterance）
    /// 一次驗證、一次替換成 `target`（issue #21／#46）。target 由呼叫端依設定決定：session 起始原文
    /// （一併退掉已潤飾）或帳本的已潤飾鏡像（只退 raw）。鏡像已等於 target＝沒東西可退：零寫入、安靜回 `.replaced`。
    /// 缺 anchor／identity／AX → `.unverified`；identity 或內容不符 → `.fieldMismatch`。兩者都一個字不動。
    public func retractSession(to target: String) -> SessionReplaceOutcome {
        guard displayedText != target else { return .replaced }
        guard let ax = rangeReplacer, let anchor = sessionAnchor, let identity = sessionIdentity else {
            return .unverified
        }
        return performVerifiedReplace(ax, identity: identity, location: anchor,
                                      expected: displayedText, with: target) {
            self.displayedText = target
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
    private func insertWithFallback(_ text: String) throws -> AppendOutcome {
        // 閘門必須查兩次（issue #37）。fallback 重送是**獨立的窗口 W1′**：
        // primary 拋錯到 secondary 送出之間，焦點一樣可能被搬走（primary 失敗本身就常伴隨
        // App 狀態變動），只擋 primary 等於把最後一段沒設防的路留著。
        if let blocked = focusGateBlock() { return blocked }
        let pasteFirst = text.count >= pasteThreshold
        let primary: any TextInserter = pasteFirst ? paste : keystroke
        let secondary: any TextInserter = pasteFirst ? keystroke : paste
        do {
            try primary.insert(text)
        } catch {
            if let blocked = focusGateBlock() { return blocked }
            try secondary.insert(text)   // 這裡再拋＝真失敗，交給呼叫端的 insertFailed 路徑
            onInserterFallback?(pasteFirst ? .pasteToKeystroke : .keystrokeToPaste)
        }
        return .inserted
    }

    /// 寫入前的閘門查詢（issue #37）：回非 nil＝這次不能寫。
    ///
    /// - `.different`：AX 明確指出焦點已換 → fail closed（裁定 Q1）。
    /// - `.secure`／`.secureUnknown`：這一層只回報「不能寫」，**session 的硬停由呼叫端負責**——
    ///   兩個消費端（`DictationController` 的 `insertFinalized`:471 與 `insertDetached`:936 分支）
    ///   都必須**先記診斷再 `abortForSecureField()`**（issue #63）。
    ///   兩者行為逐字相同，但分成 `subroleUnknown` 的兩種形態回報：後者是「AX 問不出來只好當作是」，
    ///   事後要靠這一格算 0.2s timeout 的誤殺率（issue #59）。
    ///   「不寫就滿足 §5.3」是**被否決的舊判斷**：被擋片段在 `segmenter.onTranscript` 就已進 buffer
    ///   （那一行跑在閘門查詢之前），session 不停就會經話語閉合把整句 raw 送雲端 provider，
    ///   並讓 `dispatch` 頂端那道無條件的 `recordExchange` 把 LLM 潤飾全文寫進 `history_exchange`。
    ///   日後新增 `.secureXxx` case 或改動本函式，硬停這一半不得省略。
    /// - `.same`／`.unknown`／沒接閘門：照常寫。`.unknown` 涵蓋「讀不到焦點」與
    ///   「無 AX 的 App（兩邊都沒有 identity）」——issue #21 的裁定，純追加永遠不得因缺 AX 而停。
    ///
    /// **每個 case 都明白列出，不用 `default`**：`FieldGate` 之後再長出新 case 時（`.secureUnknown`
    /// 就是這樣加進來的），編譯器必須在這裡叫，而不是讓新的未知狀態安靜掉進「照常寫」。
    private func focusGateBlock() -> AppendOutcome? {
        guard let fieldGate else { return nil }
        switch fieldGate(sessionIdentity) {
        case .different(let currentAppBundleID):
            return .fieldChanged(currentAppBundleID: currentAppBundleID)
        case .secure:
            return .secureField(subroleUnknown: false)      // AX 明確說是密碼欄
        case .secureUnknown:
            return .secureField(subroleUnknown: true)       // 問不出 subrole，fail closed 當作是
        case .same, .unknown:
            return nil
        }
    }
}
