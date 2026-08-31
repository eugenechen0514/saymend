/// 插入協調器：選擇 inserter、記錄 utterance 帳本、提供尾端替換／session 全文替換／丟棄。
/// 「session 即尾端」（M2 設計裁決 1）：存活 session 的全文永遠是欄位尾端的連續區段，
/// 故 keystroke 路徑可用退格重打完成全文替換；AX 可用時優先走帶校驗的範圍替換。
public final class InsertionCoordinator {
    public struct UtteranceSnapshot: Equatable {
        public let text: String      // 快照當下的 utterance 全文（回復原文用）
        public let counter: Int      // 插入計數，偵測尾端是否前進
        public var length: Int { text.count }
    }

    public enum SessionReplaceOutcome: Equatable {
        case replaced
        case tailAdvanced      // 尾端已前進（快照後又有插入）：放棄
        case fieldMismatch     // AX 校驗不符（外力改動欄位）：放棄且呼叫端應凍結
    }

    /// Esc 全聽寫階段退回。沒有 tailAdvanced：呼叫端提供的是按下 Esc 當下完整欄位鏡像。
    public enum SessionRetractionOutcome: Equatable {
        case retracted
        case fieldMismatch
    }

    /// 過期尾端回收結果（M10-C）。與另外兩個 outcome 型別分開：語意不同——
    /// 這條路徑失敗時原文完好留在螢幕上，呼叫端只需保留原文並說明原因，不必凍結、也無需急救。
    public enum StaleTailOutcome: Equatable {
        case replaced
        case mismatch       // 欄位已被外力改動，或兩步之間變動：放棄，保留原文
        case unsupported    // 無 AX 範圍能力：放棄，保留原文
    }

    /// 選取替換結果（規格 §3.6）。與 SessionReplaceOutcome 分開：語意不同（selectionChanged
    /// ＝放棄且結果進 HUD 供複製；fieldMismatch＝凍結）。
    public enum SelectionReplaceOutcome: Equatable {
        case replaced
        case selectionChanged   // AX 校驗不符或兩步間變動：選取已不是快照當下的樣子，放棄
        case unsupported        // 無 AX 範圍能力：呼叫端改走「打字蓋選取」＋立即凍結
    }

    /// 主 inserter 失敗、備援救回時的分類（issue #1 蒐證）。控制流上是「成功」，
    /// 但 replaceTail 偶發落地失敗的兩個候選 trigger 之一正是 paste 偶發失敗——
    /// 過去這條路徑什麼都不留，帳面與一次乾淨插入完全無法區分。
    /// 另一個候選 trigger（counter-mismatch）已由 M7 的 insertSkipped/counterMismatch 覆蓋。
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

    public init(keystroke: any TextInserter,
                paste: any TextInserter,
                rangeReplacer: (any SessionRangeReplacing)? = nil,
                pasteThreshold: Int = 12) {
        self.keystroke = keystroke
        self.paste = paste
        self.rangeReplacer = rangeReplacer
        self.pasteThreshold = pasteThreshold
    }

    public func reset() {
        currentUtteranceText = ""
    }

    /// finalized 片段上屏。主 inserter 失敗時換另一個（規格 §5.2 逐層降級）。
    public func insertFinalized(_ text: String) throws {
        guard !text.isEmpty else { return }
        try insertWithFallback(text)
        currentUtteranceText += text
        insertCounter += 1
    }

    /// 緩衝模式（選取即目標，M3 設計裁決 1）：finalized 只記帳不上屏。
    /// 不動 insertCounter——螢幕上什麼都沒發生。
    public func accumulateFinalized(_ text: String) {
        currentUtteranceText += text
    }

    /// 緩衝模式的 Esc：清掉帳本。螢幕上本來就沒有字，發任何鍵盤事件都是錯的。
    public func clearCurrentUtterance() {
        currentUtteranceText = ""
    }

    /// 不掛 utterance 帳本的直接插入：「打字蓋選取」降級與緩衝後續句落地用。
    /// 走 insertWithFallback（長度門檻選 paste／keystroke），成功即 counter 前進。
    public func insertDetached(_ text: String) throws {
        guard !text.isEmpty else { return }
        try insertWithFallback(text)
        insertCounter += 1
    }

