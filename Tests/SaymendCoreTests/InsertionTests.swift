import Testing
@testable import SaymendCore

/// 只記錄插入。issue #44 起 TextInserter 沒有退格——欄位上任何刪字都走 SessionRangeReplacing 的 verified AX，
/// 所以這個 fake 也不可能記到 `.delete`；「有沒有盲退格」變成型別層面的不可能，不再需要測。
final class RecordingInserter: TextInserter {
    enum Op: Equatable { case insert(String) }
    var ops: [Op] = []
    var failInsertsRemaining = 0
    func insert(_ text: String) throws {
        if failInsertsRemaining > 0 { failInsertsRemaining -= 1; throw InserterError.postFailed }
        ops.append(.insert(text))
    }
}

final class FakeRangeReplacer: SessionRangeReplacing {
    var verifyResult: RangeReplaceResult = .replaced
    var replaceResult: RangeReplaceResult = .replaced
    private(set) var verifyCalls: [(identity: FieldIdentity, location: Int, expected: String)] = []
    private(set) var calls: [(identity: FieldIdentity, location: Int, expected: String, new: String)] = []
    /// 保留游標的替換單獨記帳——與 calls 混在一起就無法斷言「走的是新路徑而非舊路徑」
    private(set) var preservingCaretCalls: [(identity: FieldIdentity, location: Int, expected: String, new: String)] = []
    func verifyRange(fieldIdentity: FieldIdentity, location: Int, expected: String) -> RangeReplaceResult {
        verifyCalls.append((fieldIdentity, location, expected))
        return verifyResult
    }
    func replaceVerifiedRange(fieldIdentity: FieldIdentity, location: Int, expected: String,
                              with newText: String) -> RangeReplaceResult {
        calls.append((fieldIdentity, location, expected, newText))
        return replaceResult
    }
    func replaceVerifiedRangePreservingCaret(fieldIdentity: FieldIdentity, location: Int, expected: String,
                                             with newText: String) -> RangeReplaceResult {
        preservingCaretCalls.append((fieldIdentity, location, expected, newText))
        return replaceResult
    }
}

/// 無 AX 的協調器：只能追加
private func makeCoordinator() -> (InsertionCoordinator, RecordingInserter, RecordingInserter) {
    let key = RecordingInserter()
    let paste = RecordingInserter()
    return (InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 6), key, paste)
}

private let sessionIdentity = FieldIdentity(token: 1)

/// 有 AX、已 begin 的協調器：anchor 與 identity 齊備，會刪字的操作才走得通
private func makeAXCoordinator(anchor: Int? = 0, identity: FieldIdentity? = sessionIdentity,
                               initialText: String = "", pasteThreshold: Int = 100)
    -> (InsertionCoordinator, RecordingInserter, RecordingInserter, FakeRangeReplacer) {
    let key = RecordingInserter(), paste = RecordingInserter(), ax = FakeRangeReplacer()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: pasteThreshold)
    c.beginSession(anchor: anchor, identity: identity, initialText: initialText)
    return (c, key, paste, ax)
}

// MARK: - 純追加：與 AX 無關，永遠照常

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

@Test func appendWorksWithoutAnySessionOrAX() throws {
    // issue #21 的裁定：純追加的上屏永遠不得因缺 AX／identity 而停——這條是 PR #36 被否決的原因
    let (c, key, _) = makeCoordinator()
    try c.insertFinalized("沒有 AX")
    try c.insertDetached("也能寫")
    #expect(key.ops == [.insert("沒有 AX"), .insert("也能寫")])
    #expect(c.displayedText == "沒有 AX也能寫")
}

@Test func snapshotCarriesText() throws {
    let (c, _, _) = makeCoordinator()
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(snap.text == "呃你好")
    #expect(snap.length == 3)
}

