import Testing
@testable import SaymendCore

@MainActor
@Suite struct FeedbackTests {
    @Test func streamingExtendsUnderlineSpan() {
        let fb = FakeFeedback()
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 10)
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
        let reader = FakeFieldReader(), ax = FakeRangeReplacer()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0)
        let (c, _, _, _, _, _) = makeController(polisher: intent, rangeReplacer: ax,
                                                fieldReader: reader, feedback: fb)
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
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 4,
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
}
