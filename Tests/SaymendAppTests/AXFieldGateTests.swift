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
///
/// **`readSubrole` 一律注入**（`notSecureRead`）：`fieldGate` 的 secure 判定走的是 issue #59 的三態
/// `isSecureField`，逾時兩次就 fail closed 成 `.secure`。不注入的話，這些測試的結果會取決於
/// 「那個 pid 的行程回不回應 AX」——launchd（pid 1）就不回應，`.different` 那條會變成 `.secure`。
/// 本 suite 要驗的是 identity 比對，不是 AX 的回應性；secure 路徑另有專屬測試。
@Suite struct AXFieldGateTests {

    private let me = ProcessInfo.processInfo.processIdentifier

    /// 「問到了，這個元素沒有 subrole 屬性」——#59 的 `secureVerdict` 對此維持寬鬆（`.notSecure`），
    /// 大量非 AX-rich 欄位本來就落在這裡。用它把 secure 判定固定成不擋，讓測試只驗 identity 比對。
    private let notSecureRead: (AXUIElement) -> (AXError, String?) = { _ in (.attributeUnsupported, nil) }

    /// 讀不到焦點＝`.unknown`（維持 #21：呼叫端照常追加），不是 `.different`。
    @Test func noFocusedElementIsUnknown() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { nil })
        #expect(reader.fieldGate(sessionIdentity: token) == .unknown)
    }

    /// session 沒有 identity（無 AX 的 App）＝`.unknown`，即使現在讀得到焦點元素。
    @Test func nilSessionIdentityIsUnknown() {
        let r = AXFieldRegistry()
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: nil) == .unknown)
    }

    /// 焦點還是同一個元素（CFEqual 相等的另一個 wrapper）＝`.same`。
    @Test func sameElementIsSame() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
    }

    /// 焦點換到別的元素＝`.different`（bundleID 取自 NSWorkspace 前景 App，測試行程不保證有值，只斷言 case）。
    @Test func anotherElementIsDifferent() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { AXUIElementCreateApplication(1) })   // launchd
        guard case .different = reader.fieldGate(sessionIdentity: token) else {
            Issue.record("焦點已換到別的元素，閘門必須回 .different")
            return
        }
    }

    /// session archive 後 token 已釋放：即使焦點還在同一元素，舊 token 也不得回 `.same`。
    @Test func releasedTokenIsNoLongerTheSameField() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { AXUIElementCreateApplication(self.me) })
        r.release(token)
        #expect(reader.fieldGate(sessionIdentity: token) != .same)
    }

    // MARK: - §5.3 secure 判定（走 issue #59 的三態 isSecureField，這裡驗的是 fieldGate 這條路徑）

    /// subrole 連續兩次逾時＝問不出來，閘門必須擋（fail closed）。
    /// 同時釘住**恰好問兩次**：只問一次等於把 header 對 `cannotComplete` 建議的重試拿掉、
    /// 一次逾時就判死；無限重試則會在卡住的 App 上把每句上屏拖成 N×200ms。
    @Test func subroleTimingOutTwiceMakesTheGateSecure() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        var reads = 0
        let reader = AXFieldReader(registry: r,
                                   readSubrole: { _ in
                                       reads += 1
                                       return (.cannotComplete, nil)
                                   },
                                   focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .secure)
        #expect(reads == 2, "逾時要重試一次，且只重試一次")
    }

    /// 重試救得回來：第二次問到了、不是密碼欄，閘門就照常往下做 identity 比對。
    /// 沒有這條的話，「重試」可以被實作成一個不影響結果的裝飾動作。
    @Test func subroleAnsweringOnRetryProceedsToIdentityComparison() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        var reads = 0
        let reader = AXFieldReader(registry: r,
                                   readSubrole: { _ in
                                       reads += 1
                                       return reads == 1 ? (.cannotComplete, nil) : (.success, "AXStandardWindow")
                                   },
                                   focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
        #expect(reads == 2)
    }

    /// **lease 不變式（#43）**：閘門只能用 `registry.matches`，不得呼叫 `identity(for:)`——
    /// 後者會替焦點元素多留一個持有者，session 起始那個 token 就再也死不掉。
    @Test func gateDoesNotAddAnyHolder() {
        let r = AXFieldRegistry()
        let token = r.identity(for: AXUIElementCreateApplication(me))
        let reader = AXFieldReader(registry: r, readSubrole: notSecureRead, focusedElement: { AXUIElementCreateApplication(self.me) })
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
        #expect(reader.fieldGate(sessionIdentity: token) == .same)
        #expect(r.entryCount == 1, "閘門不得替焦點元素登記新 entry")
        r.release(token)                                    // 只有 identity(for:) 發出的那一份持有者
        #expect(!r.matches(token, element: AXUIElementCreateApplication(me)),
                "閘門若呼叫 identity(for:)，這裡的 token 會因為多出來的持有者而不死")
    }
}
