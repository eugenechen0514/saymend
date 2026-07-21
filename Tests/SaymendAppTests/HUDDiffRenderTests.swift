import SwiftUI
import Testing
@testable import SaymendApp
@testable import SaymendCore

@Suite struct HUDDiffRenderTests {
    @Test func attributedPreservesTextOrder() {
        let window = DiffWindow(ops: [.kept("前"), .deleted("舊"), .added("新"), .kept("後")])
        let a = HUDView.attributed(window)
        #expect(String(a.characters) == "前舊新後")
    }

    @Test func deletedRunsCarryStrikethroughAndAddedCarryUnderline() {
        let window = DiffWindow(ops: [.kept("前"), .deleted("舊"), .added("新")])
        let a = HUDView.attributed(window)
        var deletedStruck = false, addedUnderlined = false, keptPlain = true
        for run in a.runs {
            let seg = String(a.characters[run.range])
            if seg == "舊" { deletedStruck = (run.strikethroughStyle != nil) }
            if seg == "新" { addedUnderlined = (run.underlineStyle != nil) }
            if seg == "前" { keptPlain = (run.strikethroughStyle == nil && run.underlineStyle == nil) }
        }
        #expect(deletedStruck)      // 刪除＝刪除線（規格 §3.5）
        #expect(addedUnderlined)    // 新增＝底線
        #expect(keptPlain)
    }

    @Test func emptyWindowYieldsEmptyString() {
        #expect(String(HUDView.attributed(DiffWindow(ops: [])).characters).isEmpty)
    }
}
