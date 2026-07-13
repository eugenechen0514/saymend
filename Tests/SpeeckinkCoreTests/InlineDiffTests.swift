import Testing
@testable import SpeeckinkCore

@Suite struct InlineDiffTests {
    @Test func singleReplacementProducesOneWindow() {
        let w = InlineDiff.windows(old: "我們星期二開會討論", new: "我們星期三開會討論")
        #expect(w.count == 1)
        #expect(w[0].ops.contains(.deleted("二")))
        #expect(w[0].ops.contains(.added("三")))
    }

    @Test func keptContextTrimsToWindowWithEllipsis() {
        let old = String(repeating: "甲", count: 40) + "舊" + String(repeating: "乙", count: 40)
        let new = String(repeating: "甲", count: 40) + "新" + String(repeating: "乙", count: 40)
        let w = InlineDiff.windows(old: old, new: new, context: 15)
        #expect(w.count == 1)
        guard case .kept(let lead) = w[0].ops.first else { Issue.record("首段應為 kept"); return }
        guard case .kept(let tail) = w[0].ops.last else { Issue.record("尾段應為 kept"); return }
        #expect(lead == "…" + String(repeating: "甲", count: 15))
        #expect(tail == String(repeating: "乙", count: 15) + "…")
    }

    @Test func farApartChangesSplitIntoTwoWindows() {
        let old = "開頭錯字" + String(repeating: "中", count: 80) + "結尾錯字"
        let new = "開頭對字" + String(repeating: "中", count: 80) + "結尾對字"
        #expect(InlineDiff.windows(old: old, new: new, context: 15).count == 2)
    }

    @Test func identicalTextsYieldNoWindows() {
        #expect(InlineDiff.windows(old: "一樣", new: "一樣").isEmpty)
    }

    @Test func pureInsertionAndDeletion() {
        let ins = InlineDiff.windows(old: "前後", new: "前中後")
        #expect(ins.count == 1 && ins[0].ops.contains(.added("中")))
        let del = InlineDiff.windows(old: "前中後", new: "前後")
        #expect(del.count == 1 && del[0].ops.contains(.deleted("中")))
    }

    @Test func changedSpanCoversReplacedRegionInNew() {
        let span = InlineDiff.changedSpanUTF16(old: "我們星期二開會", new: "我們星期三開會")
        #expect(span == SpanUTF16(location: 4, length: 1))
    }

    @Test func changedSpanForAppendCoversAppendedTail() {
        let span = InlineDiff.changedSpanUTF16(old: "第一句", new: "第一句第二句。")
        #expect(span == SpanUTF16(location: 3, length: 4))
    }

    @Test func changedSpanNilWhenIdentical() {
        #expect(InlineDiff.changedSpanUTF16(old: "同", new: "同") == nil)
    }

    @Test func changedSpanZeroLengthForPureDeletion() {
        let span = InlineDiff.changedSpanUTF16(old: "留刪留", new: "留留")
        #expect(span == SpanUTF16(location: 1, length: 0))
    }

    @Test func changedSpanCountsSurrogatePairsInUTF16() {
        let span = InlineDiff.changedSpanUTF16(old: "a🎉b", new: "a🎉c")   // 🎉＝2 UTF-16 units
        #expect(span == SpanUTF16(location: 3, length: 1))
    }

    @Test func oversizedInputsDegradeToWholeReplacement() {
        let old = String(repeating: "舊", count: 700)
        let new = String(repeating: "新", count: 700)
        let w = InlineDiff.windows(old: old, new: new)
        #expect(w.count == 1)                        // 超限不做 LCS：單一「整段刪＋整段加」窗口
        #expect(w[0].ops.contains(.deleted(old)))
        #expect(w[0].ops.contains(.added(new)))
    }
}
