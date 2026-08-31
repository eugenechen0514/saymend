import Testing
@testable import SaymendCore

final class RecordingInserter: TextInserter {
    enum Op: Equatable { case insert(String), delete(Int) }
    var ops: [Op] = []
    var failInsertsRemaining = 0
    var failDeletesRemaining = 0
    func insert(_ text: String) throws {
        if failInsertsRemaining > 0 { failInsertsRemaining -= 1; throw InserterError.postFailed }
        ops.append(.insert(text))
    }
    func deleteBackward(count: Int) throws {
        if failDeletesRemaining > 0 { failDeletesRemaining -= 1; throw InserterError.postFailed }
        ops.append(.delete(count))
    }
}

final class FakeRangeReplacer: SessionRangeReplacing {
    static let defaultFieldIdentity = defaultTestFieldIdentity
    var focusedFieldIdentity: FieldIdentity? = defaultFieldIdentity
    var verifyResult: RangeReplaceResult = .replaced
    var replaceResult: RangeReplaceResult = .replaced
    private(set) var verifyCalls: [(fieldIdentity: FieldIdentity, location: Int, expected: String)] = []
    private(set) var calls: [(fieldIdentity: FieldIdentity, location: Int, expected: String, new: String)] = []
    /// 保留游標的替換單獨記帳——與 calls 混在一起就無法斷言「走的是新路徑而非舊路徑」
    private(set) var preservingCaretCalls: [(fieldIdentity: FieldIdentity, location: Int,
                                              expected: String, new: String)] = []
    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult {
        verifyCalls.append((fieldIdentity, location, expected))
        if fieldIdentity != focusedFieldIdentity { return .mismatch }
        return verifyResult
    }
    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int,
                              expected: String, with newText: String) -> RangeReplaceResult {
        calls.append((fieldIdentity, location, expected, newText))
        if fieldIdentity != focusedFieldIdentity { return .mismatch }
        return replaceResult
    }
    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int,
                                             expected: String, with newText: String) -> RangeReplaceResult {
        preservingCaretCalls.append((fieldIdentity, location, expected, newText))
        if fieldIdentity != focusedFieldIdentity { return .mismatch }
        return replaceResult
    }
}

private func makeCoordinator() -> (InsertionCoordinator, RecordingInserter, RecordingInserter) {
    let key = RecordingInserter()
    let paste = RecordingInserter()
    return (InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6), key, paste)
}

@Test func shortTextUsesKeystrokeLongUsesPaste() throws {
    let (c, key, paste) = makeCoordinator()
    try c.insertFinalized("你好")            // 2 字 < 6 → keystroke
    try c.insertFinalized("這是一段很長的文字啊")  // ≥ 6 → paste
    #expect(key.ops == [.insert("你好")])
    #expect(paste.ops == [.insert("這是一段很長的文字啊")])
    #expect(c.currentUtteranceLength == 12)
}

@Test func insertFallsBackToOtherInserter() throws {
    let (c, key, paste) = makeCoordinator()
    key.failInsertsRemaining = 1
    try c.insertFinalized("嗨")               // keystroke 失敗 → 改用 paste
    #expect(paste.ops == [.insert("嗨")])
}

@Test func replaceTailDeletesGraphemesAndInserts() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("呃你好")            // 3 graphemes
    let snap = c.snapshotAndBeginNext()
    #expect(snap.length == 3)
    let ok = try c.replaceTail(snap, with: "你好。")
    #expect(ok)
    #expect(key.ops == [.insert("呃你好"), .delete(3), .insert("你好。")])
}

@Test func replaceTailAbortsWhenTailAdvanced() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")            // 尾端前進
    let ok = try c.replaceTail(snap, with: "第一段。")
    #expect(!ok)
    #expect(!key.ops.contains(.delete(3)))    // 不得退格
}

@Test func emojiCountsAsSingleGrapheme() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("👨‍👩‍👧‍👦好")            // 2 graphemes
    let snap = c.snapshotAndBeginNext()
    _ = try c.replaceTail(snap, with: "好")
    #expect(key.ops.contains(.delete(2)))
}