@Test func chunkerRespectsGraphemesAndUTF16Limit() {
    let chunks = TypingChunker.chunks(of: "a👨‍👩‍👧‍👦b中文def", maxUTF16: 12)
    #expect(chunks.joined() == "a👨‍👩‍👧‍👦b中文def")
    for ch in chunks { #expect(ch.utf16.count <= 12) }
    // 👨‍👩‍👧‍👦 佔 11 個 UTF-16 unit，必須完整落在同一塊
    #expect(chunks.contains(where: { $0.contains("👨‍👩‍👧‍👦") }))
}

@Test func crossFragmentComposedGraphemeCountsOnceButMirrorKeepsUTF16() throws {
    // 跨片段組字：e + 組合重音符 分兩批抵達，欄位裡已合成 é（1 個字位）；
    // 帳本以字位計、鏡像以原始 UTF-16 保留——AX 範圍替換要的是後者
    let (c, _, _, ax) = makeAXCoordinator(anchor: 7)
    try c.insertFinalized("e")
    try c.insertFinalized("\u{301}")
    #expect(c.currentUtteranceLength == 1)   // 以串接後字串計數，不是片段各自加總
    #expect(c.retractSession() == .replaced)
    #expect(ax.calls.count == 1)
    #expect(ax.calls.first?.location == 7 && ax.calls.first?.expected == "e\u{301}" && ax.calls.first?.new == "")
}

// MARK: - 鏡像（displayedText）：本 session 從 anchor 起實際寫在欄位上的文字

@Test func beginSessionSeedsMirrorWithInitialTextAndEndClearsIt() throws {
    let (c, _, _, _) = makeAXCoordinator(anchor: 3, initialText: "原選取")
    #expect(c.displayedText == "原選取")
    try c.insertDetached("後續")
    #expect(c.displayedText == "原選取後續")
    c.endSession()
    #expect(c.displayedText == "")
    #expect(c.currentUtteranceLength == 0)
}

@Test func resetKeepsMirrorForLingerResume() throws {
    // 延續窗 resume 會呼叫 reset()：同一 session，鏡像與 anchor 都不能被清
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0)
    try c.insertFinalized("第一句")
    _ = c.snapshotAndBeginNext()
    c.reset()
    #expect(c.displayedText == "第一句")
    #expect(c.retractSession() == .replaced)
    #expect(ax.calls.first?.expected == "第一句")
}

@Test func mirrorIncludesTextWhosePolishIsStillInFlight() throws {
    // issue #21 的 1.5 秒窗口：話語閉合（snapshotAndBeginNext）後 currentUtteranceText 歸零，
    // 但字還在欄位上、潤飾還沒回來——鏡像必須仍包含它，Esc 才退得掉
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0)
    try c.insertFinalized("已經落地的字")
    _ = c.snapshotAndBeginNext()               // 潤飾在途
    try c.insertFinalized("下一句")
    #expect(c.currentUtteranceLength == 3)
    #expect(c.displayedText == "已經落地的字下一句")
    #expect(c.retractSession() == .replaced)
    #expect(ax.calls.first?.expected == "已經落地的字下一句")
}

// MARK: - retractSession（Esc）：整段退回 initialText，verified AX 專屬

@Test func retractSessionReplacesWholeMirrorWithEmptyForTailSession() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 5)
    try c.insertFinalized("嗨嗨")
    _ = c.snapshotAndBeginNext()
    try c.insertFinalized("第二句")
    let stale = c.currentTailSnapshot()
    #expect(c.retractSession() == .replaced)
    #expect(ax.verifyCalls.count == 1 && ax.calls.count == 1)
    #expect(ax.calls.first?.identity == sessionIdentity)
    #expect(ax.calls.first?.location == 5 && ax.calls.first?.expected == "嗨嗨第二句" && ax.calls.first?.new == "")
    #expect(key.ops == [.insert("嗨嗨"), .insert("第二句")])     // 零鍵盤事件
    #expect(c.displayedText == "")
    #expect(c.currentUtteranceLength == 0)
    #expect(c.replaceTail(stale, with: "x") == .tailAdvanced)   // counter 前進
}

