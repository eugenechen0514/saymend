import ApplicationServices
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #44：AXInserter 的 identity 閘門——現在聚焦的元素必須 CFEqual 於 session 起始登記的那個，否則 `.mismatch`，
/// 且**在任何 AX 讀寫之前**就回頭。`focusedElement` 注入讓這道閘門不需要真的焦點就能驗。
/// 元素用 AXUIElementCreateApplication(pid) 建（不需要輔助使用權限）；不同 pid 即不同元素。
@Suite struct AXInserterIdentityGateTests {

    private let me = ProcessInfo.processInfo.processIdentifier

    @Test func focusedElementFromAnotherProcessIsMismatchOnAllThreeOperations() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let inserter = AXInserter(registry: r, focusedElement: { AXUIElementCreateApplication(1) })   // 焦點在 launchd
        #expect(inserter.verifyRange(fieldIdentity: token, location: 0, expected: "") == .mismatch)
        #expect(inserter.replaceVerifiedRange(fieldIdentity: token, location: 0, expected: "", with: "x") == .mismatch)
        #expect(inserter.replaceVerifiedRangePreservingCaret(fieldIdentity: token, location: 0, expected: "", with: "x") == .mismatch)
    }

    @Test func noFocusedElementIsUnsupported() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let inserter = AXInserter(registry: r, focusedElement: { nil })
        #expect(inserter.verifyRange(fieldIdentity: token, location: 0, expected: "") == .unsupported)
        #expect(inserter.replaceVerifiedRange(fieldIdentity: token, location: 0, expected: "", with: "x") == .unsupported)
    }

    /// 同一元素通過閘門後才往下讀值：application 元素沒有 kAXValue，所以落在 `.unsupported`——
    /// 重點是**不是** `.mismatch`，證明 identity 閘門確實放行了同一元素。
    @Test func matchingElementPassesTheGateAndProceedsToValueRead() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let inserter = AXInserter(registry: r, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(inserter.verifyRange(fieldIdentity: token, location: 0, expected: "") == .unsupported)
    }

    /// session archive 後 token 已釋放：即使焦點還在同一元素，舊 token 也不得再通過閘門。
    @Test func releasedTokenIsMismatchEvenOnTheSameElement() {
        let r = AXFieldRegistry()
        let element = AXUIElementCreateApplication(me)
        let token = r.identity(for: element)
        r.release(token)
        let inserter = AXInserter(registry: r, focusedElement: { element })
        #expect(inserter.verifyRange(fieldIdentity: token, location: 0, expected: "") == .mismatch)
    }
}
