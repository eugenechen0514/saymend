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
    let polisher = GatedPolisher()
    polisher.outcome = .polished("你好。")
    let (c, _, _, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)                    // 鎖定
    c.handleTranscript(.finalized("呃你好"), at: 11.0)
    c.tick(at: 12.6)                              // 1.6s quiet → 潤飾
    await c.lastPolishTask?.value
    #expect(polisher.calls == ["呃你好"])
    #expect(key.ops == [.insert("呃你好"), .delete(3), .insert("你好。")])
}

@MainActor
@Test func replaceAbortsWhenNextUtteranceStarted() async {
    let polisher = GatedPolisher()
    polisher.gated = true
    polisher.outcome = .polished("第一段。")
    let (c, _, _, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("第一段"), at: 11.0)
    c.tick(at: 12.6)                              // 潤飾發出（被 gate 卡住）
    c.handleTranscript(.finalized("第二段"), at: 13.0)  // 尾端前進
    polisher.release()
    await c.lastPolishTask?.value
    #expect(!key.ops.contains(.delete(3)))        // 不得替換
    #expect(hud.states.contains(.notice("未潤飾")))
}

@MainActor
@Test func degradedKeepsRawAndNotifies() async {
    let polisher = GatedPolisher()
    polisher.outcome = .degraded(reason: "測試")
    let (c, _, _, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)
    c.handleTranscript(.finalized("原文"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastPolishTask?.value
    #expect(key.ops == [.insert("原文")])          // 原文保留，無退格
    #expect(hud.states.contains(.notice("未潤飾")))
}

@MainActor
@Test func streamEndFlushesRemainderThroughPolish() async {
    let polisher = GatedPolisher()
    polisher.outcome = .polished("尾巴。")
    let (c, _, asr, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("尾巴"), at: 11.0)
    c.hotkeyReleased(at: 12.0)                    // 長按結束 → audio.stop
    asr.continuation?.finish()                     // 模擬 ASR 排空後結束
    c.asrStreamEnded(at: 12.1)
    await c.lastPolishTask?.value
    #expect(polisher.calls == ["尾巴"])
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
    let polisher = GatedPolisher()
    polisher.outcome = .polished("你好世界。")
    let (c, _, _, key, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("你好"), at: 10.5)
    c.hotkeyReleased(at: 11.0)                         // 長按放開 → endListening → 進排空窗
    c.handleTranscript(.finalized("世界"), at: 11.1)    // drain 尾端 finalized：仍須上屏＋入 buffer
    c.asrStreamEnded(at: 11.2)                         // 排空結束 → flush → 潤飾整句
    await c.lastPolishTask?.value
    #expect(polisher.calls == ["你好世界"])              // 尾巴「世界」沒被丟
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
    let polisher = GatedPolisher()
    let (c, _, _, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)                                        // session A
    let a = c.sessionID
    c.hotkeyReleased(at: 11.0)                                       // 進排空窗
    c.hotkeyPressed(at: 12.0)                                        // 開 session B
    c.receiveTranscript(.finalized("半句"), session: c.sessionID, at: 12.5)  // B 的半句進 buffer
    c.receiveStreamEnd(session: a, at: 12.6)                         // A 的 stale stream-end → 忽略
    await c.lastPolishTask?.value
    #expect(polisher.calls.isEmpty)                                  // 未被提早切斷潤飾
}

@MainActor
@Test func escapeSkipsPendingFlush() async {
    let polisher = GatedPolisher()
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
    let polisher = GatedPolisher()
    polisher.outcome = .polished("你好。")
    let (c, _, asr, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("呃你好"), at: 10.5)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.2)            // flush → 潤飾
    await c.lastPolishTask?.value
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
    let polisher = GatedPolisher()
    polisher.outcome = .polished("你好。")
    let (c, _, asr, key, _, hud) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("呃你好"), at: 10.5)
    c.userActivityDetected(at: 10.8)      // 使用者手動打字（設計裁決 2）
    #expect(c.ledger.frozen)
    #expect(hud.states.contains(.notice("偵測到手動輸入，本段不再修正")))
    c.hotkeyReleased(at: 11.5)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.6)
    await c.lastPolishTask?.value
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
    let polisher = GatedPolisher()
    let (c, _, _, _, _, _) = makeController(polisher: polisher)
    c.hotkeyPressed(at: 10.0)
    c.hotkeyReleased(at: 10.1)             // 鎖定
    polisher.outcome = .polished("第一句。")
    c.handleTranscript(.finalized("呃第一句"), at: 11.0)
    c.tick(at: 12.6)
    await c.lastPolishTask?.value
    #expect(c.ledger.sessionText == "第一句。")
    polisher.outcome = .degraded(reason: "x")
    c.handleTranscript(.finalized("第二句原文"), at: 13.0)
    c.tick(at: 14.6)
    await c.lastPolishTask?.value
    #expect(c.ledger.sessionText == "第一句。第二句原文")   // degraded 以原文入帳（欄位鏡像）
    #expect(c.ledger.canUndo)
}