@Test func crossFragmentComposedGraphemeCountsOnce() throws {
    // 跨片段組字：e + 組合重音符 分兩批抵達，欄位裡已合成 é（1 個字位，退格一次全刪）
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("e")
    try c.insertFinalized("\u{301}")
    #expect(c.currentUtteranceLength == 1)   // 以串接後字串計數，不是片段各自加總
    try c.discardCurrentUtterance()
    #expect(key.ops.last == .delete(1))
}

@Test func discardDeletesCurrentUtterance() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("嗨嗨")
    try c.discardCurrentUtterance()
    #expect(key.ops == [.insert("嗨嗨"), .delete(2)])
    #expect(c.currentUtteranceLength == 0)
}

@Test func retractSessionWithoutAXFailsClosedEvenForSuffix() {
    let (c, key, paste) = makeCoordinator()
    let outcome = c.retractSession(expectedScreenText: "保留。👨‍👩‍👧‍👦",
                                   to: "保留。", axAnchor: nil, fieldIdentity: nil)
    #expect(outcome == .fieldMismatch)
    #expect(key.ops.isEmpty && paste.ops.isEmpty) // whole-session Esc 不因「只是 suffix」例外盲退
}

@Test func retractSessionUsesOneVerifiedAXReplacement() throws {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "本階段全文", to: "", axAnchor: 42,
                                       fieldIdentity: FakeRangeReplacer.defaultFieldIdentity)
    #expect(outcome == .retracted)
    #expect(ax.verifyCalls.count == 1 && ax.calls.count == 1)
    #expect(ax.verifyCalls[0].location == 42 && ax.verifyCalls[0].expected == "本階段全文")
    #expect(ax.calls[0].location == 42 && ax.calls[0].expected == "本階段全文" && ax.calls[0].new == "")
    #expect(key.ops.isEmpty)                       // AX 與 keystroke 不混用
}

@Test func retractSessionFailsClosedWhenPreviouslyAvailableAXBecomesUnsupported() throws {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    ax.verifyResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "保留。尾巴", to: "保留。", axAnchor: 7,
                                       fieldIdentity: FakeRangeReplacer.defaultFieldIdentity)
    #expect(outcome == .fieldMismatch)
    #expect(ax.calls.isEmpty)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)  // 起點曾有 AX、現在不可驗證：不得盲退 wrong field
}

@Test func retractSessionStopsAfterAXSecondStepFailure() throws {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    ax.replaceResult = .mismatch
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "本階段", to: "", axAnchor: 7,
                                       fieldIdentity: FakeRangeReplacer.defaultFieldIdentity)
    #expect(outcome == .fieldMismatch)
    #expect(ax.calls.count == 1)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)   // AX 可能留活選取，禁止 keystroke 收尾
}

@Test func retractSessionWithoutAXFailsClosedForNonPrefixBaseline() {
    let (c, key, paste) = makeCoordinator()
    let outcome = c.retractSession(expectedScreenText: "改寫後", to: "原選取",
                                   axAnchor: nil, fieldIdentity: nil)
    #expect(outcome == .fieldMismatch)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func retractSessionMissingIdentityFailsClosed() {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "原始好。", to: "好。",
                                   axAnchor: 0, fieldIdentity: nil)
    #expect(outcome == .fieldMismatch)
    #expect(ax.verifyCalls.isEmpty && key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func retractSessionMissingAnchorFailsClosed() {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "原始好。", to: "好。", axAnchor: nil,
                                   fieldIdentity: FakeRangeReplacer.defaultFieldIdentity)
    #expect(outcome == .fieldMismatch)
    #expect(ax.verifyCalls.isEmpty && key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func retractSessionStopsWhenAXTextNoLongerMatches() throws {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    ax.verifyResult = .mismatch
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.retractSession(expectedScreenText: "程式以為的全文", to: "", axAnchor: 7,
                                       fieldIdentity: FakeRangeReplacer.defaultFieldIdentity)
    #expect(outcome == .fieldMismatch)
    #expect(ax.calls.isEmpty && key.ops.isEmpty && paste.ops.isEmpty) // 使用者外改後分毫不碰
}

