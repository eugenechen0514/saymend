import Foundation
import Testing
@testable import SaymendCore

/// issue #37 的焦點閘門本身：分類（same／different／secure／unknown）、診斷 detail 的格式、
/// 以及它對 identity lease 的中性。
///
/// **這個 suite 原名 `FieldGateShadowTests`（PR-1a）**，釘的是「shadow 模式：只記
/// `insertWouldSkip` 診斷、照常上屏、不發 notice」。PR-2 把閘門下沉到 `InsertionCoordinator`
/// 的寫入路徑並真的開閘之後，那些斷言逐條翻轉：
///
/// - 原本「`.different` 記一列 `insertWouldSkip`，文字仍照常寫進 B」
///   → 現在「記一列 `insertSkipped`／`fieldChanged`，B 一個字都沒進、內容進剪貼簿、發 notice」。
///   `insertWouldSkip` 這個 kind 隨 shadow 一起退場（它存在的唯一理由是不位移既有的 history 斷言）。
/// - 原本「shadow 不發任何 notice」→ 現在「恰好發一則 `fieldChangedNotice`」。
/// - 未翻轉的三條（`.unknown` 照常上屏、焦點沒動零診斷、`.secure` 硬停）**逐字保留**：
///   它們正是「閘門開了也不能碰」的那幾條界線。
///
/// 上屏契約與四個 TOCTOU 窗口的 oracle 在 `RawAppendTargetTests`；這裡只管閘門的分類與診斷。
@Suite @MainActor struct FieldGateTests {

