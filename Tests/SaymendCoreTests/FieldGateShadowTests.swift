import Foundation
import Testing
@testable import SaymendCore

/// issue #37 shadow 階段：每句 finalized 上屏前的「重」snapshot 換成輕量 `fieldGate`，
/// 並把「焦點已換」記進診斷——**照常上屏、不攔、不凍、不發 notice**。
///
/// 這個 suite 釘的是「零行為改變」：`insertWouldSkip` 只是觀測資料，任何一條斷言若變成
/// 「文字沒進去」就代表 shadow 被誤實作成攔阻。閘門本身**不修 #37**，它只能關掉
/// W0（session 開始 → 第 N 句抵達）這一段窗口。
@Suite @MainActor struct FieldGateShadowTests {

    private func shadowEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "insertWouldSkip" }
    }

    /// 寬窗口（同 App 換欄位）：session 起在 A，兩句之間頁面 JS 把焦點跳到 B，第二句抵達。
    /// shadow 模式：記一筆診斷，**文字仍照常寫進 B**。
    @Test func focusMovedToAnotherFieldOfTheSameAppRecordsShadowEventAndStillAppends() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        #expect(env.text(in: "A") == "第一句")
        env.focus("B")                                   // 無 keyDown、無 mouseDown、非切 App
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        let shadow = shadowEvents(history)
        #expect(shadow.count == 1)
        #expect(shadow.first?.utteranceRaw == "第二句")
        #expect(shadow.first?.outcomeText == "fieldChanged：sameApp:com.foo.app")
        // shadow 模式的正確行為就是不改行為：文字照常進了現在聚焦的那個欄位
        #expect(env.text(in: "B") == "第二句", "shadow 不攔阻：第二句仍照常上屏")
        #expect(env.text(in: "A") == "第一句")
        #expect(!c.ledger.frozen, "shadow 不凍結")
        #expect(!hud.states.contains(.notice("插入失敗")), "shadow 不發 notice")
        #expect(c.ledger.isActive, "shadow 不中止 session")
    }

    /// 跨 App：detail 要能事後判讀「從哪個 App 換到哪個 App」。
    @Test func focusMovedToAnotherAppRecordsCrossAppDetail() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.tinyspeck.slackmacgap")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(shadowEvents(history).first?.outcomeText
                == "fieldChanged：crossApp:com.foo.app→com.tinyspeck.slackmacgap")
        #expect(env.text(in: "B") == "第二句")
    }

    /// 焦點沒動：零診斷事件（誤判率的分母乾不乾淨全看這條）。
    @Test func focusUnchangedRecordsNoShadowEvent() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(shadowEvents(history).isEmpty)
        #expect(env.text(in: "A") == "第一句第二句")
        #expect(env.text(in: "B") == "")
    }

    /// **issue #21 的釘子**：沒有 AX 的 App（兩邊都沒有 identity）＝ `.unknown`，
    /// 照常上屏、零診斷。閘門若把 `.unknown` 當成 `.different`，每一句都會被記一筆假陽性。
    @Test func withoutAnyIdentityAppendsAsUsualAndRecordsNothing() {
        let reader = FakeFieldReader()                 // 預設：有聚焦元素、無 anchor、無 identity
        let history = FakeHistory()
        let (c, _, _, key, _, _) = makeController(fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(c.ledger.fieldIdentity == nil)
        #expect(key.ops == [.insert("第一句"), .insert("第二句")], "無 AX 的純追加照常上屏")
        #expect(shadowEvents(history).isEmpty, "沒有 identity 可比就不得產生 shadow 診斷")
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.isEmpty)
    }

    /// 聽寫途中焦點切進密碼欄位：閘門回 `.secure`，行為必須逐字不變（硬停整個 session）。
    @Test func secureFieldMidSessionStillAborts() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("正常內容"), at: 10.5)
        env.focus("P")
        c.handleTranscript(.finalized("這段不可上屏"), at: 11.0)
        #expect(env.text(in: "P") == "", "密碼欄位一個字都不能進")
        #expect(env.text(in: "A") == "正常內容")
        #expect(!c.ledger.isActive, "session 硬停")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        #expect(shadowEvents(history).isEmpty, "密碼欄位走 secure 分支，不記 shadow 診斷")
    }

    /// 閘門對 lease 不變式必須中性：整段 session 跑完（含焦點切換）registry 不得有殘留持有者。
    @Test func gateKeepsTheIdentityLeaseBalanced() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        c.escapePressed()
        #expect(env.identityEntryCount == 0)
    }
}
