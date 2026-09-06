import Testing
@testable import SaymendCore

/// issue #40 的驗收：語音「修正」／「復原」的**指令話語本身**（「改一下」「復原」）會先被 ASR 當成
/// 一般轉錄上屏，之後才由 `InsertionCoordinator.replaceSession` 連同 session 全文一起被替換掉。
///
/// replaceSession 失敗的三種 outcome 依 issue #38／#44 的原子契約都是「一個字都沒動」——
/// 指令話語**仍完整留在畫面上**。此時帳本若不鏡像它，它就成為孤兒文字：
///   A1 `ledger.sessionText` 少一段（下一句的 context、Esc 的 expected、field mismatch 判定全部偏掉）
///   A2 `archiveSession()` 寫進 History 的 `finalText` 少一段（歷史頁看到的不是欄位實況）
///   A3 `emitFeedback()` 的底線範圍少一段（overlay 與畫面不一致）
///
/// A3 只對**不凍結**的兩種 outcome 成立：`.fieldMismatch` 一律凍結，而凍結的語意就是底線淡出
/// （`FeedbackCoordinator.sessionFrozen()` 會 `overlay.fadeOutAndHide()`），此時正確行為是不再發 update。
@MainActor
@Suite struct CommandUtteranceOrphanTests {

    private func updates(_ feedback: FakeFeedback) -> [FeedbackUpdate] {
        feedback.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
    }

    // MARK: - 修正路徑（applyCorrection）

