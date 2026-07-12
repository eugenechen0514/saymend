import Testing
@testable import SpeeckinkCore

final class RecordingInserter: TextInserter {
    enum Op: Equatable { case insert(String), delete(Int) }
    var ops: [Op] = []
    var failInsertsRemaining = 0
    func insert(_ text: String) throws {
        if failInsertsRemaining > 0 { failInsertsRemaining -= 1; throw InserterError.postFailed }
        ops.append(.insert(text))
    }
    func deleteBackward(count: Int) throws { ops.append(.delete(count)) }
}

final class FakeRangeReplacer: SessionRangeReplacing {
    var verifyResult: RangeReplaceResult = .replaced
    var replaceResult: RangeReplaceResult = .replaced
    private(set) var verifyCalls: [(location: Int, expected: String)] = []
    private(set) var calls: [(location: Int, expected: String, new: String)] = []
    func verifyRange(location: Int, expected: String) -> RangeReplaceResult {
        verifyCalls.append((location, expected))
        return verifyResult
    }
    func replaceVerifiedRange(location: Int, expected: String, with newText: String) -> RangeReplaceResult {
        calls.append((location, expected, newText))
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
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 42)
    #expect(out == .replaced)
    #expect(ax.verifyCalls.count == 1)                      // 先驗證
    #expect(ax.calls.count == 1)                            // 再替換
    #expect(ax.calls[0].location == 42)
    #expect(ax.calls[0].expected == "舊文")
    #expect(key.ops == [.insert("指令"), .delete(2)])       // 只退指令，session 由 AX 換
}

@Test func replaceSessionAXMismatchAborts() throws {
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .mismatch
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 6)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 42)
    #expect(out == .fieldMismatch)                          // 欄位被外力改過：不得亂改
    #expect(key.ops == [.insert("指令")])                   // mismatch 時分毫未動（連指令話語都不退）
    #expect(!key.ops.contains(.insert("新文")))
}

@Test func replaceSessionAXUnsupportedFallsBackToKeystroke() throws {
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 1)
    #expect(out == .replaced)
    #expect(key.ops == [.insert("指令"), .delete(2), .delete(2), .insert("新文")])
}

@Test func replaceSessionAXSecondStepFailureFallsBackToKeystroke() throws {
    // verify 過了、替換那步卻失敗（兩步之間狀況變了）：指令已退掉，session 仍是尾端 → keystroke 補完
    let key = RecordingInserter(); let paste = RecordingInserter()
    let ax = FakeRangeReplacer(); ax.verifyResult = .replaced; ax.replaceResult = .unsupported
    let c = InsertionCoordinator(keystroke: key, paste: paste, rangeReplacer: ax, pasteThreshold: 100)
    try c.insertFinalized("指令")
    let snap = c.snapshotAndBeginNext()
    let out = try c.replaceSession(commandSnapshot: snap, expectedSessionText: "舊文", with: "新文", axAnchor: 1)
    #expect(out == .replaced)
    #expect(key.ops == [.insert("指令"), .delete(2), .delete(2), .insert("新文")])
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
