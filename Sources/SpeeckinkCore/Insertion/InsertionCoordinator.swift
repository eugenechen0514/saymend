/// 插入協調器：選擇 inserter（短句鍵入、長句貼上）、記錄 utterance 帳本、
/// 提供「尾端替換」與「丟棄」（規格 §3.2／§3.7；M1 簡化：僅尾端可替換）。
public final class InsertionCoordinator {
    public struct UtteranceSnapshot: Equatable {
        public let length: Int   // grapheme cluster 數（＝退格次數）
        public let counter: Int  // 快照當下的插入計數，用來偵測尾端是否前進
    }

    private let keystroke: any TextInserter
    private let paste: any TextInserter
    private let pasteThreshold: Int

    /// 目前 utterance 已上屏的「串接後」文字。長度一律以串接後字串的 grapheme cluster 數計，
    /// 避免跨片段組字（combining mark、ZWJ emoji 分批抵達）造成退格數與實際字位不符。
    private var currentUtteranceText = ""
    public var currentUtteranceLength: Int { currentUtteranceText.count }
    private var insertCounter = 0

    public init(keystroke: any TextInserter, paste: any TextInserter, pasteThreshold: Int = 12) {
        self.keystroke = keystroke
        self.paste = paste
        self.pasteThreshold = pasteThreshold
    }

    public func reset() {
        currentUtteranceText = ""
    }

    /// finalized 片段上屏。主 inserter 失敗時換另一個（規格 §5.2 逐層降級的 M1 版）。
    public func insertFinalized(_ text: String) throws {
        guard !text.isEmpty else { return }
        try insertWithFallback(text)
        currentUtteranceText += text
        insertCounter += 1
    }

    /// 關閉目前 utterance 帳本並開新的；回傳舊帳本快照供潤飾替換用。
    public func snapshotAndBeginNext() -> UtteranceSnapshot {
        let snap = UtteranceSnapshot(length: currentUtteranceText.count, counter: insertCounter)
        currentUtteranceText = ""
        return snap
    }

    /// 以潤飾後文字替換快照的 utterance。僅當尾端未前進（counter 未變）才執行。
    public func replaceTail(_ snap: UtteranceSnapshot, with newText: String) throws -> Bool {
        guard snap.counter == insertCounter else { return false }
        if snap.length > 0 {
            try keystroke.deleteBackward(count: snap.length)
        }
        try insertWithFallback(newText)
        insertCounter += 1
        return true
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