    /// 焦點已換而被攔下的診斷列。kind 沿用既有的 `insertSkipped`（守衛拒絕，非失敗），
    /// 以 classification 前綴 `fieldChanged` 區辨。
    private func skipEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "insertSkipped"
            && ($0.outcomeText?.hasPrefix("fieldChanged") ?? false) }
    }

    /// 「AX 問不出 subrole，於是 fail closed 當密碼欄擋下」的診斷列（issue #37）。
    /// `outcomeText` 是 `secureUnknown：<detail>`，故用 prefix 比對。
    private func secureUnknownEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter {
            $0.outcomeKind == "insertSkipped" && ($0.outcomeText ?? "").hasPrefix("secureUnknown")
        }
    }

    private func notices(_ hud: FakeHUD) -> [String] {
        hud.states.compactMap { if case .notice(let s) = $0 { return s }; return nil }
    }

    /// 寬窗口（同 App 換欄位）：session 起在 A，兩句之間頁面 JS 把焦點跳到 B，第二句抵達。
    /// detail 要能事後判讀成「同一個 App 內換了欄位」。
    @Test func focusMovedToAnotherFieldOfTheSameAppIsSkippedAndRecordedAsSameApp() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        #expect(env.text(in: "A") == "第一句")
        env.focus("B")                                   // 無 keyDown、無 mouseDown、非切 App
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(skipEvents(history).count == 1, "恰一列——閘門下沉後不得再有 shadow 那列重複計數")
        #expect(skipEvents(history).first?.utteranceRaw == "第二句")
        #expect(skipEvents(history).first?.outcomeText == "fieldChanged：sameApp:com.foo.app")
        #expect(env.text(in: "B") == "", "別的欄位一個字都不能進")
        #expect(env.text(in: "A") == "第一句", "也不會補寫回 A")
        #expect(!c.ledger.frozen, "只跳過這一句，不凍結（裁定 Q2）")
        #expect(c.ledger.isActive, "也不中止 session")
        #expect(notices(hud) == [DictationController.fieldChangedNotice], "恰一則提示")
    }

    /// 跨 App：detail 要能事後判讀「從哪個 App 換到哪個 App」。
    @Test func focusMovedToAnotherAppRecordsCrossAppDetail() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.tinyspeck.slackmacgap")
        let history = FakeHistory()
        let clipboard = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(skipEvents(history).first?.outcomeText
                == "fieldChanged：crossApp:com.foo.app→com.tinyspeck.slackmacgap")
        #expect(env.text(in: "B") == "", "跨 App 更不能寫")
        #expect(clipboard.texts == ["第二句"], "內容不得遺失")
        #expect(notices(hud) == [DictationController.fieldChangedNotice])
    }

    /// 焦點沒動：零診斷事件（誤判率的分母乾不乾淨全看這條）。
    @Test func focusUnchangedRecordsNoSkipEvent() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(skipEvents(history).isEmpty)
        #expect(env.text(in: "A") == "第一句第二句")
        #expect(env.text(in: "B") == "")
    }

    /// **issue #21 的釘子**：沒有 AX 的 App（兩邊都沒有 identity）＝ `.unknown`，
    /// 照常上屏、零診斷。閘門若把 `.unknown` 當成 `.different`，這種 App 從此一個字也打不出來。
    @Test func withoutAnyIdentityAppendsAsUsualAndRecordsNothing() {
        let reader = FakeFieldReader()                 // 預設：有聚焦元素、無 anchor、無 identity
        let history = FakeHistory()
        let (c, _, _, key, _, _) = makeController(fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(c.ledger.fieldIdentity == nil)
        #expect(key.ops == [.insert("第一句"), .insert("第二句")], "無 AX 的純追加照常上屏")
        #expect(skipEvents(history).isEmpty, "沒有 identity 可比就不得產生跳過診斷")
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.isEmpty)
    }

    /// 聽寫途中焦點切進密碼欄位：controller 的閘門回 `.secure`，行為必須逐字不變（硬停整個 session）。
    /// 這是**兩句之間**的切換，controller 那一道就攔得住；窄窗口版（切換發生在 controller
    /// 閘門答完之後）由 `RawAppendTargetTests` 釘，那條走的是 coordinator 層的 `.secure`。
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
        #expect(skipEvents(history).isEmpty, "密碼欄位走 secure 分支，不記 fieldChanged 診斷")
        #expect(secureUnknownEvents(history).isEmpty,
                "AX 明確回答了，不得被記成 secureUnknown——那會污染「AX 沒回應」這組樣本的分子")
    }

    // MARK: - secureUnknown：fail closed 擋下，但要留下「這是不知道，不是知道」的證據

    /// AX 連續問不出 subrole（#59 fail closed）→ 一樣硬停整個 session（§5.3 一個字都不能進），
    /// 但**必須留下一筆 `insertSkipped`／`secureUnknown` 診斷**。
    /// 沒有這筆，「真的密碼欄」與「AX 沒回應被當密碼欄」在事後資料裡長得一模一樣，
    /// 0.2s timeout 到底誤殺了多少就永遠量不出來。
    @Test func subroleUnknownMidSessionAbortsAndRecordsDiagnostic() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("正常內容"), at: 10.5)
        env.focus("U")
        c.handleTranscript(.finalized("這段不可上屏"), at: 11.0)
        // 行為面：與 .secure 逐字相同——不上屏、硬停、發同一則 notice
        #expect(env.text(in: "U") == "", "問不出來就當密碼欄：一個字都不能進")
        #expect(env.text(in: "A") == "正常內容")
        #expect(!c.ledger.isActive, "session 硬停")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        // 診斷面：分得出來這是「不知道」，但**內容一個字都不得落進 DB**
        let events = secureUnknownEvents(history)
        #expect(events.count == 1)
        #expect(events.first?.utteranceRaw == "",
                "secureUnknown 有可能就是密碼欄（慢 App 的 AXSecureTextField 連兩次逾時），定稿文字一個字都不得落進 history_exchange")
        #expect(events.first?.outcomeText == "secureUnknown：sessionApp:com.foo.app",
                "誤殺率要的是「哪個 App、發生幾次」，metadata 就夠；標 sessionApp 是因為這是 session 起始的前景 App，不保證就是逾時的那個")
        #expect(skipEvents(history).isEmpty, "secureUnknown 不是 fieldChanged")
    }

    /// **順序**：`recordInsertEvent` 必須排在 `abortForSecureField()` **之前**。
    /// `abortForSecureField` 會 `archiveSession()`，而 archive 把 `historySessionID` 清成 nil，
    /// `recordInsertEvent` 沒有 hid 就整筆靜默丟掉——順序一對調，最需要的那筆樣本恰好記不到。
    /// 這條測試同時釘住「session 真的被封存了」，否則「先記」可以靠「不 abort」來滿足。
    @Test func secureUnknownDiagnosticIsRecordedBeforeTheSessionIsArchived() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("正常內容"), at: 10.5)
        env.focus("U")
        c.handleTranscript(.finalized("這段不可上屏"), at: 11.0)
        #expect(secureUnknownEvents(history).count == 1,
                "archive 先跑的話 historySessionID 已是 nil，這筆診斷會被靜默丟掉")
        // 這筆診斷掛在**這個 session** 上——archive 先跑的話 hid 已是 nil，連掛都掛不上去
        #expect(history.sessions.count == 1)
        #expect(secureUnknownEvents(history).first?.sessionID == history.sessions.first?.id)
        #expect(history.finished.count == 1, "session 仍必須被封存（先記診斷不等於不 abort）")
        #expect(history.finished.first?.id == history.sessions.first?.id)
    }

    /// `fieldChangeDetail` 的保守歸類（reviewer M7 存活的那條）：兩邊 bundleID 都讀不到時
    /// **必須歸入 crossApp**，不得因為「兩邊都是 nil、看起來相等」就寫成 sameApp——
    /// 那會把「其實已經換 App」的樣本混進 sameApp 那組、低估風險。
    @Test func unknownBundleIDsOnBothSidesAreClassifiedAsCrossApp() {
        let reader = FakeFieldReader.sessionField(token: 1)   // 有 identity、frontAppBundleID 為 nil
        let history = FakeHistory()
        let (c, _, _, key, _, _) = makeController(clipboard: ClipboardSpy(),
                                                  fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0,
                                      fieldIdentity: FieldIdentity(token: 2))   // 換了欄位、仍讀不到 bundleID
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        #expect(skipEvents(history).first?.outcomeText == "fieldChanged：crossApp:?→?",
                "分不出同 App 或跨 App 時保守歸入 crossApp")
        #expect(key.ops == [.insert("第一句")], "第二句被攔下，一個字都沒送到 inserter")
    }

    /// 閘門對 lease 不變式必須中性：整段 session 跑完（含焦點切換）registry 不得有殘留持有者。
    @Test func gateKeepsTheIdentityLeaseBalanced() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        c.escapePressed()
        #expect(env.identityEntryCount == 0)
    }
}
