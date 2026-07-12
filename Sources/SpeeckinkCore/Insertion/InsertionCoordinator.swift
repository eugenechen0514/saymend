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

    private let keystroke: any TextInserter
    private let paste: any TextInserter
    private let rangeReplacer: (any SessionRangeReplacing)?
    private let pasteThreshold: Int

    private var currentUtteranceText = ""
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
        // AX 優先，且「先驗證、再退指令、最後替換」的三步順序：
        // (1) verify 不動手 → mismatch 時欄位分毫未動；
        // (2) keystroke 退掉尾端的指令話語（此刻游標仍在欄位末端，退格刪的就是指令）；
        // (3) AX 範圍替換 session——替換後游標落在新文字之後＝欄位末端，狀態乾淨。
        // 若先替換再退指令，AX 會把游標留在新 session 與指令話語之間，退格就會刪錯字。
        if let ax = rangeReplacer, let anchor = axAnchor {
            switch ax.verifyRange(location: anchor, expected: expectedSessionText) {
            case .mismatch:
                return .fieldMismatch
            case .unsupported:
                break   // 全程退 keystroke 路徑
            case .replaced:   // ＝驗證通過
                if commandSnapshot.length > 0 {
                    try keystroke.deleteBackward(count: commandSnapshot.length)
                }
                switch ax.replaceVerifiedRange(location: anchor, expected: expectedSessionText, with: newText) {
                case .replaced:
                    insertCounter += 1
                    return .replaced
                case .mismatch, .unsupported:
                    // 罕見：兩步之間狀況變了；指令已退掉、session 仍是尾端 → keystroke 補完
                    try deleteAndRetype(expectedLength: expectedSessionText.count,
                                        originalText: expectedSessionText,
                                        newText: newText)
                    return .replaced
                }
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

    /// Esc：退格清掉目前 utterance 已上屏的文字。
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
        let primary: any TextInserter = text.count >= pasteThreshold ? paste : keystroke
        let secondary: any TextInserter = text.count >= pasteThreshold ? keystroke : paste
        do {
            try primary.insert(text)
        } catch {
            try secondary.insert(text)
        }
    }
}