    /// 零長度、現時 counter 的指令快照（零副作用，不動 currentUtteranceText）。
    /// 緩衝 undo 專用：緩衝句從未上屏、無指令話語可退，但 counter 必須是「現在」的值——
    /// 用該句在首句替換前取的舊快照，replaceSession 會誤判 tailAdvanced。
    public func currentTailSnapshot() -> UtteranceSnapshot {
        UtteranceSnapshot(text: "", counter: insertCounter)
    }

    /// 選取範圍替換（規格 §3.6）：AX 專屬——選取在欄位中段，keystroke 退格重打不適用。
    /// 校驗不符或兩步間變動一律放棄（selectionChanged）：AX 失敗可能留下活選取，
    /// 任何 keystroke 收尾都會把選取吃掉（同 M2 終審「兩通道不混用」finding）。
    public func replaceSelection(location: Int, expected: String, with newText: String) -> SelectionReplaceOutcome {
        guard let ax = rangeReplacer else { return .unsupported }
        switch ax.verifyRange(location: location, expected: expected) {
        case .unsupported: return .unsupported
        case .mismatch: return .selectionChanged
        case .replaced:
            if ax.replaceVerifiedRange(location: location, expected: expected, with: newText) == .replaced {
                insertCounter += 1
                currentUtteranceText = ""
                return .replaced
            }
            return .selectionChanged
        }
    }

    /// 回收「已不在尾端」的潤飾（M10-C）。
    /// A 後面已經接了 B，退格重打會從游標往回刪、吃掉 B 的字，故 replaceTail 擋下它是對的；
    /// 這裡改以絕對範圍帶校驗替換，並保留游標（後續串流插入才不會落在句子中間）。
    /// 校驗不符＝欄位被外力改動，放棄（鐵律：不覆蓋使用者的修改）。
    /// **刻意不遞增 insertCounter**：中段改寫沒有改變「誰是尾端」，遞增會讓後續句子的快照
    /// 對不上而被迫也走這條慢路徑——它們其實仍在尾端，正常的 replaceTail 就能處理。
    public func replaceStaleTail(_ snap: UtteranceSnapshot,
                                 at location: Int,
                                 with newText: String) -> StaleTailOutcome {
        guard let ax = rangeReplacer else { return .unsupported }
        // 零長度快照沒有可校驗的錨——那樣的「替換」等於在算出來的位置盲插，寧可放棄
        guard !snap.text.isEmpty else { return .mismatch }
        switch ax.verifyRange(location: location, expected: snap.text) {
        case .unsupported: return .unsupported
        case .mismatch:    return .mismatch
        case .replaced:
            if ax.replaceVerifiedRangePreservingCaret(location: location,
                                                      expected: snap.text,
                                                      with: newText) == .replaced {
                return .replaced
            }
            return .mismatch   // 兩步之間變動：放棄，原文留在螢幕上
        }
    }

    /// 關閉目前 utterance 帳本並開新的；回傳舊帳本快照供潤飾／修正使用。
    public func snapshotAndBeginNext() -> UtteranceSnapshot {
        let snap = UtteranceSnapshot(text: currentUtteranceText, counter: insertCounter)
        currentUtteranceText = ""
        return snap
    }

    /// 以潤飾後文字替換快照的 utterance（尾端未前進才執行）。
    /// 失敗回復（鐵律）：刪除成功但補插失敗→重打原文；再失敗→丟 lostText。
    public func replaceTail(_ snap: UtteranceSnapshot, with newText: String) throws -> Bool {
        guard snap.counter == insertCounter else { return false }
        try deleteAndRetype(expectedLength: snap.length, originalText: snap.text, newText: newText)
        return true
    }

