import ApplicationServices
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #37 shadow 階段：`AXFieldReader.fieldGate` 的輕量閘門。
/// 元素用 `AXUIElementCreateApplication(pid)` 建（不需要輔助使用權限）；不同 pid 即不同元素、CFEqual 判同。
/// `focusedElement` 注入讓這道閘門不需要真的焦點就能驗（比照 AXInserterIdentityGateTests）。
///
/// 這裡驗不到的：真正的密碼欄位 subrole（測試行程建不出 `AXSecureTextField` 元素），
/// 以及「每句 AX IPC 從 4–5 降到 2」這個成本面事實——只能靠實機驗證。
@Suite struct AXFieldGateTests {

    private let me = ProcessInfo.processInfo.processIdentifier

    /// 讀不到焦點＝`.unknown`（維持 #21：呼叫端照常追加），不是 `.different`。
    @Test func noFocusedElementIsUnknown() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, focusedElement: { nil })
        #expect(reader.fieldGate(sessionIdentity: token) == .unknown)
    }

    /// session 沒有 identity（無 AX 的 App）＝`.unknown`，即使現在讀得到焦點元素。
    @Test func nilSessionIdentityIsUnknown() {
        let r = AXFieldRegistry()
        let reader = AXFieldReader(registry: r, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: nil) == .unknown)
    }

    /// 焦點還是同一個元素（CFEqual 相等的另一個 wrapper）＝`.same`。
    @Test func sameElementIsSame() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
    }

    /// 焦點換到別的元素＝`.different`（bundleID 取自 NSWorkspace 前景 App，測試行程不保證有值，只斷言 case）。
    @Test func anotherElementIsDifferent() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, focusedElement: { AXUIElementCreateApplication(1) })   // launchd
        guard case .different = reader.fieldGate(sessionIdentity: token) else {
            Issue.record("焦點已換到別的元素，閘門必須回 .different")
            return
        }
    }

    /// session archive 後 token 已釋放：即使焦點還在同一元素，舊 token 也不得回 `.same`。
    @Test func releasedTokenIsNoLongerTheSameField() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, focusedElement: { AXUIElementCreateApplication(self.me) })
        r.release(token)
        #expect(reader.fieldGate(sessionIdentity: token) != .same)
    }

    /// **lease 不變式（#43）**：閘門只能用 `registry.matches`，不得呼叫 `identity(for:)`——
    /// 後者會替焦點元素多留一個持有者，session 起始那個 token 就再也死不掉。
    @Test func gateDoesNotAddAnyHolder() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
        #expect(r.entryCount == 1, "閘門不得替焦點元素登記新 entry")
        r.release(token)                                    // 只有 identity(for:) 發出的那一份持有者
        #expect(!r.matches(token, element: AXUIElementCreateApplication(me)),
                "閘門若呼叫 identity(for:)，這裡的 token 會因為多出來的持有者而不死")
    }
}