@Test func chunkerRespectsGraphemesAndUTF16Limit() {
    let chunks = TypingChunker.chunks(of: "a👨‍👩‍👧‍👦b中文def", maxUTF16: 12)
    #expect(chunks.joined() == "a👨‍👩‍👧‍👦b中文def")
    for ch in chunks { #expect(ch.utf16.count <= 12) }
    // 👨‍👩‍👧‍👦 佔 11 個 UTF-16 unit，必須完整落在同一塊
    #expect(chunks.contains(where: { $0.contains("👨‍👩‍👧‍👦") }))
}

@Test func snapshotCarriesText() throws {
    let (c, _, _) = makeCoordinator()
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(snap.text == "呃你好")
    #expect(snap.length == 3)
}

@Test func replaceSessionKeystrokePath() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("欸改一下")                       // 指令話語已上屏（4 字）
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊全文", with: "新全文。", axAnchor: nil)
    #expect(out == .replaced)
    #expect(key.ops == [.insert("欸改一下"), .delete(4), .delete(3), .insert("新全文。")])
}

@Test func replaceSessionPrefersAXWhenAvailable() throws {
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer()                            // 預設 verify／replace 皆 .replaced
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 6)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 42,
                                   fieldIdentity: defaultTestFieldIdentity)
    #expect(out == .replaced)
    #expect(ax.verifyCalls.count == 1)                      // 先驗證
    #expect(ax.calls.count == 1)                            // 再替換
    #expect(ax.calls[0].location == 42)
    #expect(ax.calls[0].expected == "舊文指令")              // session＋指令話語合併為單一範圍
    #expect(key.ops == [.insert("指令")])                   // 全程零鍵盤事件（跨通道競態消滅）
}

@Test func replaceSessionKeystrokeFailureRestoresOriginal() throws {
    let (c, key, paste) = makeCoordinator()
    try c.insertFinalized("改一下")
    let command = c.snapshotAndBeginNext()
    key.failInsertsRemaining = 1
    paste.failInsertsRemaining = 1

    #expect(throws: InserterError.replaceFailedRestored) {
        _ = try c.replaceSession(commandSnapshot: command, expectedSessionText: "首句。",
                                 with: "首句改。", axAnchor: nil)
    }
    #expect(key.ops == [.insert("改一下"), .delete(3), .delete(3), .insert("首句。")])
}

@Test func replaceSessionAXMismatchAborts() throws {
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .mismatch
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 6)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 42,
                                   fieldIdentity: defaultTestFieldIdentity)
    #expect(out == .fieldMismatch)                          // 欄位被外力改過：不得亂改
    #expect(key.ops == [.insert("指令")])                   // mismatch 時分毫未動（連指令話語都不退）
    #expect(!key.ops.contains(.insert("新文")))
}

@Test func replaceSessionWithoutIdentityKeepsLegacyKeystrokeFallback() throws {
    // 低階 API 相容性；production controller 的 session-bound call 一律帶 identity 並 fail closed。
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 1)
    #expect(out == .replaced)
    #expect(key.ops == [.insert("指令"), .delete(2), .delete(2), .insert("新文")])
}

@Test func replaceSessionAXSecondStepFailureFreezes() throws {
    // verify 過了、替換那步卻失敗（兩步之間狀況變了）：AX 可能留下活選取，
    // keystroke 收尾會把選取吃掉（M2 遺留債修復）→ 判 fieldMismatch，呼叫端凍結
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .replaced; ax.replaceResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 1,
                                   fieldIdentity: defaultTestFieldIdentity)
    #expect(out == .fieldMismatch)
    #expect(key.ops == [.insert("指令")])                   // 除最初插入外，零 keystroke 收尾
}