@Test func retractSessionRestoresInitialTextForSelectionSession() throws {
    // 選取即目標：Esc 要把使用者的原選取還回去，不是刪成空
    let (c, _, _, ax) = makeAXCoordinator(anchor: 3, initialText: "原選取")
    #expect(c.replaceSelection(location: 3, expected: "原選取", with: "改寫後") == .replaced)
    #expect(c.displayedText == "改寫後")
    #expect(c.retractSession() == .replaced)
    #expect(ax.calls.last?.location == 3 && ax.calls.last?.expected == "改寫後" && ax.calls.last?.new == "原選取")
    #expect(c.displayedText == "原選取")
}

@Test func retractSessionWithNothingWrittenIsQuietNoOp() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0)
    #expect(c.retractSession() == .replaced)
    #expect(ax.verifyCalls.isEmpty && ax.calls.isEmpty)
    let (s, _, _, ax2) = makeAXCoordinator(anchor: 3, initialText: "原選取")
    #expect(s.retractSession() == .replaced)               // 選取尚未被替換：欄位就是 initialText
    #expect(ax2.verifyCalls.isEmpty)
}

@Test func retractSessionWithoutIdentityIsUnverifiedAndTouchesNothing() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 0, identity: nil)
    try c.insertFinalized("字")
    #expect(c.retractSession() == .unverified)
    #expect(ax.verifyCalls.isEmpty)
    #expect(key.ops == [.insert("字")])
    #expect(c.displayedText == "字")                       // 什麼都沒動：鏡像照舊
}

@Test func retractSessionWithoutAnchorIsUnverified() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: nil)
    try c.insertFinalized("字")
    #expect(c.retractSession() == .unverified)
    #expect(ax.verifyCalls.isEmpty)
}

@Test func retractSessionWithoutRangeReplacerIsUnverified() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: nil)
    c.beginSession(anchor: 0, identity: sessionIdentity)
    try c.insertFinalized("字")
    #expect(c.retractSession() == .unverified)
    #expect(key.ops == [.insert("字")])
}

@Test func retractSessionMismatchIsFieldMismatchAndTouchesNothing() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0)
    ax.verifyResult = .mismatch                             // 焦點已到別的欄位，或內容被改
    try c.insertFinalized("字")
    #expect(c.retractSession() == .fieldMismatch)
    #expect(ax.calls.isEmpty)
    #expect(c.displayedText == "字")
}

@Test func retractSessionSecondStepFailureIsFieldMismatch() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0)
    ax.replaceResult = .mismatch                            // verify 過、replace 失敗（兩步之間變動）
    try c.insertFinalized("字")
    #expect(c.retractSession() == .fieldMismatch)
    #expect(c.displayedText == "字")                       // 鏡像不得樂觀更新
}

// MARK: - replaceTail（潤飾）：verified AX 範圍＝鏡像尾端

@Test func replaceTailAcrossUtteranceCombiningMarkUsesUTF16Boundary() throws {
    // 前一句尾是 "e"、下一句只有組合重音符：欄位上合成一個字位 é，但兩者屬不同 utterance。
    // 字位語意的 hasSuffix 會說鏡像「不以 \u{301} 結尾」而誤判 mismatch；UTF-16 比對才對得上 AX 的範圍。
    let (c, _, _, ax) = makeAXCoordinator(anchor: 10)
    try c.insertFinalized("e")
    _ = c.snapshotAndBeginNext()                              // 第一句潤飾在途
    try c.insertFinalized("\u{301}")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceTail(snap, with: "\u{301}!") == .replaced)
    #expect(ax.calls.first?.location == 11 && ax.calls.first?.expected == "\u{301}")
    #expect(Array(c.displayedText.utf16) == Array("e\u{301}!".utf16))
}

@Test func replaceTailUsesVerifiedAXRangeAtMirrorTail() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 10)
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceTail(snap, with: "你好。") == .replaced)
    #expect(ax.verifyCalls.count == 1)
    #expect(ax.calls.count == 1)
    #expect(ax.calls.first?.location == 10 && ax.calls.first?.expected == "呃你好" && ax.calls.first?.new == "你好。")
    #expect(key.ops == [.insert("呃你好")])                  // 零退格、零重打
    #expect(c.displayedText == "你好。")
}

