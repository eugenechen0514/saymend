import Testing
@testable import SpeeckinkApp

@Suite struct AXContextWindowTests {
    @Test func windowsAroundSelection() {
        let value = "0123456789ABCDEFGHIJ"
        let w = AXFieldAccess.contextWindows(value: value, selectionLocation: 8, selectionLength: 2, window: 5)
        #expect(w.before == "34567")
        #expect(w.after == "ABCDE")
    }

    @Test func windowsClampAtBoundaries() {
        let value = "abcdef"
        let w = AXFieldAccess.contextWindows(value: value, selectionLocation: 1, selectionLength: 0, window: 100)
        #expect(w.before == "a")
        #expect(w.after == "bcdef")
    }

    @Test func windowsDoNotSplitSurrogatePairs() {
        // "🎉" 佔 2 個 UTF-16 unit（D83C DF89）：窗口邊界落在 pair 中間時要讓開，不得產生半個字
        let value = "🎉🎉🎉x🎉🎉🎉"           // UTF-16: [0,2,4] 是 🎉 的起點，6 是 x，7、9、11 是 🎉
        let w = AXFieldAccess.contextWindows(value: value, selectionLocation: 6, selectionLength: 1, window: 3)
        #expect(!w.before.unicodeScalars.contains { $0.value == 0xFFFD })
        #expect(!w.after.unicodeScalars.contains { $0.value == 0xFFFD })
        #expect(w.before == "🎉")            // 窗口 3 units 只裝得下一個完整 🎉（邊界讓開半個）
        #expect(w.after == "🎉")
    }

    @Test func emptyValueYieldsEmptyWindows() {
        let w = AXFieldAccess.contextWindows(value: "", selectionLocation: 0, selectionLength: 0, window: 10)
        #expect(w.before == "" && w.after == "")
    }
}
