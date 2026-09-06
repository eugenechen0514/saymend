import Testing
@testable import SaymendCore

@MainActor
@Suite struct FeedbackTests {
    @Test func streamingExtendsUnderlineSpan() {
        let fb = FakeFeedback()
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 10, fieldIdentity: FieldIdentity(token: 1))
        let (c, _, _, _, _, _) = makeController(fieldReader: reader, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("第一句"), at: 11.0)
        let updates = fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        #expect(updates.last == FeedbackUpdate(anchor: 10, text: "第一句"))   // 底線＝進行中範圍
    }

    @Test func polishReplacementCarriesHighlightOfChange() async {
        let fb = FakeFeedback()
        let intent = GatedIntentService()
        intent.outcome = .newContent("第一句。")
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0, fieldIdentity: FieldIdentity(token: 1))
        let (c, _, _, _, _, _) = makeController(polisher: intent, fieldReader: reader, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("第一句"), at: 11.0)
        c.tick(at: 12.6)
        await c.lastIntentTask?.value
        let updates = fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        let last = updates.last
        #expect(last?.text == "第一句。")
        #expect(last?.oldText == "第一句")
        #expect(last?.highlight == SpanUTF16(location: 3, length: 1))   // 「。」是異動處
    }

    @Test func freezeEmitsFrozenAndArchiveEmitsEnded() {
        let fb = FakeFeedback()
        let (c, _, _, _, _, _) = makeController(feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("字"), at: 11.0)
        c.userActivityDetected(at: 12.0)             // 聽寫中手動活動＝凍結
        #expect(fb.events.contains(.frozen))
        c.escapePressed()                            // 鎖定中 Esc＝封存
        #expect(fb.events.last == .ended)
    }

    @Test func selectionReplacementEmitsFullSpanHighlight() async {
        let fb = FakeFeedback()
        let intent = GatedIntentService()
        intent.outcome = .editedSession("正式版")
        let ax = FakeRangeReplacer()
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 4, fieldIdentity: FieldIdentity(token: 1),
                                      selectedRange: .init(location: 4, length: 3),
                                      selectedText: "原文字")
        let (c, _, _, _, _, _) = makeController(polisher: intent, rangeReplacer: ax,
                                                fieldReader: reader, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("改正式一點"), at: 11.0)
        c.tick(at: 12.6)
        await c.lastIntentTask?.value
        let updates = fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        let last = updates.last
        #expect(last?.anchor == 4)
        #expect(last?.text == "正式版")
        #expect(last?.oldText == "原文字")
        #expect(last?.highlight == SpanUTF16(location: 0, length: 3))
    }

    @Test func undoEmitsUpdateWithRestoredText() async {
        let fb = FakeFeedback()
        let intent = GatedIntentService()
        // tail session 的第一句 commit 把「空字串」推入版本堆疊（種子＝空），故需先有一次修正
        // 造出非空的前一版「第一句」，undo 才會罩回它——直接對單一 newContent undo 只會回到空字串。
        intent.outcomeByRaw = ["第一句": .newContent("第一句"),
                               "加個句號": .editedSession("第一句。"),
                               "復原上一步": .undo]
        let (c, _, _, _, _, _) = makeController(polisher: intent, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("第一句"), at: 11.0)
        c.tick(at: 12.6)
        await c.lastIntentTask?.value
        c.handleTranscript(.finalized("加個句號"), at: 13.0)
        c.tick(at: 14.6)
        await c.lastIntentTask?.value
        c.handleTranscript(.finalized("復原上一步"), at: 15.0)
        c.tick(at: 16.6)
        await c.lastIntentTask?.value
        let updates = fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        #expect(updates.last?.text == "第一句")       // 復原後底線罩回舊版
    }

    /// issue #54：沒有步驟可回時，指令話語會被 replaceTail 物理退掉（它不是內容）。
    /// 底線必須跟著縮回——否則 overlay 仍罩著已經不在畫面上的「復原」兩字，
    /// 直到下一次任何路徑碰巧呼叫 emitFeedback() 才會修正。
    @Test func undoWithNothingToUndoRetractsUnderlineAfterCommandRemoved() async {
        let fb = FakeFeedback()
        let intent = GatedIntentService()
        intent.outcome = .undo
        let ax = FakeRangeReplacer()
        let (c, _, _, key, _, hud) = makeController(polisher: intent, rangeReplacer: ax, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("復原"), at: 11.0)   // 第一句就是 undo：帳本沒有版本可回
        func updates() -> [FeedbackUpdate] {
            fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        }
        // 缺陷前提：指令話語上屏時底線已延伸到它
        #expect(updates().last?.text == "復原")
        let countBeforeUndo = updates().count

        c.tick(at: 12.6); await c.lastIntentTask?.value

        // 分支身分：走的是「沒步驟可回」＋replaceTail 成功物理退掉指令話語那一支
        #expect(hud.states.contains(.notice("沒有可復原的步驟")))
        #expect(ax.calls.last?.expected == "復原" && ax.calls.last?.new == "")
        #expect(key.ops == [.insert("復原")], "退回走 verified AX，零鍵盤事件")
        #expect(c.ledger.sessionText == "", "指令話語從未入帳，退掉後帳本仍是空的")
        // #54 本體：底線要跟著縮回，且必須是「退掉之後」新發的一筆
        #expect(updates().last?.text == "",
                "底線仍罩著已被退掉的指令話語；實際：\(updates().last?.text ?? "nil")")
        #expect(updates().count == countBeforeUndo + 1, "退掉之後要再發一次 update")
        // 純底線更新：指令話語不是「內容異動」，不該帶 highlight 去畫變更框
        #expect(updates().last?.highlight == nil && updates().last?.oldText == nil)
    }

    /// #54 的對照組：退不掉時（無 verified AX）指令話語仍留在畫面上，底線就該維持罩著它。
    /// 這條把「縮回的 update 只能發生在 replaceTail 成功之後」釘死——把 emitFeedback() 提前到
    /// switch 之前（對 .replaced 而言送出的值完全相同、看不出差別），會在這裡多送一筆空底線而變紅。
    @Test func undoWithNothingToUndoKeepsUnderlineWhenCommandCannotBeRetracted() async {
        let fb = FakeFeedback()
        let intent = GatedIntentService()
        intent.outcome = .undo
        let (c, _, _, _, _, hud) = makeController(polisher: intent, rangeReplacer: nil, feedback: fb)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("復原"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        let updates = fb.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }
        #expect(hud.states.contains(.notice("沒有可復原的步驟")))
        #expect(c.ledger.sessionText == "復原", "退不掉就入帳鏡像它（issue #40）")
        #expect(updates.last?.text == "復原",
                "指令話語仍在畫面上，底線不得縮回；實際：\(updates.last?.text ?? "nil")")
    }
}
