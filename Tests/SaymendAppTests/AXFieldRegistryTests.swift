import ApplicationServices
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #43：App 端 registry 以 **CFEqual** 判同一 AXUIElement。
/// 建立 AXUIElement 不需要輔助使用權限（只有讀屬性才要），所以這裡能在測試行程裡拿到真的元素：
/// `AXUIElementCreateSystemWide()` 每次回新 wrapper 但指向同一元素；`AXUIElementCreateApplication(pid)` 不同 pid 即不同元素。
@Suite struct AXFieldRegistryTests {

    @Test func twoWrappersOfTheSameElementShareOneToken() {
        let r = AXFieldRegistry()
        let a = r.identity(for: AXUIElementCreateSystemWide())
        let b = r.identity(for: AXUIElementCreateSystemWide())
        #expect(a == b, "CFEqual 相等的 wrapper 必須拿到同一個 token（Swift `===` 或 CFHash 都不是這個語意）")
        #expect(r.matches(a, element: AXUIElementCreateSystemWide()))
    }

    @Test func differentProcessesYieldDifferentTokens() {
        let r = AXFieldRegistry()
        let me = ProcessInfo.processInfo.processIdentifier
        let a = r.identity(for: AXUIElementCreateApplication(me))
        let b = r.identity(for: AXUIElementCreateApplication(1))       // launchd
        #expect(a != b)
        #expect(!r.matches(a, element: AXUIElementCreateApplication(1)))
    }

    @Test func releaseDropsOnlyOneHolder() {
        let r = AXFieldRegistry()
        let e = AXUIElementCreateSystemWide()
        let fromReader = r.identity(for: e)
        let fromFeedback = r.identity(for: e)
        r.release(fromReader)
        #expect(r.matches(fromFeedback, element: e))
        r.release(fromFeedback)
        #expect(!r.matches(fromFeedback, element: e))
    }

    /// AXFieldReader 走同一個 registry：它歸還的就是 registry 的持有數。
    @Test func readerReleaseGoesThroughTheSharedRegistry() {
        let r = AXFieldRegistry()
        let reader = AXFieldReader(registry: r)
        let id = r.identity(for: AXUIElementCreateSystemWide())
        reader.releaseFieldIdentity(id)
        #expect(!r.matches(id, element: AXUIElementCreateSystemWide()))
    }

    /// snapshot(of:) 對任一元素都要把 identity 填進 FieldContext——這是 controller 拿到 token 的唯一入口。
    /// 用 system-wide 元素：沒有 AX 權限時屬性讀取全部失敗（非 secure、無 caret），但 identity 仍必須填。
    @Test func snapshotOfElementFillsFieldIdentity() {
        let r = AXFieldRegistry()
        let reader = AXFieldReader(registry: r)
        let e = AXUIElementCreateSystemWide()
        let ctx = reader.snapshot(of: e)
        #expect(ctx.hasFocusedElement)
        #expect(ctx.fieldIdentity != nil)
        #expect(r.matches(ctx.fieldIdentity!, element: AXUIElementCreateSystemWide()))
    }
}