@Test func replaceTailLocatesTailInUTF16UnitsAfterEarlierText() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 10)
    try c.insertFinalized("前綴")                            // 2 UTF-16
    _ = c.snapshotAndBeginNext()
    try c.insertFinalized("👨‍👩‍👧‍👦好")                       // 11 + 1 = 12 UTF-16，2 個字位
    let snap = c.snapshotAndBeginNext()
    #expect(snap.length == 2)
    #expect(c.replaceTail(snap, with: "好") == .replaced)
    #expect(ax.calls.first?.location == 12, "anchor 10 + 鏡像 14 − 快照 12")
    #expect(ax.calls.first?.expected == "👨‍👩‍👧‍👦好")
    #expect(c.displayedText == "前綴好")
}

@Test func replaceTailAbortsWhenTailAdvanced() throws {
    let (c, _, _, ax) = makeAXCoordinator()
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")            // 尾端前進
    #expect(c.replaceTail(snap, with: "第一段。") == .tailAdvanced)
    #expect(ax.verifyCalls.isEmpty)           // 連驗證都不發：快照已知過期
    #expect(c.displayedText == "第一段第二段")
}

@Test func replaceTailWithoutIdentityIsUnverifiedAndKeepsRawOnScreen() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 0, identity: nil)
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceTail(snap, with: "你好。") == .unverified)
    #expect(ax.verifyCalls.isEmpty)
    #expect(key.ops == [.insert("呃你好")])
    #expect(c.displayedText == "呃你好")
}

@Test func replaceTailWithoutAXCapabilityIsUnverified() throws {
    let (c, _, _, ax) = makeAXCoordinator()
    ax.verifyResult = .unsupported                          // App 不支援 AX 讀寫
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceTail(snap, with: "你好。") == .unverified)
    #expect(ax.calls.isEmpty)
}

@Test func replaceTailMismatchIsFieldMismatch() throws {
    let (c, _, _, ax) = makeAXCoordinator()
    ax.verifyResult = .mismatch
    try c.insertFinalized("呃你好")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceTail(snap, with: "你好。") == .fieldMismatch)
    #expect(ax.calls.isEmpty)
    #expect(c.displayedText == "呃你好")
}

@Test func replaceTailOfEmptySnapshotToEmptyIsQuietNoOp() throws {
    // performUndo「沒步驟可回」時把（可能為空的）指令話語退掉：空對空不得發出任何 AX 呼叫
    let (c, _, _, ax) = makeAXCoordinator()
    let empty = c.currentTailSnapshot()
    #expect(c.replaceTail(empty, with: "") == .replaced)
    #expect(ax.verifyCalls.isEmpty)
}

// MARK: - replaceSession（修正／undo）：expected＝整個鏡像

@Test func replaceSessionReplacesWholeMirrorViaAX() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 42)
    try c.insertFinalized("舊文")
    _ = c.snapshotAndBeginNext()
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceSession(commandSnapshot: snap, with: "新文") == .replaced)
    #expect(ax.verifyCalls.count == 1)                      // 先驗證
    #expect(ax.calls.count == 1)                            // 再替換
    #expect(ax.calls.first?.identity == sessionIdentity)
    #expect(ax.calls.first?.location == 42)
    #expect(ax.calls.first?.expected == "舊文指令")              // session＋指令話語合併為單一範圍
    #expect(ax.calls.first?.new == "新文")
    #expect(key.ops == [.insert("舊文"), .insert("指令")])   // 全程零鍵盤事件
    #expect(c.displayedText == "新文")
}

