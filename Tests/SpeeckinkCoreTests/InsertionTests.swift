import Testing
@testable import SpeeckinkCore

final class RecordingInserter: TextInserter {
    enum Op: Equatable { case insert(String), delete(Int) }
    var ops: [Op] = []
    var failNextInsert = false
    func insert(_ text: String) throws {
        if failNextInsert { failNextInsert = false; throw InserterError.postFailed }
        ops.append(.insert(text))
    }
    func deleteBackward(count: Int) throws { ops.append(.delete(count)) }
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
    key.failNextInsert = true
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