@Test func replaceSessionTailAdvancedAborts() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("下一段")                          // 尾端前進
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊", with: "新", axAnchor: nil)
    #expect(out == .tailAdvanced)
    #expect(!key.ops.contains(.insert("新")))
}

@Test func replaceTailRestoresOriginalWhenInsertFails() throws {
    let (c, key, paste) = makeCoordinator()
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    key.failInsertsRemaining = 1                             // 新文字：keystroke 失敗
    paste.failInsertsRemaining = 1                           //          paste 也失敗
    #expect(throws: InserterError.replaceFailedRestored) {
        _ = try c.replaceTail(snap, with: "你好。")
    }
    #expect(key.ops.last == .insert("呃你好"))               // 原文已回復（鐵律）
}

@Test func replaceTailLostTextWhenRestoreAlsoFails() throws {
    let (c, key, paste) = makeCoordinator()
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    key.failInsertsRemaining = 2                             // 新文字＋回復 都失敗
    paste.failInsertsRemaining = 2
    #expect(throws: InserterError.lostText("呃你好")) {
        _ = try c.replaceTail(snap, with: "你好。")
    }
}

@Test func fieldContextHasSelectionRequiresNonEmptyRangeAndText() {
    #expect(!FieldContext().hasSelection)
    #expect(!FieldContext(selectedRange: .init(location: 3, length: 0), selectedText: "").hasSelection)
    #expect(!FieldContext(selectedRange: .init(location: 3, length: 2), selectedText: nil).hasSelection)
    #expect(FieldContext(selectedRange: .init(location: 3, length: 2), selectedText: "嗨嗨").hasSelection)
}

@Test func accumulateFinalizedBuffersWithoutInserting() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste)
    c.accumulateFinalized("欸改")
    c.accumulateFinalized("正式一點")
    #expect(key.ops.isEmpty && paste.ops.isEmpty)      // 一個鍵盤事件都不准有
    #expect(c.currentUtteranceLength == "欸改正式一點".count)
    let snap = c.snapshotAndBeginNext()
    #expect(snap.text == "欸改正式一點")
}

@Test func clearCurrentUtteranceEmitsNoKeyboardEvents() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste)
    c.accumulateFinalized("要丟棄的話")
    c.clearCurrentUtterance()
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
    #expect(c.currentUtteranceLength == 0)
}

@Test func replaceSelectionHappyPathUsesAXOnly() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let outcome = c.replaceSelection(location: 7, expected: "原選取", with: "改寫後",
                                     fieldIdentity: defaultTestFieldIdentity)
    #expect(outcome == .replaced)
    #expect(ax.calls.count == 1)
    #expect(ax.calls[0].location == 7 && ax.calls[0].expected == "原選取" && ax.calls[0].new == "改寫後")
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func replaceSelectionMismatchAbandonsWithoutTouchingField() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.verifyResult = .mismatch                        // 選取已變
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    #expect(c.replaceSelection(location: 7, expected: "原選取", with: "改寫後",
                               fieldIdentity: defaultTestFieldIdentity) == .selectionChanged)
    #expect(ax.calls.isEmpty && key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func replaceSelectionWithoutAXIsUnsupported() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: nil)
    #expect(c.replaceSelection(location: 0, expected: "x", with: "y") == .unsupported)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func replaceSelectionPartialFailureDoesNotFallBackToKeystroke() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.replaceResult = .mismatch                       // verify 過、replace 失敗（兩步間變動）
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    #expect(c.replaceSelection(location: 7, expected: "原選取", with: "改寫後",
                               fieldIdentity: defaultTestFieldIdentity) == .selectionChanged)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)      // AX 可能留下活選取，keystroke 會把它吃掉
}

@Test func replaceSelectionAdvancesCounter() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    let snapBefore = c.snapshotAndBeginNext()          // counter 快照
    _ = c.replaceSelection(location: 0, expected: "a", with: "b",
                           fieldIdentity: defaultTestFieldIdentity)
    #expect(try c.replaceTail(snapBefore, with: "x") == false)   // 尾端已前進
}