@Test func replaceSessionAXMismatchAborts() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 42)
    ax.verifyResult = .mismatch
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceSession(commandSnapshot: snap, with: "新文") == .fieldMismatch)   // 欄位被外力改過：不得亂改
    #expect(key.ops == [.insert("指令")])                   // mismatch 時分毫未動（連指令話語都不退）
    #expect(ax.calls.isEmpty)
    #expect(c.displayedText == "指令")
}

@Test func replaceSessionWithoutAXCapabilityIsUnverifiedAndTouchesNothing() throws {
    // 舊契約在這裡退回 keystroke 盲退格——那是 #21 destructive 清單裡唯一的 fail-open 點，本票封掉
    let (c, key, _, ax) = makeAXCoordinator(anchor: 1)
    ax.verifyResult = .unsupported
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceSession(commandSnapshot: snap, with: "新文") == .unverified)
    #expect(key.ops == [.insert("指令")])
    #expect(ax.calls.isEmpty)
    #expect(c.displayedText == "指令")
}

@Test func replaceSessionWithoutIdentityIsUnverified() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 1, identity: nil)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceSession(commandSnapshot: snap, with: "新文") == .unverified)
    #expect(ax.verifyCalls.isEmpty)
}

@Test func replaceSessionAXSecondStepFailureFreezes() throws {
    // verify 過了、替換那步卻失敗（兩步之間狀況變了）：AX 可能留下活選取——判 fieldMismatch，呼叫端凍結
    let (c, key, _, ax) = makeAXCoordinator(anchor: 1)
    ax.replaceResult = .unsupported
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceSession(commandSnapshot: snap, with: "新文") == .fieldMismatch)
    #expect(key.ops == [.insert("指令")])
    #expect(c.displayedText == "指令")                     // 鏡像不得樂觀更新
}

@Test func replaceSessionTailAdvancedAborts() throws {
    let (c, _, _, ax) = makeAXCoordinator()
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("下一段")                          // 尾端前進
    #expect(c.replaceSession(commandSnapshot: snap, with: "新") == .tailAdvanced)
    #expect(ax.verifyCalls.isEmpty)
}

// MARK: - 其他 API

@Test func fieldContextHasSelectionRequiresNonEmptyRangeAndText() {
    #expect(!FieldContext().hasSelection)
    #expect(!FieldContext(selectedRange: .init(location: 3, length: 0), selectedText: "").hasSelection)
    #expect(!FieldContext(selectedRange: .init(location: 3, length: 2), selectedText: nil).hasSelection)
    #expect(FieldContext(selectedRange: .init(location: 3, length: 2), selectedText: "嗨嗨").hasSelection)
}

@Test func accumulateFinalizedBuffersWithoutInserting() throws {
    let (c, key, paste) = makeCoordinator()
    c.accumulateFinalized("欸改")
    c.accumulateFinalized("正式一點")
    #expect(key.ops.isEmpty && paste.ops.isEmpty)      // 一個鍵盤事件都不准有
    #expect(c.currentUtteranceLength == "欸改正式一點".count)
    #expect(c.displayedText == "")                       // 緩衝：螢幕上沒字，鏡像也沒有
    let snap = c.snapshotAndBeginNext()
    #expect(snap.text == "欸改正式一點")
}

@Test func clearCurrentUtteranceEmitsNoKeyboardEvents() throws {
    let (c, key, paste) = makeCoordinator()
    c.accumulateFinalized("要丟棄的話")
    c.clearCurrentUtterance()
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
    #expect(c.currentUtteranceLength == 0)
}

@Test func replaceSelectionHappyPathUsesAXOnly() throws {
    let (c, key, paste, ax) = makeAXCoordinator(anchor: 7, initialText: "原選取")
    let outcome = c.replaceSelection(location: 7, expected: "原選取", with: "改寫後")
    #expect(outcome == .replaced)
    #expect(ax.calls.count == 1)
    #expect(ax.calls.first?.identity == sessionIdentity)
    #expect(ax.calls.first?.location == 7 && ax.calls.first?.expected == "原選取" && ax.calls.first?.new == "改寫後")
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
    #expect(c.displayedText == "改寫後")
}

