import Foundation
import Testing
@testable import SpeeckinkCore

@MainActor
@Test func pressStartsHoldListening() {
    let (c, audio, asr, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    #expect(c.phase == .listening(.hold))
    #expect(audio.startCount == 1)
    #expect(asr.startCount == 1)
    #expect(hud.states.last == .listening(mode: .hold, volatile: ""))
}

@MainActor
@Test func quickTapSwitchesToLockedMode() {
    let (c, audio, _, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.2)          // 0.2s < 0.3s → 鎖定
    #expect(c.phase == .listening(.locked))
    #expect(audio.stopCount == 0)       // 不停止
    #expect(hud.states.last == .listening(mode: .locked, volatile: ""))
}

@MainActor
@Test func longHoldReleaseEndsListening() {
    let (c, audio, _, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)          // 1.0s ≥ 0.3s → 結束
    #expect(c.phase == .idle)
    #expect(audio.stopCount == 1)
}

@MainActor
@Test func secondTapEndsLockedSession() {
    let (c, audio, _, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)          // 進鎖定
    c.hotkeyPressed(at: 15.0)
    c.hotkeyReleased(at: 15.1)          // 第二次短按 → 結束
    #expect(c.phase == .idle)
    #expect(audio.stopCount == 1)
}

@MainActor
@Test func escapeDiscardsUtteranceAndEndsSession() {
    let (c, audio, asr, key, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("要丟掉"), at: 10.5)
    c.escapePressed()
    #expect(c.phase == .idle)
    #expect(asr.cancelCount == 1)
    #expect(audio.stopCount == 1)
    #expect(key.ops.contains(.delete(3)))          // 退格清掉「要丟掉」
    #expect(hud.states.last == .hidden)
}

@MainActor
@Test func pressWhileHoldIsIgnored() {
    let (c, audio, _, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyPressed(at: 10.05)          // key repeat
    #expect(audio.startCount == 1)
}

@MainActor
@Test func finalizedInsertsAndVolatileGoesToHUD() {
    let (c, _, _, key, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.volatile("你"), at: 10.5)
    c.handleTranscript(.finalized("你好"), at: 11.0)
    #expect(hud.states.contains(.listening(mode: .hold, volatile: "你")))
    #expect(key.ops == [.insert("你好")])
}

@MainActor
@Test func quietGapPolishesAndReplacesTail() async {
    let polisher = GatedIntentService()
    polisher.outcome = .newContent("你好。")
    let (c, _, _, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                    // 鎖定
    c.handleTranscript(.finalized("呃你好"), at: 11.0)
    c.tick(at: 12.6)                              // 1.6s quiet → 潤飾
    await c.lastIntentTask?.value
    #expect(polisher.calls.map(\.raw) == ["呃你好"])
    #expect(key.ops == [.insert("呃你好"), .delete(3), .insert("你好。")])
}

@MainActor
@Test func replaceAbortsWhenNextUtteranceStarted() async {
    let polisher = GatedIntentService()
    polisher.gated = true
    polisher.outcome = .newContent("第一段。")
    let (c, _, _, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("第一段"), at: 11.0)
    c.tick(at: 12.6)                              // 潤飾發出（被 gate 卡住）
    c.handleTranscript(.finalized("第二段"), at: 13.0)  // 尾端前進
    polisher.release()
    await c.lastIntentTask?.value
    #expect(!key.ops.contains(.delete(3)))        // 不得替換
    #expect(hud.states.contains(.notice("未潤飾")))
}

@MainActor
@Test func degradedKeepsRawAndNotifies() async {
    let polisher = GatedIntentService()
    polisher.outcome = .degraded(reason: "測試")
    let (c, _, _, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("原文"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(key.ops == [.insert("原文")])          // 原文保留，無退格
    #expect(hud.states.contains(.notice("未潤飾")))
}

@MainActor
@Test func streamEndFlushesRemainderThroughPolish() async {
    let polisher = GatedIntentService()
    polisher.outcome = .newContent("尾巴。")
    let (c, _, asr, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("尾巴"), at: 11.0)
    c.hotkeyReleased(at: 12.0)                    // 長按結束 → audio.stop
    asr.continuation?.finish()                     // 模擬 ASR 排空後結束
    c.asrStreamEnded(at: 12.1)
    await c.lastIntentTask?.value
    #expect(polisher.calls.map(\.raw) == ["尾巴"])
    #expect(key.ops == [.insert("尾巴"), .delete(2), .insert("尾巴。")])
}

@MainActor
@Test func lockedSilenceTimeoutEndsSession() {
    let (c, audio, _, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                    // 鎖定
    c.tick(at: 75.0)                              // 60s 無活動
    #expect(c.phase == .idle)
    #expect(audio.stopCount == 1)
}

// MARK: - 排空（drain）與跨 session 隔離

/// Finding #1：結束聽寫後，ASR 排空階段的尾端 finalized 仍須上屏＋進 flush 緩衝，不能白說話。
@MainActor
@Test func drainFinalizedAfterEndIsInsertedAndFlushed() async {
    let polisher = GatedIntentService()
    polisher.outcome = .newContent("你好世界。")
    let (c, _, _, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("你好"), at: 10.5)
    c.hotkeyReleased(at: 11.0)                         // 長按放開 → endListening → 進排空窗
    c.handleTranscript(.finalized("世界"), at: 11.1)    // drain 尾端 finalized：仍須上屏＋入 buffer
    c.asrStreamEnded(at: 11.2)                         // 排空結束 → flush → 潤飾整句
    await c.lastIntentTask?.value
    #expect(polisher.calls.map(\.raw) == ["你好世界"])              // 尾巴「世界」沒被丟
    #expect(key.ops == [.insert("你好"), .insert("世界"), .delete(4), .insert("你好世界。")])
}

/// Finding #2：舊 session 的殘留 transcript 不得注入正在使用的新 session。
@MainActor
@Test func staleSessionTranscriptIsFiltered() {
    let (c, _, _, key, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)                                        // session A
    let a = c.sessionID
    c.receiveTranscript(.finalized("甲"), session: a, at: 10.5)      // 當前 session → 上屏
    #expect(key.ops.contains(.insert("甲")))
    c.hotkeyReleased(at: 11.0)                                       // 進排空窗
    c.hotkeyPressed(at: 12.0)                                        // 排空窗內開 session B（跳號＋reset）
    let b = c.sessionID
    #expect(b != a)
    c.receiveTranscript(.finalized("污染"), session: a, at: 12.5)     // A 的殘留 → 必須丟棄
    #expect(!key.ops.contains(.insert("污染")))
    c.receiveTranscript(.finalized("乙"), session: b, at: 12.6)       // B 的正常事件 → 上屏
    #expect(key.ops.contains(.insert("乙")))
}

/// Finding #2：舊 session 的 stream-end 不得提早 flush／潤飾新 session 的半句。
@MainActor
@Test func staleStreamEndDoesNotFlushNewSession() async {
    let polisher = GatedIntentService()
    let (c, _, _, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)                                        // session A
    let a = c.sessionID
    c.hotkeyReleased(at: 11.0)                                       // 進排空窗
    c.hotkeyPressed(at: 12.0)                                        // 開 session B
    c.receiveTranscript(.finalized("半句"), session: c.sessionID, at: 12.5)  // B 的半句進 buffer
    c.receiveStreamEnd(session: a, at: 12.6)                         // A 的 stale stream-end → 忽略
    await c.lastIntentTask?.value
    #expect(polisher.calls.isEmpty)                                  // 未被提早切斷潤飾
}

@MainActor
@Test func escapeSkipsPendingFlush() async {
    let polisher = GatedIntentService()
    let (c, _, asr, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("別潤飾我"), at: 10.5)
    c.escapePressed()
    asr.continuation?.finish()
    c.asrStreamEnded(at: 10.6)
    #expect(polisher.calls.isEmpty)               // Esc 後不得潤飾
}

// MARK: - session 生命週期 v2（lingering／凍結／帳本）

@MainActor
@Test func normalEndEntersLingeringThenArchivesAt8s() {
    let (c, _, asr, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)            // 長按結束 → finishing
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)
    #expect(c.phase == .idle)             // 對外形狀不變
    #expect(c.isLingering)
    #expect(hud.states.contains(.lingering))
    c.tick(at: 19.1)                      // 11.2 + 8 = 19.2 未到
    #expect(c.isLingering)
    c.tick(at: 19.3)
    #expect(!c.isLingering)
    #expect(hud.states.last == .hidden)
}

@MainActor
@Test func pressDuringLingerResumesSameSessionLedger() async {
    let polisher = GatedIntentService()
    polisher.outcome = .newContent("你好。")
    let (c, _, asr, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("呃你好"), at: 10.5)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)            // flush → 潤飾
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "你好。")
    #expect(c.isLingering)
    c.hotkeyPressed(at: 12.0)             // 延續窗內再按 → 同 session（規格 §3.4）
    #expect(c.phase == .listening(.hold))
    #expect(c.ledger.sessionText == "你好。")
    #expect(c.ledger.isActive)
}

@MainActor
@Test func escapeArchivesImmediatelyNoLinger() {
    let (c, _, _, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("丟"), at: 10.5)
    c.escapePressed()
    #expect(!c.isLingering)
    #expect(!c.ledger.isActive)
}

@MainActor
@Test func escapeDuringLingerArchives() {
    let (c, _, asr, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)
    #expect(c.isLingering)
    c.escapePressed()                       // 延續窗中按 Esc＝提前定稿
    #expect(!c.isLingering)
    #expect(!c.ledger.isActive)
    #expect(hud.states.last == .hidden)
}

@MainActor
@Test func lockedTimeoutArchivesAfterDrain() {
    let (c, audio, asr, _, _, _) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)            // 鎖定
    c.tick(at: 75.0)                      // 60 秒靜音逾時 → 排空
    #expect(audio.stopCount == 1)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 75.2)
    #expect(!c.isLingering)               // 逾時＝凍結觸發器，不進延續窗
    #expect(!c.ledger.isActive)
}

@MainActor
@Test func userActivityWhileListeningFreezesAndBlocksReplace() async {
    let polisher = GatedIntentService()
    polisher.outcome = .newContent("你好。")
    let (c, _, asr, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("呃你好"), at: 10.5)
    c.userActivityDetected(at: 10.8)      // 使用者手動打字（設計裁決 2）
    #expect(c.ledger.frozen)
    #expect(hud.states.contains(.notice("偵測到手動輸入，本段不再修正")))
    c.hotkeyReleased(at: 11.5)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.6)
    await c.lastIntentTask?.value
    #expect(!key.ops.contains(.delete(3)))   // 凍結後不得改寫欄位
    #expect(!c.isLingering)                  // 凍結 session 不進延續窗
    #expect(!c.ledger.isActive)
}

@MainActor
@Test func userActivityDuringLingerArchives() {
    let (c, _, asr, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)
    #expect(c.isLingering)
    c.userActivityDetected(at: 12.0)
    #expect(!c.isLingering)
    #expect(!c.ledger.isActive)
    #expect(hud.states.last == .hidden)
}

@MainActor
@Test func commitsAccumulateInLedger() async {
    let polisher = GatedIntentService()
    let (c, _, _, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)             // 鎖定
    polisher.outcome = .newContent("第一句。")
    c.handleTranscript(.finalized("呃第一句"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "第一句。")
    polisher.outcome = .degraded(reason: "x")
    c.handleTranscript(.finalized("第二句原文"), at: 13.0)
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "第一句。第二句原文")   // degraded 以原文入帳（欄位鏡像）
    #expect(c.ledger.canUndo)
}

@MainActor
@Test func editCommandReplacesSessionAndRemovesCommandUtterance() async {
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                      // 鎖定
    intent.outcome = .newContent("星期二開會。")
    c.handleTranscript(.finalized("星期二開會"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "星期二開會。")
    intent.outcome = .editedSession("星期三開會。")
    c.handleTranscript(.finalized("欸改成星期三"), at: 13.0)   // 指令話語（6 字）已上屏
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    #expect(intent.calls.last?.context.targetText == "星期二開會。")       // 呼叫帶 session 全文
    // 退指令 6 字 → 退 session 全文 6 字 → 重打修正後全文
    #expect(Array(key.ops.suffix(3)) == [.delete(6), .delete(6), .insert("星期三開會。")])
    #expect(c.ledger.sessionText == "星期三開會。")
    #expect(hud.states.contains(.notice("已修正")))
}

@MainActor
@Test func undoIntentRevertsLastCommit() async {
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("星期二開會。")
    c.handleTranscript(.finalized("星期二開會"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    intent.outcome = .editedSession("星期三開會。")
    c.handleTranscript(.finalized("改成星期三"), at: 13.0)      // 5 字
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    intent.outcome = .undo
    c.handleTranscript(.finalized("復原上一步"), at: 15.0)      // 5 字
    c.tick(at: 16.6)
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "星期二開會。")
    #expect(Array(key.ops.suffix(3)) == [.delete(5), .delete(6), .insert("星期二開會。")])
    #expect(hud.states.contains(.notice("已復原")))
    #expect(c.ledger.canUndo)                        // 還能再復原回空
}

@MainActor
@Test func frozenSessionRefusesCorrection() async {
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("內容。")
    c.handleTranscript(.finalized("內容"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    c.userActivityDetected(at: 13.0)                 // 凍結
    intent.outcome = .editedSession("改壞。")
    c.handleTranscript(.finalized("改一下"), at: 13.5)
    c.tick(at: 15.1)
    await c.lastIntentTask?.value
    #expect(hud.states.contains(.notice("已凍結，未修正")))
    #expect(!key.ops.contains(.insert("改壞。")))
    #expect(c.ledger.sessionText == "內容。")         // 帳本未動
}

@MainActor
@Test func lostTextDuringNewContentRescuesToClipboard() async {
    let intent = GatedIntentService()
    let clipboard = ClipboardSpy()
    let pasteFake = RecordingInserter()
    let (c, _, _, key, _, hud) = makeController(polisher: intent, pasteInserter: pasteFake, clipboard: clipboard)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("你好。")
    c.handleTranscript(.finalized("呃你好"), at: 11.0)
    key.failInsertsRemaining = 2                     // 新文字與原文回復（keystroke 側）都失敗
    pasteFake.failInsertsRemaining = 2               // paste 備援也失敗
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(clipboard.texts == ["呃你好"])            // 鐵律最後手段：原文進剪貼簿
    #expect(hud.states.contains(.notice("插入失敗，原文已複製到剪貼簿")))
}

@MainActor
@Test func undoRequestedDuringLingerRevertsAndKeepsLinger() async {
    let intent = GatedIntentService()
    let (c, _, asr, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("星期二開會。")
    c.handleTranscript(.finalized("星期二開會"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    intent.outcome = .editedSession("星期三開會。")
    c.handleTranscript(.finalized("改成星期三"), at: 13.0)
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    c.hotkeyPressed(at: 15.0)
    c.hotkeyReleased(at: 15.05)               // 鎖定中短按 → 結束
    asr.continuation?.finish()
    c.asrStreamEnded(at: 15.2)
    #expect(c.isLingering)
    c.undoRequested()                          // HUD 按鈕（無指令話語）
    #expect(Array(key.ops.suffix(2)) == [.delete(6), .insert("星期二開會。")])
    #expect(c.ledger.sessionText == "星期二開會。")
    #expect(hud.states.contains(.notice("已復原")))
    #expect(c.isLingering)                     // 延續窗不因復原而中斷
}

@MainActor
@Test func undoRequestedWithNothingToUndoNotices() {
    let (c, _, _, key, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)                  // session 開了但沒有任何 commit
    c.undoRequested()
    #expect(hud.states.contains(.notice("沒有可復原的步驟")))
    #expect(key.ops.isEmpty)
}

@MainActor
@Test func undoRequestedMidUtteranceRefuses() {
    let (c, _, _, key, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("半句"), at: 10.5)   // 目前 utterance 尚未收尾
    c.undoRequested()
    #expect(hud.states.contains(.notice("說完這句再復原")))
    #expect(!key.ops.contains(.delete(2)))
}

@MainActor
@Test func undoRequestedWhenIdleIsNoop() {
    let (c, _, _, _, _, hud) = makeController()
    let statesBefore = hud.states.count
    c.undoRequested()
    #expect(hud.states.count == statesBefore)
}

@MainActor
@Test func secureFieldRefusesListening() {
    let reader = FakeFieldReader()
    reader.context = FieldContext(hasFocusedElement: true, isSecure: true, caretLocation: nil)
    let (c, audio, _, _, _, hud) = makeController(fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    #expect(c.phase == .idle)
    #expect(audio.startCount == 0)                    // 不錄音（規格 §5.3）
    #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
    #expect(!c.ledger.isActive)
}

@MainActor
@Test func axAnchorFlowsIntoCorrection() async {
    let reader = FakeFieldReader()
    reader.context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: 42)
    let ax = FakeRangeReplacer()                      // verify／replace 預設 .replaced
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("星期二開會。")
    c.handleTranscript(.finalized("星期二開會"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    intent.outcome = .editedSession("星期三開會。")
    c.handleTranscript(.finalized("欸改成星期三"), at: 13.0)
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    #expect(ax.verifyCalls.first?.location == 42)     // session 起點錨位流進 AX 路徑
    #expect(ax.calls.first?.location == 42)
    #expect(ax.calls.first?.expected == "星期二開會。欸改成星期三")   // session＋指令合併單一範圍
    #expect(key.ops.last == .insert("欸改成星期三"))   // AX 單次整段替換：零退格（最後的鍵盤事件是指令原文上屏）
    #expect(c.ledger.sessionText == "星期三開會。")
    #expect(hud.states.contains(.notice("已修正")))
}

@MainActor
@Test func axMismatchFreezesSession() async {
    let reader = FakeFieldReader()
    reader.context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: 0)
    let ax = FakeRangeReplacer(); ax.verifyResult = .mismatch
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.outcome = .newContent("內容。")
    c.handleTranscript(.finalized("內容"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    intent.outcome = .editedSession("改。")
    c.handleTranscript(.finalized("改一下"), at: 13.0)
    let opsBefore = key.ops.count
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    #expect(hud.states.contains(.notice("欄位已被外部改動，本段停止修正")))
    #expect(c.ledger.frozen)
    #expect(key.ops.count == opsBefore)               // 指令話語留在欄位、分毫未動
    #expect(c.ledger.sessionText == "內容。")
}

/// 迴歸：延續窗內點 HUD「復原」的接線危險——若滑鼠 leftMouseDown 被當成使用者活動先送進
/// userActivityDetected，會在 undo 之前 archiveSession（internalPhase→.idle、ledger 封存、HUD 隱藏），
/// 使隨後 FIFO 排隊的 undoRequested 命中 .idle → return（no-op）。
/// 此測試釘住 controller 端的危險順序；App 端由 HotkeyMonitor.shouldEmitUserActivityForMouse
/// 對落在自家 HUD 的點擊回傳 false 來阻斷（見 SpeeckinkAppTests）。
@MainActor
@Test func lingerHUDClickSequence_userActivityBeforeUndoWouldBreakUndo() async {
    // 危險順序：使用者活動（未過濾的 HUD mouseDown）先到 → 封存 → undo 變 no-op
    do {
        let intent = GatedIntentService()
        let (c, _, asr, key, _, _) = makeController(polisher: intent)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        intent.outcome = .newContent("星期二開會。")
        c.handleTranscript(.finalized("星期二開會"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        intent.outcome = .editedSession("星期三開會。")
        c.handleTranscript(.finalized("改成星期三"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        c.hotkeyPressed(at: 15.0); c.hotkeyReleased(at: 15.05)
        asr.continuation?.finish(); c.asrStreamEnded(at: 15.2)
        #expect(c.isLingering)
        let opsBefore = key.ops.count
        c.userActivityDetected(at: 15.3)           // 未過濾的 mouseDown → 立即封存
        #expect(!c.isLingering)                    // session 已封存
        c.undoRequested()                          // mouseUp 才觸發，命中 .idle → no-op
        #expect(key.ops.count == opsBefore)        // 什麼都沒退，復原失效（危險已成立）
    }
    // 正確接線：HUD 點擊被 HotkeyMonitor 過濾（不送 userActivity），只送 undoRequested → 復原成立
    do {
        let intent = GatedIntentService()
        let (c, _, asr, key, _, hud) = makeController(polisher: intent)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        intent.outcome = .newContent("星期二開會。")
        c.handleTranscript(.finalized("星期二開會"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        intent.outcome = .editedSession("星期三開會。")
        c.handleTranscript(.finalized("改成星期三"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        c.hotkeyPressed(at: 15.0); c.hotkeyReleased(at: 15.05)
        asr.continuation?.finish(); c.asrStreamEnded(at: 15.2)
        #expect(c.isLingering)
        c.undoRequested()                          // 過濾後只剩這一路
        #expect(Array(key.ops.suffix(2)) == [.delete(6), .insert("星期二開會。")])
        #expect(c.ledger.sessionText == "星期二開會。")
        #expect(hud.states.contains(.notice("已復原")))
        #expect(c.isLingering)                     // 復原不中斷延續窗
    }
}

@MainActor
@Test func isEngagedCoversFinishingAndLingeringWindows() {
    let (c, _, asr, _, _, _) = makeController()
    #expect(!c.isEngaged)
    c.hotkeyPressed(at: 10.0)
    #expect(c.isEngaged)                 // listening
    c.hotkeyReleased(at: 11.0)           // 長按結束 → finishing（排空窗）
    #expect(c.phase == .idle)            // 對外 phase 看不出 finishing——
    #expect(c.isEngaged)                 // ——但 app 層必須繼續吞 Esc、偵測使用者活動
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)           // → lingering
    #expect(c.isEngaged)
    c.tick(at: 19.5)                     // 延續窗過期封存
    #expect(!c.isEngaged)
}

// MARK: - 終審併發家族回歸測試（刻意在 LLM 在途時操作，不先 await）

@MainActor
@Test func undoRequestedWhileIntentInFlightRefuses() async {
    let intent = GatedIntentService()
    let (c, _, asr, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                 // 鎖定
    intent.outcome = .newContent("第一句。")
    c.handleTranscript(.finalized("第一句"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value              // 先落定一步，讓 canUndo 為真
    intent.gated = true                        // 下一句 LLM 卡住（在途）
    intent.outcome = .newContent("第二句。")
    c.handleTranscript(.finalized("第二句"), at: 13.0)
    c.hotkeyPressed(at: 14.0)
    c.hotkeyReleased(at: 14.05)                // 結束 → 排空
    asr.continuation?.finish()
    c.asrStreamEnded(at: 14.2)                 // flush → 第二句 intent 在途 → lingering
    #expect(c.isLingering)
    #expect(c.pendingIntents == 1)
    let opsBefore = key.ops
    c.undoRequested()                          // 終審 critical 場景：在途時按復原
    #expect(hud.states.contains(.notice("說完這句再復原")))
    #expect(key.ops == opsBefore)              // 分毫未動——不可依過期長度退格
    intent.release()
    await c.lastIntentTask?.value
    #expect(c.ledger.sessionText == "第一句。第二句。")   // 在途句正常落定
    c.undoRequested()                          // 落定後復原恢復可用
    #expect(hud.states.contains(.notice("已復原")))
    #expect(c.ledger.sessionText == "第一句。")
}

@MainActor
@Test func staleGenerationOutcomeIsDropped() async {
    let intent = GatedIntentService()
    let (c, _, asr, key, _, _) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    intent.gated = true
    intent.outcome = .newContent("舊世代。")
    c.handleTranscript(.finalized("舊句"), at: 10.5)
    c.hotkeyReleased(at: 11.0)                 // 排空
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.1)                 // 舊句 intent 在途 → lingering
    c.userActivityDetected(at: 11.5)           // 點擊他處 → 封存
    #expect(!c.ledger.isActive)
    c.hotkeyPressed(at: 12.0)                  // 立刻開新 session（begin → 世代 +1）
    let opsBefore = key.ops
    intent.release()                            // 舊世代 outcome 這才回來
    await c.lastIntentTask?.value
    #expect(key.ops == opsBefore)              // 不得對新 session 的游標位置動手
    #expect(c.ledger.sessionText == "")        // 新帳本不受舊 outcome 鏡像污染
}

@MainActor
@Test func editedSessionWithStaleBasisDegradesToKeepRaw() async {
    let intent = GatedIntentService()
    let (c, _, _, key, _, hud) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                 // 鎖定
    intent.gatedRaws = ["第一句"]              // 第一句卡住、第二句直通
    intent.outcomeByRaw = ["第一句": .newContent("第一句。"),
                           "欸改一下": .editedSession("被竄改的全文。")]
    c.handleTranscript(.finalized("第一句"), at: 11.0)
    c.tick(at: 12.6)                           // 第一句 intent 在途（gated）
    c.handleTranscript(.finalized("欸改一下"), at: 13.0)
    c.tick(at: 14.6)                           // 第二句（修正指令）以「不含第一句」的過期基準呼叫 LLM
    intent.release()                            // 放行第一句；套用串行化：第一句先落地、第二句後落地
    await c.lastIntentTask?.value
    // 第一句因尾端已前進而保留原文（M1 設計裁決）、修正因基準過期降級 keepRaw——重點：第一句沒有被抹掉
    #expect(c.ledger.sessionText == "第一句欸改一下")
    #expect(!key.ops.contains(.insert("被竄改的全文。")))
    #expect(hud.states.contains(.notice("未修正（內容已變動，請再說一次）")))
    #expect(intent.calls.last?.context.targetText == "")   // 佐證：第二句呼叫時基準確實是過期的空全文
}

@MainActor
@Test func outcomesApplyInUtteranceOrderEvenIfLaterReturnsFirst() async {
    let intent = GatedIntentService()
    let (c, _, _, key, _, _) = makeController(polisher: intent)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    intent.gatedRaws = ["第一句"]              // 模擬第 N 句慢、第 N+1 句先返回
    intent.outcomeByRaw = ["第一句": .newContent("第一句。"),
                           "第二句": .newContent("第二句。")]
    c.handleTranscript(.finalized("第一句"), at: 11.0)
    c.tick(at: 12.6)
    c.handleTranscript(.finalized("第二句"), at: 13.0)
    c.tick(at: 14.6)
    intent.release()
    await c.lastIntentTask?.value
    // 串行化保證帳本與欄位順序一致：先一後二，不得左右對調。
    // 第一句因尾端已前進而保留原文（M1 設計裁決：潤飾僅替換仍在尾端的 utterance）。
    #expect(c.ledger.sessionText == "第一句第二句。")
    let inserts = key.ops.compactMap { if case .insert(let s) = $0 { return s } else { return nil } }
    let i1 = inserts.firstIndex(of: "第一句")
    let i2 = inserts.firstIndex(of: "第二句。")
    #expect(i1 != nil && i2 != nil && i1! < i2!)
}

@MainActor
@Test func escapeDuringFinishingCancelsAndArchives() {
    let (c, _, asr, _, _, hud) = makeController()
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)                 // finishing（排空窗）
    #expect(c.isEngaged)
    c.escapePressed()                          // 排空窗按 Esc：中止排空、提前定稿
    #expect(asr.cancelCount == 1)
    #expect(!c.isEngaged)
    #expect(!c.ledger.isActive)
    #expect(hud.states.last == .hidden)
}

@MainActor
@Test func audioStartFailureLeavesNoOrphanLedger() {
    let (c, audio, _, _, _, hud) = makeController()
    audio.failNextStart = true
    c.hotkeyPressed(at: 10.0)
    #expect(c.phase == .idle)
    #expect(!c.ledger.isActive)                // 不留 idle＋isActive 孤兒（活動偵測在 idle 不設防）
    #expect(hud.states.contains(.notice("無法啟動麥克風")))
}

// MARK: - 選取即目標（規格 §3.6，M3 設計裁決 1–4）

/// 便利：帶選取的欄位快照
private func selectionField(_ text: String, location: Int) -> FieldContext {
    FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: location,
                 selectedRange: .init(location: location, length: text.utf16.count),
                 selectedText: text)
}

@MainActor
@Test func selectionEditCommandReplacesSelectionWithoutTyping() async {
    let intent = GatedIntentService()
    intent.outcome = .editedSession("正式問候語")
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("嗨大家好喔", location: 3)
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                     // 鎖定
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(key.ops.isEmpty)                       // 緩衝模式：全程零鍵盤事件
    #expect(ax.calls.count == 1)
    #expect(ax.calls[0].location == 3 && ax.calls[0].expected == "嗨大家好喔" && ax.calls[0].new == "正式問候語")
    #expect(c.ledger.sessionText == "正式問候語")
    #expect(c.ledger.canUndo)                      // 復原可回到原選取文字
    #expect(hud.states.contains(.notice("已替換選取")))
}

@MainActor
@Test func selectionNewContentAlsoReplacesSelection() async {
    let intent = GatedIntentService()
    intent.outcome = .newContent("大家好。")
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("嗨嗨", location: 0)
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("大家好"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(ax.calls.last?.new == "大家好。")       // 取代選取（與選字後打字同語意）
    #expect(key.ops.isEmpty)
}

@MainActor
@Test func selectionIntentCarriesSelectionContext() async {
    let intent = GatedIntentService()
    let reader = FakeFieldReader()
    var field = selectionField("目標文字", location: 5)
    field.contextBefore = "前文"
    field.contextAfter = "後文"
    reader.context = field
    let (c, _, _, _, _, _) = makeController(polisher: intent, rangeReplacer: FakeRangeReplacer(), fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改一下"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    let ctx = intent.calls.last?.context
    #expect(ctx?.targetKind == .selection)
    #expect(ctx?.targetText == "目標文字")
    #expect(ctx?.contextBefore == "前文" && ctx?.contextAfter == "後文")
}

@MainActor
@Test func selectionChangedAbandonsToClipboardAndArchives() async {
    let intent = GatedIntentService()
    intent.outcome = .editedSession("結果文字")
    let ax = FakeRangeReplacer()
    ax.verifyResult = .mismatch                    // 使用者點了別處，選取已變
    let reader = FakeFieldReader()
    reader.context = selectionField("原選取", location: 2)
    let spy = ClipboardSpy()
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, clipboard: spy, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改一下"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(spy.texts == ["結果文字"])              // 結果進剪貼簿供貼上（規格 §3.6）
    #expect(key.ops.isEmpty)                       // 欄位分毫未動
    #expect(!c.ledger.isActive)                    // session 結束
    #expect(hud.states.contains(.notice("選取已變動，結果已入剪貼簿")))
}

@MainActor
@Test func selectionWithoutAXTypesOverAndFreezes() async {
    let intent = GatedIntentService()
    intent.outcome = .newContent("替換文。")
    let reader = FakeFieldReader()
    reader.context = selectionField("舊字", location: 0)
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: nil, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("替換文"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(key.ops == [.insert("替換文。")])       // 打字蓋選取（系統原生行為）
    #expect(c.ledger.frozen)                       // 立即凍結：無 AX 不可續改（M3 設計裁決 3）
    #expect(c.ledger.sessionText == "替換文。")
    #expect(hud.states.contains(.notice("已取代選取（此 App 不支援後續語音修正）")))
}

@MainActor
@Test func selectionEscDiscardsBufferWithoutBackspace() {
    let intent = GatedIntentService()
    let reader = FakeFieldReader()
    reader.context = selectionField("選取", location: 0)
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: FakeRangeReplacer(), fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("講到一半"), at: 11.0)
    c.escapePressed()
    #expect(key.ops.isEmpty)                       // 螢幕上本來就沒字，不得退格
}

@MainActor
@Test func selectionVolatileShowsSelectionListeningHUD() {
    let intent = GatedIntentService()
    let reader = FakeFieldReader()
    reader.context = selectionField("選取", location: 0)
    let (c, _, _, _, _, hud) = makeController(polisher: intent, rangeReplacer: FakeRangeReplacer(), fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.volatile("欸"), at: 11.0)
    #expect(hud.states.contains(.selectionListening(mode: .locked, volatile: "欸")))
}

@MainActor
@Test func selectionUndoAfterReplaceRestoresOriginalText() async {
    let intent = GatedIntentService()
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"), "復原上一步": .undo]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let (c, _, _, _, _, _) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastIntentTask?.value                   // 首句落地，session 轉常規
    c.handleTranscript(.finalized("復原上一步"), at: 14.0)
    c.tick(at: 15.6)
    await c.lastIntentTask?.value
    #expect(ax.calls.last?.new == "原文字")          // 復原＝物理換回原選取文字
    #expect(c.ledger.sessionText == "原文字")
}

@MainActor
@Test func secureFieldWinsOverSelection() {
    let intent = GatedIntentService()
    let reader = FakeFieldReader()
    var field = selectionField("password123", location: 0)
    field.isSecure = true
    reader.context = field
    let (c, audio, _, _, _, _) = makeController(polisher: intent, fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    #expect(audio.startCount == 0)                  // 不錄音（M2 既有行為，選取不得繞過）
    #expect(!c.ledger.isActive)
}

// MARK: - 選取 session 進階：在途後續句、凍結競態、延續窗（Task 6）

@MainActor
@Test func bufferedSecondUtteranceAppendsAfterSelectionReplaced() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                           "然後補一句": .newContent("補充內容。")]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)                                // 首句在途（gated）
    c.handleTranscript(.finalized("然後補一句"), at: 13.0)
    c.tick(at: 14.6)                                // 第二句也被緩衝（key.ops 仍空）
    #expect(key.ops.isEmpty)
    intent.release()                                // 放行首句；串行化：首句先落地
    await c.lastIntentTask?.value
    #expect(ax.calls.first?.new == "正式版")         // 首句：AX 替換選取
    // makeController 的 pasteThreshold 預設 100：5 字必走 keystroke（此斷言依賴該預設；
    // paste/keystroke 門檻切換行為本身由 InsertionTests 的 fallback 測試涵蓋）
    #expect(key.ops == [.insert("補充內容。")])      // 第二句：緩衝落地＝直接鍵入接在 span 尾端
    #expect(c.ledger.sessionText == "正式版補充內容。")
}

@MainActor
@Test func bufferedUndoAfterSelectionReplaceRevertsToOriginal() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                           "復原上一步": .undo]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)                                // 首句在途（gated）
    c.handleTranscript(.finalized("復原上一步"), at: 13.0)
    c.tick(at: 14.6)                                // undo 句也被緩衝（首句尚未落地）
    intent.release()
    await c.lastIntentTask?.value
    // 串行化：首句先替換選取（counter 前進），緩衝 undo 句再以「現時」counter 快照執行——
    // 若誤用該句的舊快照，counter 過期會被 tailAdvanced 擋下、復原永遠失敗（互審 finding）
    #expect(ax.calls.first?.new == "正式版")
    #expect(ax.calls.last?.new == "原文字")
    #expect(c.ledger.sessionText == "原文字")
    #expect(key.ops.isEmpty)                        // 全程零鍵盤事件
}

@MainActor
@Test func bufferedUtteranceAfterAbandonIsDropped() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                           "第二句": .newContent("第二句。")]
    let ax = FakeRangeReplacer()
    ax.verifyResult = .mismatch                     // 首句落地時發現選取已變 → 放棄＋封存
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 0)
    let spy = ClipboardSpy()
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, clipboard: spy, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)
    c.handleTranscript(.finalized("第二句"), at: 13.0)
    c.tick(at: 14.6)
    intent.release()
    await c.lastIntentTask?.value
    #expect(key.ops.isEmpty)                        // 封存後第二句被 isActive 守衛丟棄，欄位分毫未動
    #expect(spy.texts == ["正式版"])
}

@MainActor
@Test func freezeDuringSelectionPendingAbandonsToClipboard() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版")]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 0)
    let spy = ClipboardSpy()
    let (c, _, _, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, clipboard: spy, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)                                // 在途
    c.userActivityDetected(at: 13.0)                // 使用者動了鍵盤／滑鼠：聽寫中＝凍結
    intent.release()
    await c.lastIntentTask?.value
    #expect(ax.calls.isEmpty && key.ops.isEmpty)    // 凍結後不得替換（選取完整性不明）
    #expect(spy.texts == ["正式版"])
}

@MainActor
@Test func frozenAfterSelectionReplacedRescuesBufferedNewContentToClipboard() async {
    // Freeze-race（終審 finding）：首句替換選取成功後轉 .tail、帳本仍活著（未凍結）；
    // 第二句在首句 LLM 在途時就被緩衝（wasBuffered=true）。首句落地後、第二句 LLM 尚未回來時
    // 使用者手動活動觸發凍結——第二句的緩衝 .newContent 落地必須守 frozen（規格 §3.4「文字定稿、不再改寫」），
    // 不得再 insertDetached 合成鍵入（游標可能已被使用者移走），改走剪貼簿急救。
    let intent = GatedIntentService()
    intent.gatedRaws = ["第二句"]                    // 只卡第二句：首句立即回、可在凍結前落地
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                           "第二句": .newContent("補充內容。")]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let spy = ClipboardSpy()
    let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, clipboard: spy, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("改正式一點"), at: 11.0)
    c.tick(at: 12.6)                                // 首句：緩衝＋建 task（body 尚未跑）
    let first = c.lastIntentTask
    c.handleTranscript(.finalized("第二句"), at: 13.0)
    c.tick(at: 14.6)                                // 第二句：仍 .selectionPending → 緩衝（wasBuffered=true）
    await first?.value                              // 放行首句：AX 替換選取→ .tail、commit「正式版」、未凍結；第二句卡在 LLM gate
    #expect(c.ledger.sessionText == "正式版")
    c.userActivityDetected(at: 15.0)               // 首句落地後、第二句在途時：使用者動手＝凍結
    #expect(c.ledger.frozen)
    intent.release()                                // 放行第二句 LLM → dispatch 走緩衝 .newContent 路徑（此時已凍結）
    await c.lastIntentTask?.value
    #expect(key.ops.isEmpty)                        // 凍結後緩衝句不得合成鍵入到欄位（write-after-hands-off）
    #expect(spy.texts == ["補充內容。"])            // 改走剪貼簿急救
    #expect(c.ledger.sessionText == "正式版")       // dispatch 未改動已定稿文字
    #expect(hud.states.contains(.notice("已凍結，內容已入剪貼簿")))
}

@MainActor
@Test func lingerResumeKeepsSelectionPendingTarget() async {
    let intent = GatedIntentService()
    intent.outcome = .editedSession("正式版")
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let (c, _, asr, key, _, _) = makeController(polisher: intent, rangeReplacer: ax, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.5)   // 按住模式，沒說話就放開
    asr.continuation?.finish()
    c.asrStreamEnded(at: 10.6)                      // 進延續窗（ledger 帶著選取種子活著）
    #expect(c.isLingering)
    c.hotkeyPressed(at: 12.0); c.hotkeyReleased(at: 12.1)   // 延續窗內再按＝resume
    c.handleTranscript(.finalized("改正式一點"), at: 13.0)
    c.tick(at: 14.6)
    await c.lastIntentTask?.value
    #expect(ax.calls.last?.new == "正式版")          // resume 後選取目標仍有效
    #expect(key.ops.isEmpty)
}

/// 實機驗收缺口（M3 驗收項 4）：說完指令→放開→進延續窗→點別處（延續窗活動＝立即封存）
/// →LLM 此刻才回來。封存後的緩衝 outcome 不得無聲蒸發——原文從未上屏，丟棄＝使用者白說話。
@MainActor
@Test func selectionOutcomeAfterLingerArchiveRescuesToClipboard() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版")]
    let ax = FakeRangeReplacer()
    let reader = FakeFieldReader()
    reader.context = selectionField("原文字", location: 4)
    let spy = ClipboardSpy()
    let (c, _, asr, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax,
                                                  clipboard: spy, fieldReader: reader)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("改正式一點"), at: 10.5)
    c.hotkeyReleased(at: 11.0)                      // 長按放開 → 排空
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.1)                      // 排空結束 → 延續窗（LLM 在途）
    #expect(c.isLingering)
    c.userActivityDetected(at: 11.5)                // 延續窗點別處 ＝ 立即封存
    #expect(!c.ledger.isActive)
    intent.release()                                // LLM 結果此刻才回來
    await c.lastIntentTask?.value
    #expect(spy.texts == ["正式版"])                 // 結果救進剪貼簿（規格 §3.6）
    #expect(key.ops.isEmpty)                        // 欄位分毫未動
    #expect(hud.states.contains(.notice("選取已變動，結果已入剪貼簿")))
    #expect(ax.calls.isEmpty)                       // 封存後不得再碰選取
}

// MARK: - M2 債清償：密碼欄位聽寫中切入、lostText 剪貼簿急救

@MainActor
@Test func secureFieldMidSessionStopsInsertionAndSession() {
    let intent = GatedIntentService()
    let reader = FakeFieldReader()
    let (c, audio, asr, key, _, hud) = makeController(polisher: intent, fieldReader: reader)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)      // 鎖定
    c.handleTranscript(.finalized("正常內容"), at: 11.0)
    #expect(key.ops == [.insert("正常內容")])
    reader.context = FieldContext(hasFocusedElement: true, isSecure: true)   // 焦點移進密碼欄
    c.handleTranscript(.finalized("這段不可上屏"), at: 12.0)
    #expect(key.ops == [.insert("正常內容")])                   // 一個字都不准再進欄位
    #expect(!c.ledger.isActive)                                 // session 硬停
    #expect(audio.stopCount == 1)                               // 不再錄音（規格 §5.3）
    #expect(asr.cancelCount == 1)
    #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
}

@MainActor
@Test func lostTextFallsBackToClipboardRescue() async {
    let intent = GatedIntentService()
    intent.outcome = .newContent("第一句。")
    let paste = RecordingInserter()
    let spy = ClipboardSpy()
    let (c, _, _, key, _, _) = makeController(polisher: intent, pasteInserter: paste, clipboard: spy)
    c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("第一句"), at: 11.0)          // 原文上屏成功
    key.failInsertsRemaining = 2                                // 之後的插入全失敗：
    paste.failInsertsRemaining = 2                              // 新文（主/副）＋原文回復（主/副）
    c.tick(at: 12.6)
    await c.lastIntentTask?.value
    #expect(spy.texts == ["第一句"])                             // 鐵律最後手段：原文進剪貼簿
}

/// 規格 §4.5「per-session 臨時覆蓋」：session 結束（封存）即失效
@MainActor
@Test func sessionLanguageOverrideClearsOnArchive() {
    let (c, _, asr, _, _, _) = makeController()
    c.settings.sessionLanguageOverride = .english
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)                      // 長按結束 → 排空
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.1)                      // 延續窗（session 未結束，覆蓋仍在）
    #expect(c.settings.sessionLanguageOverride == .english)
    c.escapePressed()                               // 延續窗 Esc ＝ 封存
    #expect(c.settings.sessionLanguageOverride == nil)
}

/// 設計裁決 4「archive 時自動清除」：聽寫中 Esc 中止也是封存路徑，須清除 session 級語系覆蓋
@MainActor
@Test func sessionLanguageOverrideClearsOnEscapeAbortDuringListening() {
    let (c, _, _, _, _, _) = makeController()
    c.settings.sessionLanguageOverride = .english
    c.hotkeyPressed(at: 10.0)                        // 聽寫中（hold）
    c.handleTranscript(.finalized("測試"), at: 10.5)
    c.escapePressed()                               // 聽寫中 Esc ＝ 中止並封存
    #expect(c.settings.sessionLanguageOverride == nil)
}

/// 設計裁決 4：延續窗中改在密碼欄按下＝封存前一 session，session 級語系覆蓋須一併清除
@MainActor
@Test func sessionLanguageOverrideClearsWhenSecureFieldAbortsPendingSession() {
    let reader = FakeFieldReader()
    reader.context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: 0)
    let (c, _, asr, _, _, _) = makeController(fieldReader: reader)
    c.settings.sessionLanguageOverride = .english
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)                      // 延續窗（覆蓋仍在）
    reader.context = FieldContext(hasFocusedElement: true, isSecure: true)
    c.hotkeyPressed(at: 12.0)                       // 密碼欄按下＝封存前一 session
    #expect(c.settings.sessionLanguageOverride == nil)
}

/// 設計裁決 4：麥克風啟動失敗＝session 夭折封存，session 級語系覆蓋須清除
@MainActor
@Test func sessionLanguageOverrideClearsOnMicFailure() {
    let (c, audio, _, _, _, _) = makeController()
    c.settings.sessionLanguageOverride = .english
    audio.failNextStart = true
    c.hotkeyPressed(at: 10.0)                        // 麥克風啟動失敗
    #expect(c.settings.sessionLanguageOverride == nil)
}
