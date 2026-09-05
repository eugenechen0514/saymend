import Testing
@testable import SaymendCore

/// issue #43：欄位 identity 的 opaque token 語意。Core 不認識 AXUIElement，registry 以注入的
/// `areEqual` 判同一元素；production 端用 CFEqual（AXFieldAccess），這裡用可控的假元素釘住契約。
///
/// 為什麼要 refcount：reader→ledger 與 FeedbackCoordinator 會各自 pin **同一個** element。
/// 不計數的話，先釋放的那一方會把另一方仍在用的 token 弄死（`matches` 變 false → overlay 中途消失，
/// 或 #44 的刪字驗證誤判 fail closed）。
@Suite struct FieldIdentityRegistryTests {

    /// 假元素：identity 由 `id` 決定，`label` 刻意可相同——模擬「兩個欄位 offset／文字都一樣但不是同一個」
    struct Element { let id: Int; let label: String }
    private func makeRegistry() -> FieldIdentityRegistry<Element> {
        FieldIdentityRegistry(areEqual: { $0.id == $1.id })
    }

    @Test func sameElementYieldsSameToken() {
        let r = makeRegistry()
        let a1 = r.identity(for: Element(id: 1, label: "x"))
        let a2 = r.identity(for: Element(id: 1, label: "x"))
        #expect(a1 == a2)
        #expect(r.count == 1)
    }

    @Test func distinctElementsWithIdenticalLabelYieldDistinctTokens() {
        let r = makeRegistry()
        let a = r.identity(for: Element(id: 1, label: "同樣的字"))
        let b = r.identity(for: Element(id: 2, label: "同樣的字"))
        #expect(a != b, "label 相同不代表同一個欄位——這正是 offset+text 錨點抓不到的情況")
        #expect(r.matches(a, element: Element(id: 1, label: "")))
        #expect(!r.matches(a, element: Element(id: 2, label: "")))
    }

    @Test func tokenSurvivesUntilEveryHolderReleases() {
        let r = makeRegistry()
        let e = Element(id: 7, label: "")
        let fromReader = r.identity(for: e)       // reader 在熱鍵按下時 pin
        let fromFeedback = r.identity(for: e)     // FeedbackCoordinator 首繪時 pin 同一元素
        #expect(fromReader == fromFeedback)
        r.release(fromReader)                     // ledger archive
        #expect(r.matches(fromFeedback, element: e), "另一方仍持有，token 不得失效")
        #expect(r.count == 1)
        r.release(fromFeedback)                   // feedback sessionEnded
        #expect(!r.matches(fromFeedback, element: e), "全部釋放後 stale token 不得再匹配")
        #expect(r.count == 0)
    }

    @Test func releasedElementGetsAFreshTokenNextTime() {
        let r = makeRegistry()
        let e = Element(id: 3, label: "")
        let old = r.identity(for: e)
        r.release(old)
        let fresh = r.identity(for: e)
        #expect(fresh != old, "釋放後重新登記必須是新 token——舊 session 殘留的 token 不能對上新 session 的欄位")
        #expect(!r.matches(old, element: e))
        #expect(r.matches(fresh, element: e))
    }

    @Test func releasingNilOrUnknownIsANoOp() {
        let r = makeRegistry()
        let a = r.identity(for: Element(id: 1, label: ""))
        r.release(nil)
        r.release(FieldIdentity(token: 9999))
        #expect(r.matches(a, element: Element(id: 1, label: "")))
        #expect(r.count == 1)
    }

    @Test func overReleaseDoesNotUnderflowOrResurrect() {
        let r = makeRegistry()
        let e = Element(id: 5, label: "")
        let a = r.identity(for: e)
        r.release(a)
        r.release(a)                              // 多釋放一次
        #expect(r.count == 0)
        let b = r.identity(for: e)
        #expect(b != a)
        #expect(r.count == 1)
        r.release(b)
        #expect(r.count == 0, "多釋放不得讓計數變負、導致下一個 token 永遠釋放不掉")
    }
}