@Test func replaceSelectionMismatchAbandonsWithoutTouchingField() throws {
    let (c, key, paste, ax) = makeAXCoordinator(anchor: 7, initialText: "原選取")
    ax.verifyResult = .mismatch                        // 選取已變
    #expect(c.replaceSelection(location: 7, expected: "原選取", with: "改寫後") == .selectionChanged)
    #expect(ax.calls.isEmpty && key.ops.isEmpty && paste.ops.isEmpty)
    #expect(c.displayedText == "原選取")
}

@Test func replaceSelectionWithoutAXIsUnsupported() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: nil)
    c.beginSession(anchor: 0, identity: sessionIdentity, initialText: "x")
    #expect(c.replaceSelection(location: 0, expected: "x", with: "y") == .unsupported)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)
}

@Test func replaceSelectionWithoutIdentityIsUnsupported() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 0, identity: nil, initialText: "x")
    #expect(c.replaceSelection(location: 0, expected: "x", with: "y") == .unsupported)
    #expect(ax.verifyCalls.isEmpty)
}

@Test func replaceSelectionPartialFailureDoesNotFallBackToKeystroke() throws {
    let (c, key, paste, ax) = makeAXCoordinator(anchor: 7, initialText: "原選取")
    ax.replaceResult = .mismatch                       // verify 過、replace 失敗（兩步間變動）
    #expect(c.replaceSelection(location: 7, expected: "原選取", with: "改寫後") == .selectionChanged)
    #expect(key.ops.isEmpty && paste.ops.isEmpty)      // AX 可能留下活選取，keystroke 會把它吃掉
}

@Test func replaceSelectionAdvancesCounter() throws {
    let (c, _, _, _) = makeAXCoordinator(anchor: 0, initialText: "a")
    let snapBefore = c.snapshotAndBeginNext()          // counter 快照
    _ = c.replaceSelection(location: 0, expected: "a", with: "b")
    #expect(c.replaceTail(snapBefore, with: "x") == .tailAdvanced)   // 尾端已前進
}

@Test func insertDetachedDoesNotTouchUtteranceLedgerButUpdatesMirror() throws {
    let (c, key, _) = makeCoordinator()
    try c.insertDetached("直接上屏")
    #expect(key.ops == [.insert("直接上屏")])
    #expect(c.currentUtteranceLength == 0)             // 不掛 utterance 帳本
    #expect(c.displayedText == "直接上屏")             // 但它確實在欄位上
}

@Test func currentTailSnapshotIsLiveAndSideEffectFree() throws {
    let (c, _, _, _) = makeAXCoordinator()
    c.accumulateFinalized("進行中")
    let stale = c.currentTailSnapshot()
    #expect(stale.text.isEmpty)
    #expect(c.currentUtteranceLength == "進行中".count)     // 零副作用：不偷正在累積的緩衝
    try c.insertDetached("x")                              // counter 前進
    #expect(c.replaceTail(stale, with: "y") == .tailAdvanced)  // 舊快照自然過期
    let fresh = c.currentTailSnapshot()                    // 現時 counter：立即可用於 replaceSession
    #expect(c.replaceSession(commandSnapshot: fresh, with: "z") == .replaced)
}

// MARK: - 回收晚到的潤飾（M10-C #7）
// 前一句已不在尾端（後面接了下一句），改以絕對範圓帶校驗替換，並保留游標。

@Test func staleTailIsRecoveredInPlace() throws {
    let (c, key, _, ax) = makeAXCoordinator(anchor: 40)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")                     // 尾端前進 → 正常 replaceTail 已不可用
    #expect(c.replaceTail(snap, with: "第一段。") == .tailAdvanced)   // 前提：確實走不了快路徑

    let outcome = c.replaceStaleTail(snap, at: 40, with: "第一段。")
    #expect(outcome == .replaced)
    #expect(ax.preservingCaretCalls.count == 1)
    #expect(ax.preservingCaretCalls.first?.identity == sessionIdentity)
    #expect(ax.preservingCaretCalls.first?.location == 40)
    #expect(ax.preservingCaretCalls.first?.expected == "第一段")
    #expect(ax.preservingCaretCalls.first?.new == "第一段。")
    #expect(ax.calls.isEmpty)                           // 不得走會把游標收到中段的舊路徑
    #expect(key.ops == [.insert("第一段"), .insert("第二段")])   // 零退格：後面那句不能被動到
    #expect(c.displayedText == "第一段。第二段")          // 鏡像中段更新
}