    /// 修正／復原用（規格 §3.3）：先退掉指令話語本身（它已被串流上屏），
    /// 再把 session 全文換成 newText。AX 優先（帶校驗），mismatch 即中止，unsupported 退 keystroke。
    public func replaceSession(commandSnapshot: UtteranceSnapshot,
                               expectedSessionText: String,
                               with newText: String,
                               axAnchor: Int?) throws -> SessionReplaceOutcome {
        guard commandSnapshot.counter == insertCounter else { return .tailAdvanced }
        // AX 優先：把「session 全文＋緊隨其後的指令話語」視為單一範圍，一次驗證、一次替換成 newText，
        // 全程不發任何鍵盤事件——CGEvent（事件佇列）與 AX（mach port）是兩條通道，目標 App 忙碌時
        // 服務順序無保證：若混用，遲到的退格可能改吃剛替換完的新文字（終審 finding）。
        // mismatch 或兩步間變動一律中止（AX 動過欄位後不得再落 keystroke）；
        // 只有 unsupported（AX 從未動過欄位）才走 keystroke 全套。
        if let ax = rangeReplacer, let anchor = axAnchor {
            let combined = expectedSessionText + commandSnapshot.text
            switch ax.verifyRange(location: anchor, expected: combined) {
            case .mismatch:
                return .fieldMismatch
            case .unsupported:
                break   // 全程退 keystroke 路徑
            case .replaced:   // ＝驗證通過
                if ax.replaceVerifiedRange(location: anchor, expected: combined, with: newText) == .replaced {
                    insertCounter += 1
                    return .replaced
                }
                // 兩步間變動：AXInserter 失敗回滾只保證「嘗試」收攏游標，可能留下活選取；
                // 落 keystroke 會把活選取整段吃掉（M2 遺留債）。判 fieldMismatch，呼叫端凍結。
                return .fieldMismatch
            }
        }
        // keystroke 尾端路徑：退指令話語＋刪 session 全文＋重打
        if commandSnapshot.length > 0 {
            try keystroke.deleteBackward(count: commandSnapshot.length)
            insertCounter += 1
        }
        try deleteAndRetype(expectedLength: expectedSessionText.count,
                            originalText: expectedSessionText,
                            newText: newText)
        return .replaced
    }

    /// Esc：把本聽寫階段目前在欄位中的完整鏡像退回指定終點（issue #21）。
    /// AX 可用時整段校驗後一次替換；keystroke 路徑若終點是既有 prefix，只退多出的 suffix，
    /// 不把要保留的潤飾文字刪掉重打。非 prefix（例如恢復原選取）才走刪舊打新與既有回復鐵律。
    public func retractSession(expectedScreenText: String,
                               to retainedText: String,
                               axAnchor: Int?) throws -> SessionRetractionOutcome {
        guard expectedScreenText != retainedText else {
            currentUtteranceText = ""
            return .retracted
        }
        if let ax = rangeReplacer, let anchor = axAnchor {
            switch ax.verifyRange(location: anchor, expected: expectedScreenText) {
            case .unsupported:
                // session 起點曾可驗證、現在卻讀不到，代表 target/focus 已不可證；
                // 不得依過期 mirror 盲送整段 Backspace。只有一開始就沒有 AX anchor 才走 keystroke。
                return .fieldMismatch
            case .mismatch:
                return .fieldMismatch
            case .replaced:
                guard ax.replaceVerifiedRange(location: anchor, expected: expectedScreenText,
                                              with: retainedText) == .replaced else {
                    return .fieldMismatch
                }
                currentUtteranceText = ""
                insertCounter += 1
                return .retracted
            }
        }
        if expectedScreenText.hasPrefix(retainedText) {
            let suffix = expectedScreenText.dropFirst(retainedText.count)
            if !suffix.isEmpty {
                try keystroke.deleteBackward(count: suffix.count)
                insertCounter += 1
            }
        } else {
            try deleteAndRetype(expectedLength: expectedScreenText.count,
                                originalText: expectedScreenText,
                                newText: retainedText)
        }
        currentUtteranceText = ""
        return .retracted
    }

    /// 舊的 utterance 級 primitive；保留給直接單元測試與非 session 呼叫端。
    public func discardCurrentUtterance() throws {
        let count = currentUtteranceText.count
        if count > 0 {
            try keystroke.deleteBackward(count: count)
            currentUtteranceText = ""
            insertCounter += 1
        }
    }

    /// 刪舊打新＋鐵律回復。
    private func deleteAndRetype(expectedLength: Int, originalText: String, newText: String) throws {
        if expectedLength > 0 {
            try keystroke.deleteBackward(count: expectedLength)
        }
        do {
            try insertWithFallback(newText)
        } catch {
            // 鐵律：絕不清掉已上屏文字——補插失敗先救原文
            if (try? insertWithFallback(originalText)) != nil {
                insertCounter += 1
                throw InserterError.replaceFailedRestored
            }
            throw InserterError.lostText(originalText)
        }
        insertCounter += 1
    }

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