@Test func insertDetachedDoesNotTouchUtteranceLedger() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste)
    try c.insertDetached("直接上屏")
    #expect(key.ops == [.insert("直接上屏")])
    #expect(c.currentUtteranceLength == 0)             // 不掛 utterance 帳本
}

@Test func currentTailSnapshotIsLiveAndSideEffectFree() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste)
    c.accumulateFinalized("進行中")
    let stale = c.currentTailSnapshot()
    #expect(stale.text.isEmpty)
    #expect(c.currentUtteranceLength == "進行中".count)     // 零副作用：不偷正在累積的緩衝
    try c.insertDetached("x")                              // counter 前進
    #expect(try c.replaceTail(stale, with: "y") == false)  // 舊快照自然過期
    let fresh = c.currentTailSnapshot()                    // 現時 counter：立即可用於 replaceSession
    #expect(try c.replaceSession(commandSnapshot: fresh, expectedSessionText: "x",
                                 with: "z", axAnchor: nil) == .replaced)
}

// M2 遺留債：replaceSession 的 AX 驗證通過→替換失敗（兩步間變動）原本落 keystroke 全套；
// 但 AXInserter 失敗時可能已設下活選取，keystroke 退格／鍵入會把選取整段吃掉——改判 fieldMismatch。
@Test func replaceSessionAXPartialFailureFreezesInsteadOfKeystroke() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.replaceResult = .mismatch
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let outcome = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "全文",
                                       with: "新全文", axAnchor: 0,
                                       fieldIdentity: defaultTestFieldIdentity)
    #expect(outcome == .fieldMismatch)
    #expect(key.ops == [.insert("指令")])              // 除最初插入外，零 keystroke 收尾
}

// MARK: - 回收晚到的潤飾（M10-C #7）
// 前一句已不在尾端（後面接了下一句），退格重打會吃掉後面那句的字。
// 改以絕對範圍帶校驗替換，並保留游標。

@Test func staleTailIsRecoveredInPlace() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")                     // 尾端前進 → 正常 replaceTail 已不可用
    #expect(try !c.replaceTail(snap, with: "第一段。"))   // 前提：確實走不了快路徑

    let outcome = c.replaceStaleTail(snap, at: 40, with: "第一段。",
                                     fieldIdentity: defaultTestFieldIdentity)
    #expect(outcome == .replaced)
    #expect(ax.preservingCaretCalls.count == 1)
    #expect(ax.preservingCaretCalls[0].location == 40)
    #expect(ax.preservingCaretCalls[0].expected == "第一段")
    #expect(ax.preservingCaretCalls[0].new == "第一段。")
    #expect(ax.calls.isEmpty)                           // 不得走會把游標收到中段的舊路徑
    #expect(key.ops == [.insert("第一段"), .insert("第二段")])   // 零退格：後面那句不能被動到
}

@Test func staleTailAbortsWhenFieldChangedUnderneath() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.verifyResult = .mismatch                          // 使用者中途手改了該句
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()

    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。",
                               fieldIdentity: defaultTestFieldIdentity) == .mismatch)
    #expect(ax.preservingCaretCalls.isEmpty)             // 鐵律：校驗不過就一個字都不准寫
}

@Test func staleTailUnsupportedWithoutRangeReplacer() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: nil)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .unsupported)
}

@Test func staleTailAbortsWhenReplaceFailsBetweenTheTwoSteps() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.replaceResult = .mismatch                         // 校驗通過但兩步之間變動
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。",
                               fieldIdentity: defaultTestFieldIdentity) == .mismatch)
}

@Test func staleTailRejectsEmptySnapshotWithoutTouchingTheField() throws {
    // 零長度快照沒有可校驗的錨——那樣的「替換」等於在算出來的位置盲插
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    let empty = c.currentTailSnapshot()                  // text 為空、counter 為現值
    #expect(empty.text.isEmpty)

    #expect(c.replaceStaleTail(empty, at: 40, with: "憑空出現的字",
                               fieldIdentity: defaultTestFieldIdentity) == .mismatch)
    #expect(ax.verifyCalls.isEmpty)                      // 連校驗都不該發出
    #expect(ax.preservingCaretCalls.isEmpty)
}