@Test func staleTailAbortsWhenFieldChangedUnderneath() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40)
    ax.verifyResult = .mismatch                          // 使用者中途手改了該句
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .mismatch)
    #expect(ax.preservingCaretCalls.isEmpty)             // 鐵律：校驗不過就一個字都不准寫
}

@Test func staleTailUnsupportedWithoutRangeReplacer() throws {
    let key = RecordingInserter(), paste = RecordingInserter()
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: nil)
    c.beginSession(anchor: 40, identity: sessionIdentity)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .unsupported)
}

@Test func staleTailUnsupportedWithoutIdentity() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40, identity: nil)
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .unsupported)
    #expect(ax.verifyCalls.isEmpty)
}

@Test func staleTailAbortsWhenReplaceFailsBetweenTheTwoSteps() throws {
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40)
    ax.replaceResult = .mismatch                         // 校驗通過但兩步之間變動
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .mismatch)
    #expect(c.displayedText == "第一段")
}

@Test func staleTailRejectsEmptySnapshotWithoutTouchingTheField() throws {
    // 零長度快照沒有可校驗的錨——那樣的「替換」等於在算出來的位置盲插
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40)
    let empty = c.currentTailSnapshot()                  // text 為空、counter 為現值
    #expect(empty.text.isEmpty)
    #expect(c.replaceStaleTail(empty, at: 40, with: "憑空出現的字") == .mismatch)
    #expect(ax.verifyCalls.isEmpty)                      // 連校驗都不該發出
    #expect(ax.preservingCaretCalls.isEmpty)
}

@Test func staleTailReportsUnsupportedWhenAXCannotReadTheField() throws {
    // 與「欄位被外力改動」不同的成因：AX 根本讀不到欄位。兩者對呼叫端的表面行為一樣，
    // 但語意不同，分類錯了不該沒人發現。
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40)
    ax.verifyResult = .unsupported
    try c.insertFinalized("第一段")
    let snap = c.snapshotAndBeginNext()
    #expect(c.replaceStaleTail(snap, at: 40, with: "第一段。") == .unsupported)
    #expect(ax.preservingCaretCalls.isEmpty)
}

@Test func staleTailRecoveryDoesNotAdvanceTheCounter() throws {
    // counter 的語意是「尾端是否前進」。中段改寫沒有改變誰是尾端——
    // 若遞增，下一句自己的快照會對不上，被迫也走慢路徧（其實它仍在尾端）。
    let (c, _, _, ax) = makeAXCoordinator(anchor: 40)
    try c.insertFinalized("第一段")
    let first = c.snapshotAndBeginNext()
    try c.insertFinalized("第二段")
    let second = c.snapshotAndBeginNext()                // 第二段仍在尾端

    #expect(c.replaceStaleTail(first, at: 40, with: "第一段。") == .replaced)

    // 回收完第一段之後，第二段照樣要能走正常的尾端路徑：位置＝anchor + 鏡像「第一段。」的長度
    #expect(c.replaceTail(second, with: "第二段。") == .replaced)
    #expect(ax.calls.last?.location == 44 && ax.calls.last?.expected == "第二段")
    #expect(c.displayedText == "第一段。第二段。")
}

// MARK: - 備援診斷（issue #1 蒐證）
// 主 inserter 失敗、備援救回＝控制流無異狀、帳面成功，過去什麼都不留。

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
    #expect(c.displayedText == "")                     // 一個字都沒進欄位，鏡像也不得記
}
