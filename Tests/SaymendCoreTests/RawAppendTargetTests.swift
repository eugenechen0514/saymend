import Testing
@testable import SaymendCore

/// issue #37：raw 上屏（純追加）的目標欄位綁定。
///
/// **本 PR 的契約是「不寫進別的欄位 ＋ 內容不遺失」，不是「字一定落在 A」。**
/// 這個檔案最早的兩條重現測試斷言「字必須落在 A」——那是選項 B（把寫入導向 session 欄位，
/// 需要 AX 直寫或跨欄位 caret 操作）的驗收條件，已移交未來的 spike。
/// 定案的裁定是 fail closed（Q1）：AX **明確**指出焦點已換就一個字都不寫、內容進剪貼簿、提示使用者；
/// AX **讀不到**（`.unknown`）則照常上屏——issue #21 的純追加契約不動。
///
/// 因此四項 oracle 是：
/// ① session 欄位維持原樣（沒有被補寫）；② 新焦點欄位一個字都沒多；
/// ③ 內容進了剪貼簿；④ HUD 提示 `DictationController.fieldChangedNotice`。
///
/// 閘門下沉到 `InsertionCoordinator` 的寫入路徑之後，它擋得住的是
/// 「閘門查詢 → 寫入呼叫」之間的窗口；**W1 只是被縮短，沒有被關掉**
/// （paste 路徑的 clipboard settle、CGEvent.post 之後的投遞都在閘門之外）。
@MainActor
@Suite struct RawAppendTargetTests {

    private func lastNotice(_ hud: FakeHUD) -> String? {
        hud.states.compactMap { if case .notice(let s) = $0 { return s }; return nil }.last
    }

    private func notices(_ hud: FakeHUD) -> [String] {
        hud.states.compactMap { if case .notice(let s) = $0 { return s }; return nil }
    }