    /// `.fieldMismatch`：欄位被外力改動，修正一個字都沒寫。指令話語「改一下」仍在畫面上，
    /// 帳本要鏡像它再凍結——與 `applyNewContent` 及 performUndo 無步驟版的 fieldMismatch 出口一致。
    @Test func correctionFieldMismatchKeepsCommandUtteranceInMirrorAndHistory() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "改一下": .editedSession("首句改。")]
        let ax = FakeRangeReplacer()
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, rangeReplacer: ax,
                                                  feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(c.ledger.sessionText == "首句。")

        ax.verifyResult = .mismatch                       // 欄位被外力改動
        c.handleTranscript(.finalized("改一下"), at: 13.0)  // 指令話語已上屏
        c.tick(at: 14.6); await c.lastIntentTask?.value

        #expect(c.ledger.frozen)
        #expect(hud.states.contains(.notice("欄位已被外部改動，本段停止修正")))
        // A1：指令話語仍在欄位上 → 帳本必須看得到它
        #expect(c.ledger.sessionText == "首句。改一下",
                "指令話語仍在畫面上卻不在帳本裡＝孤兒；實際：\(c.ledger.sessionText)")
        // A3：凍結＝底線淡出，之後不該再發 update
        #expect(feedback.events.last == .frozen)
        // A2：定稿入史要反映欄位實況
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句。改一下",
                "History 的 finalText 少了指令話語；實際：\(history.finished.last?.finalText ?? "nil")")
    }

    /// `.tailAdvanced`：修正在途時下一句已落地，尾端前進。欄位沒動，keepRaw 把指令話語入帳。
    @Test func correctionTailAdvancedKeepsCommandUtteranceInMirrorHistoryAndUnderline() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "改一下": .editedSession("首句改。")]
        polisher.gatedRaws = ["改一下"]
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value

        c.handleTranscript(.finalized("改一下"), at: 13.0)
        c.tick(at: 14.6)                                   // 修正派發、卡 gate；指令話語已上屏
        c.handleTranscript(.finalized("再來一句"), at: 15.0) // counter 前進
        polisher.release(); await c.lastIntentTask?.value

        #expect(hud.states.contains(.notice("未修正（新內容已接續）")))
        #expect(!c.ledger.frozen)
        #expect(c.ledger.sessionText == "首句。改一下")                                    // A1
        #expect(updates(feedback).last?.text == "首句。改一下再來一句")                      // A3：底線含指令話語
        c.userActivityDetected(at: 16.0)                   // 凍結後 Esc 不退字，單純定稿
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句。改一下")                        // A2
    }

    /// `.unverified`：沒有 verified AX（anchor／identity／AX 能力缺一）。同樣一個字沒動。
    @Test func correctionUnverifiedKeepsCommandUtteranceInMirrorHistoryAndUnderline() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "改一下": .editedSession("首句改。")]
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, rangeReplacer: nil,
                                                  feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(c.ledger.sessionText == "首句")             // 無 AX：潤飾也套不上，raw 照留

        c.handleTranscript(.finalized("改一下"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value

        #expect(hud.states.contains(.notice("未修正（無法確認文字位置）")))
        #expect(!c.ledger.frozen)
        #expect(c.ledger.sessionText == "首句改一下")                                      // A1
        #expect(updates(feedback).last?.text == "首句改一下")                              // A3
        c.userActivityDetected(at: 15.0)
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句改一下")                          // A2
    }

    // MARK: - 復原路徑（performUndo，有步驟可回）

    /// `.fieldMismatch`：帳本已 pop 出一版、物理替換卻失敗。`restoreFailedUndo` 把帳本回捲成
    /// 復原前的欄位實況，但那份實況**還多了指令話語「復原」**——它同樣得併回鏡像。
    @Test func undoFieldMismatchKeepsCommandUtteranceInMirrorAndHistory() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "復原": .undo]
        let ax = FakeRangeReplacer()
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, rangeReplacer: ax,
                                                  feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(c.ledger.canUndo)                          // 前提：真的有步驟可回

        ax.verifyResult = .mismatch
        c.handleTranscript(.finalized("復原"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value

        #expect(c.ledger.frozen)
        #expect(hud.states.contains(.notice("欄位已被外部改動，本段停止修正")))
        #expect(c.ledger.sessionText == "首句。復原",
                "復原失敗＝欄位仍是「首句。復原」，帳本要鏡像它；實際：\(c.ledger.sessionText)")   // A1
        #expect(feedback.events.last == .frozen)                                          // A3
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句。復原",
                "History 的 finalText 少了指令話語；實際：\(history.finished.last?.finalText ?? "nil")")  // A2
    }

    /// `.tailAdvanced`：復原在途、下一句已落地。帳本回捲後由 keepRaw 把指令話語入帳。
    @Test func undoTailAdvancedKeepsCommandUtteranceInMirrorHistoryAndUnderline() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "復原": .undo]
        polisher.gatedRaws = ["復原"]
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value

        c.handleTranscript(.finalized("復原"), at: 13.0)
        c.tick(at: 14.6)                                   // 復原派發、卡 gate
        c.handleTranscript(.finalized("再來一句"), at: 15.0) // counter 前進
        polisher.release(); await c.lastIntentTask?.value

        #expect(hud.states.contains(.notice("未復原（新內容已接續）")))
        #expect(!c.ledger.frozen)
        #expect(c.ledger.sessionText == "首句。復原")                                      // A1
        #expect(updates(feedback).last?.text == "首句。復原再來一句")                        // A3
        c.userActivityDetected(at: 16.0)
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句。復原")                          // A2
    }

    /// `.unverified`：無 AX。帳本回捲後 keepRaw 入帳指令話語，且不凍結
    /// （沒給 AX 權限的 App 是常態，凍結會連純追加上屏都停掉）。
    @Test func undoUnverifiedKeepsCommandUtteranceInMirrorHistoryAndUnderline() async {
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"), "復原": .undo]
        let history = FakeHistory()
        let feedback = FakeFeedback()
        let (c, _, _, _, _, hud) = makeController(polisher: polisher, rangeReplacer: nil,
                                                  feedback: feedback, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("首句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(c.ledger.canUndo)                          // keepRaw 也建版本，故有步驟可回

        c.handleTranscript(.finalized("復原"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value

        #expect(hud.states.contains(.notice("未復原（無法確認文字位置）")))
        #expect(!c.ledger.frozen)
        #expect(c.ledger.sessionText == "首句復原")                                        // A1
        #expect(updates(feedback).last?.text == "首句復原")                                // A3
        c.userActivityDetected(at: 15.0)
        c.escapePressed()
        #expect(history.finished.last?.finalText == "首句復原")                            // A2
    }
}
