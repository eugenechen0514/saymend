import Testing
@testable import SaymendCore

@Test func beginResetsStateAndStoresAnchor() {
    var l = SessionLedger()
    l.begin(axAnchor: 42)
    #expect(l.isActive)
    #expect(l.sessionText == "")
    #expect(l.axAnchor == 42)
    #expect(!l.frozen)
    #expect(!l.canUndo)
}

@Test func commitPushesVersionAndUpdatesText() {
    var l = SessionLedger()
    l.begin(axAnchor: nil)
    l.commit("你好。")
    #expect(l.sessionText == "你好。")
    #expect(l.canUndo)
    l.commit("你好。今天天氣好。")
    #expect(l.sessionText == "你好。今天天氣好。")
}

@Test func undoRestoresPreviousVersions() {
    var l = SessionLedger()
    l.begin(axAnchor: nil)
    l.commit("A")
    l.commit("AB")
    let step1 = l.undo()
    #expect(step1?.from == "AB")
    #expect(step1?.to == "A")
    #expect(l.sessionText == "A")
    let step2 = l.undo()
    #expect(step2?.from == "A")
    #expect(step2?.to == "")
    #expect(l.sessionText == "")
    #expect(l.undo() == nil)          // 堆疊空
    #expect(!l.canUndo)
}

@Test func correctionThenUndoRoundTrip() {
    var l = SessionLedger()
    l.begin(axAnchor: 7)
    l.commit("呃你好")                  // 第一句落定
    l.commit("你好。")                  // 修正落定（全文替換）
    let u = l.undo()
    #expect(u?.from == "你好。")
    #expect(u?.to == "呃你好")
}

@Test func freezeAndArchive() {
    var l = SessionLedger()
    l.begin(axAnchor: nil)
    l.commit("X")
    l.freeze()
    #expect(l.frozen)
    #expect(l.isActive)               // 凍結仍算存活（文字定稿但 session 未清）
    l.archive()
    #expect(!l.isActive)
    #expect(l.sessionText == "")
    #expect(!l.frozen)
    #expect(l.axAnchor == nil)
    #expect(!l.canUndo)
}

@Test func beginAfterArchiveStartsFresh() {
    var l = SessionLedger()
    l.begin(axAnchor: 1)
    l.commit("舊")
    l.archive()
    l.begin(axAnchor: nil)
    #expect(l.sessionText == "")
    #expect(!l.canUndo)
    #expect(l.axAnchor == nil)
}

@Test func beginWithInitialTextSeedsUndoBase() {
    var ledger = SessionLedger()
    ledger.begin(axAnchor: 10, initialText: "原選取文字")
    #expect(ledger.sessionText == "原選取文字")
    #expect(!ledger.canUndo)                       // 種子不是一版，還沒有可復原的動作
    ledger.commit("改寫後")
    #expect(ledger.canUndo)
    let step = ledger.undo()
    #expect(step?.from == "改寫後")
    #expect(step?.to == "原選取文字")               // 復原＝回到使用者原本選取的文字
}

@Test func beginDefaultsToEmptyInitialText() {
    var ledger = SessionLedger()
    ledger.begin(axAnchor: nil)
    #expect(ledger.sessionText == "")
}

@Test func synchronizeObservedTailUpdatesMirrorWithoutVersion() {
    var ledger = SessionLedger()
    ledger.begin(axAnchor: nil)
    #expect(ledger.canUndo == false)

    ledger.synchronizeObservedTail("已上屏 raw")

    #expect(ledger.sessionText == "已上屏 raw")
    #expect(ledger.canUndo == false)          // 關鍵：不得推進 undo stack
    #expect(ledger.undo() == nil)             // 沒有版本可退
}

@Test func synchronizeObservedTailDoesNotDisturbExistingVersions() {
    var ledger = SessionLedger()
    ledger.begin(axAnchor: nil)
    ledger.commit("第一句。")                  // versions = [""]
    #expect(ledger.canUndo)

    ledger.synchronizeObservedTail("第一句。第二句原文")

    #expect(ledger.sessionText == "第一句。第二句原文")
    #expect(ledger.canUndo)                   // 既有版本仍在
    // undo 目標是「第一句。」之前的空字串——degraded 那句不佔版本
    let step = ledger.undo()
    #expect(step?.to == "")
}

/// issue #43：session 起始欄位的 identity token 與 axAnchor 同住 ledger（兩者都是 AX 路徑的錨），
/// begin 時存、archive 時清。#44 的刪字驗證會拿它去對現在聚焦的 element。
@Test func beginStoresFieldIdentityAndArchiveClearsIt() {
    var l = SessionLedger()
    let id = FieldIdentity(token: 42)
    l.begin(axAnchor: 3, fieldIdentity: id)
    #expect(l.fieldIdentity == id)
    #expect(l.axAnchor == 3)
    l.archive()
    #expect(l.fieldIdentity == nil)
}

@Test func beginWithoutIdentityLeavesItNil() {
    var l = SessionLedger()
    l.begin(axAnchor: nil, fieldIdentity: FieldIdentity(token: 1))
    l.begin(axAnchor: nil)                   // 新 session 沒給 identity → 不得殘留上一個
    #expect(l.fieldIdentity == nil)
}

/// issue #44：Esc 整段退回的終點是 session 開始前「本階段掌控的原文」——一般 tail 是空字串，
/// 選取即目標則是原選取。不可拿 sessionText 猜。
@Test func beginStoresInitialTextAndArchiveClearsIt() {
    var l = SessionLedger()
    l.begin(axAnchor: 3, initialText: "原選取")
    #expect(l.initialText == "原選取")
    l.commit("改寫後")
    #expect(l.initialText == "原選取", "commit 不得改 initialText")
    l.archive()
    #expect(l.initialText == "")
    l.begin(axAnchor: nil)
    #expect(l.initialText == "")
}