    private func skipEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "insertSkipped" }
    }

    private func droppedEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "outcomeDropped" }
    }

    // MARK: - 1. 窄窗口 W1：controller 閘門看到 .same，寫入前的閘門看到 .different

    /// controller 的密碼守衛閘門答完「焦點還在 A」之後、`insertFinalized` 真的寫下去之前，
    /// 外部把焦點程式化搬到 B。**寫入前的第二道閘門必須擋下來**——這正是把閘門下沉到
    /// coordinator（而不是留在 controller）唯一的理由，controller 那一道對這個窗口無能為力。
    @Test func focusMovedInsideTheNarrowWindowSkipsTheWriteEntirely() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)                                  // session 起在 A
        // 只攔第一次閘門查詢（controller 的密碼守衛）：答完之後才搬焦點，製造窄窗口
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("B")                                        // 無 keyDown、無 mouseDown、非切 App
        }
        c.handleTranscript(.finalized("機密內容"), at: 10.5)

        #expect(env.text(in: "A") == "", "閘門是不寫，不是改寫別處——A 不會被補上這句")
        #expect(env.text(in: "B") == "", "別的欄位一個字都不能進")
        #expect(clipboard.texts == ["機密內容"], "內容不得遺失：進剪貼簿")
        #expect(lastNotice(hud) == DictationController.fieldChangedNotice)
        #expect(skipEvents(history).count == 1, "恰一列診斷——閘門下沉後不得再有 shadow 那列重複計數")
        #expect(skipEvents(history).first?.outcomeText == "fieldChanged：sameApp:com.foo.app")
    }

    // MARK: - 2. 寬窗口：兩句之間搬焦點

    /// 第一句正常落在 A，兩句之間焦點被搬到 B（Tab／maxlength 自動跳格／頁面 JS，
    /// 不觸發使用者活動偵測、不會 freeze），第二句抵達。
    @Test func focusMovedBetweenUtterancesSkipsTheSecondOne() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "5678", bundleID: "com.tinyspeck.slackmacgap")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        #expect(env.text(in: "A") == "第一句", "前提：第一句本來就該落在 A")

        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)

        #expect(env.text(in: "A") == "第一句", "被跳過的那句不會補寫回 A")
        #expect(env.text(in: "B") == "5678", "別的欄位一個字都不能多")
        #expect(clipboard.texts == ["第二句"])
        #expect(lastNotice(hud) == DictationController.fieldChangedNotice)
        #expect(skipEvents(history).count == 1)
        #expect(skipEvents(history).first?.utteranceRaw == "第二句")
        #expect(skipEvents(history).first?.outcomeText
                == "fieldChanged：crossApp:com.foo.app→com.tinyspeck.slackmacgap")
    }

    // MARK: - 3. W1′：fallback 重送是獨立窗口

    /// 主 inserter 拋錯、備援重送**之前**焦點被搬走。fallback 重送是自己的一個窗口（W1′）：
    /// 只在 primary 之前查一次閘門，這條路徑就是完全沒設防的——文字會整句被備援打進 B。
    /// 沒有這條測試，「閘門查兩次」就只是一句沒被驗證的宣稱。
    @Test func focusMovedBetweenPrimaryFailureAndFallbackSkipsTheFallbackWrite() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let clipboard = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard)
        c.hotkeyPressed(at: 10.0)
        env.failInsertsRemaining = 1                               // 主 inserter 拋錯一次 → 走備援
        // 第 1 次查詢＝controller 的密碼守衛；第 2 次＝coordinator 在 primary 之前。
        // 在第 2 次之後搬焦點，讓 primary 失敗後的那一次查詢（第 3 次）看到 .different。
        env.afterFieldGate = { [weak env] in
            guard env?.fieldGateCalls == 2 else { return }
            env?.focus("B")
        }
        c.handleTranscript(.finalized("備援也不許亂寫"), at: 10.5)

        #expect(env.text(in: "B") == "", "備援重送必須先過閘門：一個字都不能進 B")
        #expect(env.text(in: "A") == "", "primary 已拋錯（原子契約：一個字都沒進），A 也是空的")
        #expect(clipboard.texts == ["備援也不許亂寫"])
        #expect(lastNotice(hud) == DictationController.fieldChangedNotice)
    }

    // MARK: - 4. issue #21 的釘子：.unknown 照常上屏

    /// 沒有 AX 的 App（session 與現在都沒有 identity）＝ `.unknown`：文字照常寫進欄位，
    /// 零 notice、零剪貼簿、零診斷。閘門若把 `.unknown` 當成 `.different`，
    /// 這種 App 從此一個字也打不出來——那是比 #37 嚴重得多的迴歸。
    @Test func withoutAnyIdentityAppendsAsUsualAndTouchesNothingElse() {
        let reader = FakeFieldReader()                 // 預設：有聚焦元素、無 anchor、無 identity
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _, key, _, hud) = makeController(clipboard: clipboard, fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(.finalized("第二句"), at: 11.0)

        #expect(c.ledger.fieldIdentity == nil)
        #expect(key.ops == [.insert("第一句"), .insert("第二句")], "無 AX 的純追加照常上屏")
        #expect(clipboard.texts.isEmpty, "沒有東西被跳過，就沒有東西該進剪貼簿")
        #expect(notices(hud).isEmpty, "零 notice")
        #expect(skipEvents(history).isEmpty, "沒有 identity 可比就不得記跳過")
    }

    // MARK: - 5. Q2：只跳過那一句，不凍結

    /// 跳過不是終局：帳本不凍結、session 不封存，焦點跳回原欄位之後的下一句要能照常上屏。
    @Test func aSkippedUtteranceDoesNotFreezeTheSessionAndTheNextOneStillLands() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("被跳過"), at: 11.0)

        #expect(!c.ledger.frozen, "跳過不凍結（Q2）")
        #expect(c.ledger.isActive, "跳過不封存 session")

        env.focus("A")                                             // 焦點自己跳回來
        c.handleTranscript(.finalized("第三句"), at: 11.5)
        #expect(env.text(in: "A") == "第一句第三句", "焦點回來之後照常上屏")
        #expect(env.text(in: "B") == "")
    }

    // MARK: - 6. Q4：被跳過那句的 LLM outcome 安靜丟棄

    /// 整句被跳過：LLM 回來的潤飾結果一律丟棄（只記診斷），**不發第二則提示**——
    /// 使用者在跳過當下已經被告知內容在剪貼簿了。
    @Test func theOutcomeOfAFullySkippedUtteranceIsDroppedSilently() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("潤飾後的整句。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")                                             // 開場之後、第一句之前就被搬走
        c.handleTranscript(.finalized("整句都沒上屏"), at: 10.5)
        c.tick(at: 12.1)                                           // 靜默 1.5s → 話語閉合 → LLM
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == "", "潤飾結果不得從潤飾路徑補寫進 A")
        #expect(env.text(in: "B") == "", "更不得寫進 B")
        #expect(droppedEvents(history).count == 1)
        #expect(droppedEvents(history).first?.outcomeText == "skippedRaw")
        #expect(notices(hud) == [DictationController.fieldChangedNotice],
                "跳過當下已提示過，丟棄 outcome 不再發第二則")
        #expect(clipboard.texts == ["整句都沒上屏"], "剪貼簿也只救一次")
    }

    // MARK: - 7. Q4：部分片段被跳過

    /// 一句話兩個 finalized 片段：第一個落地、第二個被跳過。
    /// 送 LLM 的 raw（來自 segmenter）含**全部**兩段，但螢幕上只有第一段——
    /// 照常潤飾的話 `replaceTail` 會拿含「被跳過那段」的潤飾句去替換較短的鏡像尾端，
    /// 等於把我們剛拒絕寫入的內容從潤飾路徑偷渡回欄位。丟棄是唯一與 Q1 一致的選擇。
    /// 代價：部分落地的那句失去潤飾（維持 raw）。
    @Test func aPartiallySkippedUtteranceDropsItsOutcomeSoTheSkippedTextCannotSneakBack() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")            // 潤飾句含被跳過的那段
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)          // 落地
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 被跳過
        env.focus("A")                                             // 焦點回來，排除「潤飾被閘門擋掉」的干擾
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == "片段一",
                "落地那段維持 raw；被跳過那段不得從潤飾路徑偷渡回欄位")
        #expect(!env.text(in: "A").contains("片段二"))
        #expect(env.text(in: "B") == "")
        #expect(droppedEvents(history).count == 1)
        #expect(notices(hud) == [DictationController.fieldChangedNotice])
    }

    // MARK: - 8. .secure 在 coordinator 層也不寫

    /// controller 的密碼守衛答完之後、寫入之前焦點才切進密碼欄位：
    /// 規格 §5.3「一個字都不能進密碼欄」——寫入前的閘門看到 `.secure` 就不寫，這樣就滿足了。
    /// session 的硬停由 controller 既有的 `.secure` 守衛在**下一句** finalized 時處理（刻意的最小改動）。
    @Test func focusMovingIntoASecureFieldInsideTheWindowWritesNothing() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let (c, _, hud) = makeStatefulController(env: env, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")
        }
        c.handleTranscript(.finalized("這段不可上屏"), at: 10.5)

        #expect(env.text(in: "P") == "", "密碼欄位一個字都不能進")
        #expect(env.text(in: "A") == "")
        #expect(c.ledger.isActive, "本句只被跳過；硬停留給下一句的 controller 守衛（晚一句）")

        c.handleTranscript(.finalized("下一句"), at: 11.0)          // controller 的 .secure 守衛在這裡才發動
        #expect(!c.ledger.isActive, "下一句 finalized 時 session 硬停")
        #expect(env.text(in: "P") == "")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
    }

    // MARK: - 9. 沒接閘門＝維持舊行為

    /// `fieldGate` 為 nil（App 端沒接、或舊呼叫端）：coordinator 不做任何焦點判斷，照常寫。
    /// 這是「既有測試不會因為新參數而全紅」的型別層保證。
    @Test func withoutAGateTheCoordinatorAppendsExactlyAsBefore() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100)
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("你好") == .inserted)
        #expect(try c.insertDetached("再見") == .inserted)
        #expect(key.ops == [.insert("你好"), .insert("再見")])
        #expect(c.displayedText == "你好再見")
    }

    // MARK: - 10. `.fieldChanged` 一個副作用都不留

    /// 跳過時鏡像、utterance 帳本、insertCounter 三者都不得前進。
    /// 鏡像若被偷偷推進，之後的 Esc 退回會拿錯誤的 expected 去驗 AX 而 fail closed，
    /// counter 若前進則潤飾一律吃 `.tailAdvanced`——兩個都是安靜的資料損壞。
    @Test func aSkippedAppendLeavesMirrorLedgerAndCounterUntouched() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .different(currentAppBundleID: "com.other.app") })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1), initialText: "原有")
        let before = c.currentTailSnapshot()
        #expect(try c.insertFinalized("不該寫") == .fieldChanged(currentAppBundleID: "com.other.app"))
        #expect(try c.insertDetached("也不該寫") == .fieldChanged(currentAppBundleID: "com.other.app"))
        #expect(key.ops.isEmpty, "一個字都沒送到 inserter")
        #expect(paste.ops.isEmpty)
        #expect(c.displayedText == "原有", "鏡像不得前進")
        #expect(c.currentUtteranceText == "", "utterance 帳本不得前進")
        #expect(c.currentTailSnapshot() == before, "insertCounter 不得前進")
    }

    /// `.secure` 在 coordinator 層與 `.different` 同樣不寫（規格 §5.3 的最小滿足）。
    @Test func aSecureGateAlsoBlocksTheWriteAtTheCoordinatorLayer() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .secure })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("不該寫") == .fieldChanged(currentAppBundleID: nil))
        #expect(key.ops.isEmpty)
        #expect(c.displayedText == "")
    }

    /// `.unknown` 與 `.same` 一律照常寫（#21 釘子的 coordinator 單元版）。
    @Test func unknownAndSameGatesBothAppend() throws {
        for gate in [FieldGate.unknown, .same] {
            let key = RecordingInserter(), paste = RecordingInserter()
            let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                         fieldGate: { _ in gate })
            c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
            #expect(try c.insertFinalized("照常") == .inserted)
            #expect(key.ops == [.insert("照常")], "閘門 \(gate) 必須照常上屏")
        }
    }
}