@Test func staleTailReportsUnsupportedWhenAXCannotReadTheField() throws {
    // 與「欄位被外力改動」不同的成因：AX 根本讀不到欄位。兩者對呼叫端的表面行為一樣，
    // 但語意不同，分類錯了不該沒人發現。
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    ax.verifyResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()

    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。",
                               fieldIdentity: defaultTestFieldIdentity) == .unsupported)
    #expect(ax.preservingCaretCalls.isEmpty)
}

@Test func staleTailRecoveryDoesNotAdvanceTheCounter() throws {
    // counter 的語意是「尾端是否前進」。中段改寫沒有改變誰是尾端——
    // 若遞增，下一句自己的快照會對不上，被迫也走慢路徑（其實它仍在尾端）。
    let key = RecordingInserter(), paste = RecordingInserter()
    let ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("第一段")
    let first = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")
    let second = c.snapshotAndBeginNext()                // 第二段仍在尾端

    #expect(c.replaceStaleTail(first, at: 40, with: "第一段。",
                               fieldIdentity: defaultTestFieldIdentity) == .replaced)

    // 回收完第一段之後，第二段照樣要能走正常的尾端路徑
    #expect(try c.replaceTail(second, with: "第二段。"))
    #expect(key.ops.contains(.delete(3)))                // 走的是退格重打＝快路徑仍成立
}

// MARK: - 備援診斷（issue #1 蒐證）
// 主 inserter 失敗、備援救回＝控制流無異狀、帳面成功，過去什麼都不留。
// 這正是 issue #1「replaceTail 偶發落地失敗」兩個候選 trigger 之一（另一個 counter-mismatch
// 已由 M7 的 insertSkipped/counterMismatch 覆蓋）。

@Test func fallbackToSecondaryInserterIsObservable() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6)
    var seen: [InsertionCoordinator.InserterFallback] = []
    c.onInserterFallback = { seen.append($0) }

    paste.failInsertsRemaining = 1
    try c.insertFinalized("這是一段很長的文字啊")        // ≥6 → 主 paste 失敗、退 keystroke
    #expect(seen == [.pasteToKeystroke])

    key.failInsertsRemaining = 1
    try c.insertFinalized("嗨")                        // <6 → 主 keystroke 失敗、退 paste
    #expect(seen == [.pasteToKeystroke, .keystrokeToPaste])
}

@Test func noFallbackEventWhenPrimarySucceeds() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6)
    var seen: [InsertionCoordinator.InserterFallback] = []
    c.onInserterFallback = { seen.append($0) }

    try c.insertFinalized("嗨")
    try c.insertFinalized("這是一段很長的文字啊")
    #expect(seen.isEmpty)
}

@Test func noFallbackEventWhenBothInsertersFail() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6)
    var seen: [InsertionCoordinator.InserterFallback] = []
    c.onInserterFallback = { seen.append($0) }

    paste.failInsertsRemaining = 1
    key.failInsertsRemaining = 1
    #expect(throws: InserterError.self) { try c.insertFinalized("這是一段很長的文字啊") }
    // 兩邊都倒＝真失敗，走既有 insertFailed 路徑；不得再報「已用備援救回」
    #expect(seen.isEmpty)
}

@Test func fallbackDuringReplaceTailIsObservable() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6)
    var seen: [InsertionCoordinator.InserterFallback] = []
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    c.onInserterFallback = { seen.append($0) }        // 只觀察替換階段

    paste.failInsertsRemaining = 1
    let ok = try c.replaceTail(snap, with: "這是潤飾後的長句子")   // ≥6 → paste 先試
    #expect(ok)
    #expect(seen == [.pasteToKeystroke])              // 落地成功，但走的是備援
}
