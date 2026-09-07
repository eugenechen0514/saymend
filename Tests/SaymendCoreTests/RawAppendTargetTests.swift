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

    private func lastFeedbackText(_ feedback: FakeFeedback) -> String? {
        feedback.events.compactMap { if case .updated(let u) = $0 { return u }; return nil }.last?.text
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
        // 註：這個序號是硬編碼的——日後路徑上若多／少一次閘門查詢，hook 就不會在正確時機開火。
        // 好消息是它會**大聲紅**（焦點沒搬 → 備援寫進 A → 下面 `text(in:"A") == ""` 失敗），
        // 不會安靜變綠；屆時照著新的呼叫序調整這個數字即可。
        env.afterFieldGate = { [weak env] in
            guard env?.fieldGateCalls == 2 else { return }
            env?.focus("B")
        }
        c.handleTranscript(.finalized("備援也不許亂寫"), at: 10.5)

        // 承重的是下面三條（B 沒被寫、內容有救、有提示）——M2 實測拿掉第二次閘門查詢時，
        // 恰好只有它們會紅。
        #expect(env.text(in: "B") == "", "備援重送必須先過閘門：一個字都不能進 B")
        // 這條不是在驗閘門：`failInsertsRemaining = 1` 讓 primary 必定拋錯，依 #38 的原子契約
        // A 本來就會是空的，閘門查不查第二次都一樣。留著只是排除「字被寫回 A」這種其他失序。
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

    // MARK: - 8. .secure 在 coordinator 層擋下之後，controller 一律硬停

    /// controller 的密碼守衛答完之後、寫入之前焦點才切進密碼欄位。
    ///
    /// **改寫理由**：舊版釘的是「只跳過這一句，硬停留給下一句的 `:341` 守衛」。那條語意有洞——
    /// session 沒被停掉，斷句器 buffer 裡已經含被擋片段（`segmenter.onTranscript` 跑在閘門查詢之前），
    /// 話語一閉合整句 raw 就上雲端 LLM，潤飾全文再明文落進 `history_exchange`。裁定改為
    /// `.secureField` 在任何一層都比照 `:341` 硬停，本測試因此改釘「當場封存」。
    @Test func focusMovingIntoASecureFieldInsideTheWindowHardStopsTheSession() {
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
        #expect(!c.ledger.isActive, "當場硬停，不再等下一句 finalized")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")),
                "文案由 abortForSecureField 自己發，不另發「已入剪貼簿」那則")
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

    /// `.secure` 在 coordinator 層與 `.different` 同樣不寫（規格 §5.3 的最小滿足），
    /// 但回的是**自己的 case** `.secureField(subroleUnknown: false)`——不再借用
    /// `.fieldChanged(currentAppBundleID: nil)`，兩者的診斷分類與誤判率分母都不同。
    @Test func aSecureGateAlsoBlocksTheWriteAtTheCoordinatorLayer() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .secure })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("不該寫") == .secureField(subroleUnknown: false))
        #expect(try c.insertDetached("也不該寫") == .secureField(subroleUnknown: false))
        #expect(key.ops.isEmpty)
        #expect(paste.ops.isEmpty)
        #expect(c.displayedText == "")
    }

    /// `.secureUnknown`（AX 連兩次問不出 subrole，#59 fail closed）在 coordinator 層同樣不寫，
    /// 但回的是 `subroleUnknown: true`——「不知道」與「知道」必須在型別上分得出來，
    /// 否則 0.2s AX timeout 誤殺了多少永遠量不出。
    @Test func aSubroleUnknownGateBlocksTheWriteAndSaysItIsUnknown() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .secureUnknown })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("不該寫") == .secureField(subroleUnknown: true))
        #expect(try c.insertDetached("也不該寫") == .secureField(subroleUnknown: true))
        #expect(key.ops.isEmpty)
        #expect(paste.ops.isEmpty)
        #expect(c.displayedText == "")
    }

    // MARK: - 11. 緩衝句落地（insertDetached）也走同一道閘門

    /// 選取即目標模式下，第二句被緩衝、等首句替換完選取才以 `insertDetached` 落地。
    /// 這條路徑上焦點一樣可能已經換掉——它與 finalized 路徑共用 `insertWithFallback`，
    /// 所以閘門也蓋得到，比照該處既有的失敗路徑救進剪貼簿並提示。
    /// 這句話的內容**就是** LLM outcome 本身，救完就結束，不需要（也不會）再丟棄一次 outcome。
    @Test func aBufferedUtteranceLandingIntoAChangedFieldIsRescuedInstead() async {
        let intent = GatedIntentService()
        intent.gatedRaws = ["第二句"]                     // 只卡第二句：首句立即回、先把選取替換掉
        intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                               "第二句": .newContent("補充內容。")]
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 4,
                                      fieldIdentity: FieldIdentity(token: 1),
                                      selectedRange: .init(location: 4, length: 3),
                                      selectedText: "原文字")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _, key, _, hud) = makeController(polisher: intent, clipboard: clipboard,
                                                    fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("改正式一點"), at: 11.0)
        c.tick(at: 12.6)                                  // 首句：緩衝＋建 task
        let first = c.lastIntentTask
        c.handleTranscript(.finalized("第二句"), at: 13.0)
        c.tick(at: 14.6)                                  // 第二句：仍 selectionPending → 緩衝
        await first?.value                                // 首句替換選取成功 → 轉 .tail
        #expect(c.ledger.sessionText == "正式版")
        let opsBeforeLanding = key.ops
        // 第二句落地之前焦點被搬走（不是凍結——凍結那條由 DictationControllerTests 釘）
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0,
                                      fieldIdentity: FieldIdentity(token: 2),
                                      frontAppBundleID: "com.other.app")
        intent.release()
        await c.lastIntentTask?.value

        #expect(key.ops == opsBeforeLanding, "緩衝句不得合成鍵入到別的欄位")
        #expect(clipboard.texts == ["補充內容。"], "改走剪貼簿急救")
        #expect(hud.states.contains(.notice(DictationController.fieldChangedNotice)))
        #expect(c.ledger.sessionText == "正式版", "沒落地就不得進帳本")
        #expect(history.exchanges.contains { $0.outcomeKind == "insertSkipped"
                && $0.outcomeText == "fieldChanged：crossApp:?→com.other.app" })
    }

    // MARK: - 12. skippedRaw 不得洩漏到下一個 session

    /// 跳過旗標平常在 `processUtterance(raw:)` 捕捉後即重設，但 Esc 聽寫中／密碼欄硬停／
    /// ASR 失敗三條路徑都會 `segmenter.hardReset()`，把待閉合的 raw 直接丟掉——那句話
    /// **永遠走不到 `processUtterance`**，旗標就會留 true 洩漏出去。
    ///
    /// 觸發情境非常自然：使用者看到「欄位已切換，內容已入剪貼簿」之後，最直覺的反應就是
    /// 按 Esc、把焦點喬回去、重講一次；而重講的那一句正是被吃掉潤飾的那一句——
    /// 它焦點完全正常、字也確實上屏了，卻在 `dispatch` 被誤判早退：潤飾無聲丟棄
    /// （Q4 規定跳過時不再發第二則提示，所以連個說法都沒有），還多記一列假的
    /// `outcomeDropped/skippedRaw` 污染 #37 賴以決策的遙測。修法是隨 `archiveSession()` 歸零。
    @Test func aSkippedFlagDoesNotLeakIntoTheNextSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("潤飾後。")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.finalized("被跳過"), at: 10.5)          // 旗標被設起來
        c.escapePressed()                                          // hardReset：這句永遠到不了 processUtterance
        #expect(!c.ledger.isActive, "前提：Esc 已封存 session")

        env.focus("A")                                             // 使用者把焦點喬回原欄位
        c.hotkeyPressed(at: 20.0)                                  // 全新的 session
        c.handleTranscript(.finalized("新的一句"), at: 20.5)
        #expect(env.text(in: "A") == "新的一句", "前提：新 session 的字確實上屏了")
        c.tick(at: 22.1)
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == "潤飾後。", "新 session 第一句的潤飾不得被上一段的旗標吃掉")
        #expect(droppedEvents(history).isEmpty, "不得多記與閘門無關的假 outcomeDropped")
        #expect(notices(hud).filter { $0 == DictationController.fieldChangedNotice }.count == 1,
                "跳過那次提示過一則就好，新 session 不該再有")
    }


    // MARK: - 13. 部分片段被跳過：落地的那段仍須進帳本

    /// `skippedRaw` 早退在丟棄 outcome 的同時**必須同步帳本**。
    /// `snapshotAndBeginNext()` 把已落地的片段從 `coordinator.currentUtteranceText` 移進 snapshot，
    /// 早退若直接 return，那段字就只存在於欄位與 `coordinator.displayedText`（鏡像），
    /// `ledger.sessionText` 從頭到尾沒認過它。
    @Test func aPartiallySkippedUtteranceStillPutsTheLandedFragmentIntoTheLedger() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)          // 落地
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 被閘門攔下
        env.focus("A")
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == "片段一", "前提：片段一確實在欄位上")
        #expect(c.ledger.sessionText == "片段一",
                "落地的片段必須入帳；否則 History 的 finalText 與下一句的改寫基準都會少這一段")
        #expect(!c.ledger.canUndo, "只是鏡像校準，沒有潤飾成果可復原＝不推版本")
    }

    /// session 已有前一句的成果時，同步必須是「既有全文＋本次落地片段」，不是只有片段。
    /// 只寫 `snapshot.text` 會把前面已定稿的文字整段抹掉。
    @Test func theLedgerSyncKeepsTheAlreadySettledTextInFrontOfTheLandedFragment() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"),
                                 "片段一片段二": .newContent("片段一片段二。")]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("首句"), at: 10.5)
        c.tick(at: 12.1)
        await c.lastIntentTask?.value
        #expect(c.ledger.sessionText == "首句。", "前提：首句已潤飾定稿")

        c.handleTranscript(.finalized("片段一"), at: 13.0)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 13.3)
        env.focus("A")
        c.tick(at: 14.9)
        await c.lastIntentTask?.value

        #expect(c.ledger.sessionText == "首句。片段一", "同步的是尾端追加，不得把前面定稿的文字洗掉")
    }

    // MARK: - 14. 部分跳過之後封存：History 的 finalText 要含落地的片段

    /// `archiveSession()` 用 `ledger.sessionText` 當 finalText。早退不同步帳本的話，
    /// 使用者螢幕上明明有「片段一」，History 卻查不到。
    @Test func historyFinalTextIncludesTheLandedFragmentOfAPartiallySkippedUtterance() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")
        let history = FakeHistory()
        let (c, asr, _) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)
        env.focus("A")
        c.hotkeyReleased(at: 11.0)
        asr.continuation?.finish()
        c.asrStreamEnded(at: 11.1)                                 // flush → 閉合話語 → LLM
        await c.lastIntentTask?.value
        c.escapePressed()                                          // 延續窗 Esc＝封存＝定稿入史

        #expect(env.text(in: "A") == "片段一", "前提：欄位上就是片段一")
        #expect(history.finished.last?.finalText == "片段一",
                "History 的最終全文不得少掉落地的片段；實際：\(history.finished.last?.finalText ?? "nil")")
    }

    // MARK: - 15. 世代守衛：舊 session 的片段不得寫進新 session 的帳本

    /// `SessionLedger.synchronizeObservedTail` 無條件覆寫 `sessionText`，而 `skippedRaw` 早退
    /// **位在 `guard ledger.isActive, ledger.generation == generation` 之前**——
    /// 既有的 `keepRawWithoutVersion` 沒有這個問題，因為它一律在世代守衛之後才被呼叫。
    /// 少了世代條件，session A 遲到的 outcome 會把 A 的片段寫進 B 的帳本。
    @Test func aStaleSkippedOutcomeMustNotWriteIntoTheNextSessionsLedger() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["片段一片段二"]                        // 只卡 session A 那句
        polisher.outcomeByRaw = ["片段一片段二": .newContent("不該落地。"),
                                 "新的一句": .newContent("新的一句。")]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 部分跳過
        env.focus("A")
        c.tick(at: 12.4)                                           // A 的話語閉合，LLM 卡在 gate
        c.escapePressed()                                          // A 封存（outcome 仍在途）
        #expect(!c.ledger.isActive, "前提：session A 已封存")

        c.hotkeyPressed(at: 20.0)                                  // 全新的 session B
        c.handleTranscript(.finalized("新的一句"), at: 20.5)
        c.tick(at: 22.1)
        polisher.release()                                         // A 的 outcome 這時才回來
        await c.lastIntentTask?.value                              // B 的落地串在 A 之後

        #expect(!c.ledger.sessionText.contains("片段一"),
                "A 的片段不得污染 B 的帳本；實際：\(c.ledger.sessionText)")
        #expect(c.ledger.sessionText == "新的一句。", "B 的帳本只認 B 自己的成果")
    }

    // MARK: - 16. 回饋底線：早退不呼叫 emitFeedback 的實測結果

    /// `keepRawWithoutVersion` 同步帳本之後會 `emitFeedback()`，本早退分支沒有。
    /// `emitFeedback()` 算的是 `ledger.sessionText + coordinator.currentUtteranceText`，而同步只是把
    /// 同一段字從 utterance 側搬到 ledger 側——**在「N 的 dispatch 跑完之後才上屏 N+1」這個順序下和不變**，
    /// 補不補 `emitFeedback()` 都看不出差別。本測試釘住的就是這個順序下的等價關係。
    ///
    /// **交錯順序下不成立**（驗收者實測）：若 N 的 LLM 還在途、N+1 先上屏，N+1 的 `emitFeedback()`
    /// 用的是同步前的 `ledger.sessionText`，底線會暫時短一截，要等下一次 `emitFeedback()` 才補上。
    /// 這是既有行為、非本次修正引入（修正前那個片段**永遠**回不到底線上），已列為 residual limit；
    /// 本 PR 不在早退補 `emitFeedback()`（超出驗收者指定的範圍）。
    @Test func theFeedbackUnderlineIsUnchangedByTheLedgerSyncOfAPartialSkip() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")
        let feedback = FakeFeedback()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher,
                                               clipboard: ClipboardSpy(), feedback: feedback)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)
        env.focus("A")
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(lastFeedbackText(feedback) == "片段一",
                "底線本來就已經罩住落地的片段（那時它還在 currentUtteranceText 裡）")
        #expect(c.ledger.sessionText == "片段一",
                "同步把同一段字搬到 ledger 側，`ledger.sessionText + currentUtteranceText` 的和不變")

        // 下一句照常上屏：底線從「片段一」延伸，證明帳本／鏡像兩側加總後仍是正確的基準。
        c.handleTranscript(.finalized("第三句"), at: 13.0)
        #expect(lastFeedbackText(feedback) == "片段一第三句", "底線接得上，不會少一截")
    }

    // MARK: - 17. 世代守衛的 isActive 那一半：封存後、還沒開新 session

    /// `SessionLedger.archive()` **不重設 `generation`**（只把 `isActive` 設 false），所以
    /// 「A 封存了、但還沒開新 session」這個窗口裡 `generation` 仍然相符——只有 `isActive`
    /// 擋得住。上一條（測試 15）釘的是 `generation` 那一半，這條釘 `isActive` 那一半。
    ///
    /// 揭露：這條路徑寫進的是已封存的帳本，`begin()` 會把 `sessionText` 重設成 `initialText`，
    /// 且 `emitFeedback()`／`archiveSession()` 都不在 `isActive == false` 時讀它——
    /// 因此**目前沒有下游可觀察後果**，這條是防禦性不變式，不是 bug 重現。
    @Test func aStaleSkippedOutcomeMustNotWriteIntoAnArchivedLedger() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["片段一片段二"]
        polisher.outcome = .newContent("不該落地。")
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 部分跳過
        env.focus("A")
        c.tick(at: 12.4)                                           // 話語閉合，LLM 卡在 gate
        c.escapePressed()                                          // 封存；**不開新 session**
        #expect(!c.ledger.isActive, "前提：帳本已封存")

        polisher.release()                                         // 遲到的 outcome 這時才回來
        await c.lastIntentTask?.value

        #expect(c.ledger.sessionText.isEmpty,
                "已封存的帳本不得被遲到的片段寫回；實際：\(c.ledger.sessionText)")
    }

    // MARK: - 18. 頭號動機的直接釘子：.editedSession 的改寫基準

    /// 本次修正最嚴重的後果是「下一句 `.editedSession` 拿偏小的 `ledger.sessionText` 當基準」。
    /// 前面幾條是間接釘子（帳本值、History），這條直接斷言送進 LLM 的 `context.targetText`。
    ///
    /// 修正前這個基準會是「首句。」（少掉片段一），而 `replaceSession` 的 AX 驗證用的是**正確的**
    /// `displayedText`、照樣通過——片段一就被以錯誤基準算出來的整段文字靜默吃掉。
    @Test func theEditCommandBasisIncludesTheLandedFragmentOfAPartialSkip() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["首句": .newContent("首句。"),
                                 "片段一片段二": .newContent("片段一片段二。"),
                                 "改一下": .editedSession("首句片段一改。")]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: ClipboardSpy())
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("首句"), at: 10.5)
        c.tick(at: 12.1)
        await c.lastIntentTask?.value

        c.handleTranscript(.finalized("片段一"), at: 13.0)          // 落地
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 13.3)          // 被閘門攔下
        env.focus("A")
        c.tick(at: 14.9)
        await c.lastIntentTask?.value
        #expect(env.text(in: "A") == "首句。片段一", "前提：欄位上是首句加落地的片段")

        c.handleTranscript(.finalized("改一下"), at: 15.5)          // 指令話語
        c.tick(at: 17.1)
        await c.lastIntentTask?.value

        let editCall = polisher.calls.last { $0.raw == "改一下" }
        #expect(editCall?.context.targetText == "首句。片段一",
                "改寫基準必須含落地的片段；實際：\(editCall?.context.targetText ?? "nil")")
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

    // MARK: - 19. 密碼欄位攔阻自成一類，且診斷不得留下明文

    /// 密碼欄位攔阻記 `secureField`、**不記 `fieldChanged`**、**不帶 bundleID**。
    /// 這不是文字美化：`fieldChanged` 那組樣本是之後評估 `CFEqual` 誤判率的**分母**，
    /// 把「切進密碼欄」（永遠正確的攔阻）混進去，分母就再也算不出誤判率。
    ///
    /// `utteranceRaw` 必須是空字串（issue #10／#58 的不變式）：這一列會落進 `history_exchange`，
    /// 而 `historyEnabled` 預設 true——在可能是密碼欄的地方留下定稿文字等於留下明文。
    /// **改寫理由**：分類與「不留明文」兩條不變式逐字保留；剪貼簿救援與 `secureFieldSkipNotice`
    /// 兩條斷言撤掉——裁定改為硬停，剪貼簿是另一個持久容器（clipboard manager 會留存），
    /// `:341` 那道守衛今天也不救；提示由 `abortForSecureField()` 自己發的「密碼欄位不聽寫」取代。
    /// 另補「當場封存」一條。
    @Test func aSecureFieldSkipIsClassifiedApartFromFieldChangedAndKeepsNoPlaintext() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")
        }
        c.handleTranscript(.finalized("這段不可上屏"), at: 10.5)

        #expect(skipEvents(history).count == 1, "恰一列診斷")
        #expect(skipEvents(history).first?.outcomeText == "secureField",
                "分類自成一類，且不帶 detail——密碼欄位沒有 bundleID，也不該有")
        #expect(skipEvents(history).first?.utteranceRaw == "",
                "可能是密碼欄：定稿文字不得落進 history_exchange")
        #expect(!(skipEvents(history).first?.outcomeText?.hasPrefix("fieldChanged") ?? true),
                "不得混進誤判率分母那一組")
        #expect(lastNotice(hud) == "密碼欄位不聽寫")
        #expect(clipboard.texts.isEmpty,
                "**不救剪貼簿**：剪貼簿是另一個持久容器，`:341` 那道守衛今天也不救")
        #expect(env.text(in: "P") == "" && env.text(in: "A") == "", "一個字都沒進任何欄位")
        #expect(!c.ledger.isActive, "硬停")
    }

    /// AX 連兩次問不出 subrole（#59 fail closed）走同一條寫入前閘門：行為與 `.secure` 逐字相同，
    /// 但診斷分類是 `secureUnknown` 且帶 `sessionApp:` ——**格式與 `:325` 那條逐字相同**，
    /// 兩條路徑的誤殺樣本才合得起來算 0.2s timeout 的誤殺率。
    /// `utteranceRaw` 同樣留空：「不知道是不是密碼欄」正是最不該留明文的情形。
    ///
    /// **改寫理由**：同上一條——分類／detail 格式／不留明文逐字保留，剪貼簿與 notice 兩條
    /// 依硬停裁定改寫，`ledger.isActive && !frozen` 改成 `!isActive`。
    @Test func aSubroleUnknownSkipIsClassifiedApartAndKeepsNoPlaintext() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("Q", text: "", subroleUnknown: true)
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("Q")
        }
        c.handleTranscript(.finalized("這段也不可上屏"), at: 10.5)

        #expect(skipEvents(history).count == 1, "恰一列診斷")
        #expect(skipEvents(history).first?.outcomeText == "secureUnknown：sessionApp:com.foo.app",
                "分類與 detail 格式必須與 :325 那條逐字相同")
        #expect(skipEvents(history).first?.utteranceRaw == "",
                "『不知道是不是密碼欄』更不該留明文")
        #expect(lastNotice(hud) == "密碼欄位不聽寫")
        #expect(clipboard.texts.isEmpty, "**不救剪貼簿**：與 `.secure` 逐字相同")
        #expect(env.text(in: "Q") == "" && env.text(in: "A") == "", "一個字都沒進任何欄位")
        #expect(!c.ledger.isActive, "與 .secure 同：硬停")
    }

    /// 對照組：`.different` 那組**仍然**記 `fieldChanged`、帶 bundleID、且照舊留下定稿文字
    /// （那不是密碼欄，明文限制不適用）——沒有被 secure 的分家污染。
    @Test func aFieldChangedSkipKeepsItsOwnClassificationAndBundleID() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)

        #expect(skipEvents(history).first?.outcomeText == "fieldChanged：sameApp:com.foo.app")
        #expect(skipEvents(history).first?.utteranceRaw == "第二句", "不是密碼欄：定稿文字照舊留著")
        #expect(lastNotice(hud) == DictationController.fieldChangedNotice)
    }

    // MARK: - 13. `.secureField` 的資安不變式：raw 根本不得離開本機

    /// **本次修正的核心**（`.secureField` 一律硬停）。
    ///
    /// **改寫理由**（原 `aSecureBlockedSegmentAlsoDropsItsOutcomeSoItCannotSneakBack`）：
    /// 舊版建的正是這個情境，卻只斷言 `droppedEvents`——oracle 打錯對象。「只跳過、不 archive」
    /// 之下 session 與 segmenter 繼續跑：片段在 `segmenter.onTranscript` 就已進 buffer
    /// （早於閘門查詢），話語閉合時 `processUtterance` 把**含被擋片段**的整句 raw 送
    /// `intentService.process`（雲端 provider），而 `dispatch` 頂端那道**無條件**的
    /// `recordExchange` 又跑在 `skippedRaw` 早退**之前**——LLM 潤飾全文（含被擋片段）
    /// 明文落進 `history_exchange.outcomeText`，`historyEnabled` 預設 true。
    /// 失敗情境：對欄位 A 說「我的密碼是」→ 焦點被搬到密碼欄 P → 說「1234」→
    /// 「我的密碼是1234」送雲端 LLM →「我的密碼是 1234。」永久寫進本機 SQLite。
    ///
    /// 硬停之後 `abortForSecureField()` 的 `segmenter.hardReset()` 讓那句 raw 永遠不會閉合：
    /// 沒有 LLM 呼叫，也就沒有 outcome 可寫進歷史。
    ///
    /// **本條的射程只到雲端 provider 與 `history_exchange` 兩處。** 第三個持久容器
    /// `asr_diagnostic` 由下面的 `aSecureBlockedSegmentLeavesNoPlaintextInTheASRDiagnosticTable`
    /// 釘住——本條的事件全部走 `.finalized(_)`（`quality == nil`），`recordASRDiagnostic`
    /// 的 `guard let quality` 會直接早退，所以那張表在本條裡**看不見**，不要讀成已被涵蓋。
    @Test func aSecureBlockedSegmentHardStopsSoTheRawNeverReachesTheLLM() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)          // 落地
        // controller 的密碼守衛答完之後才切進密碼欄：走 coordinator 的 `.secureField` 分支
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")
        }
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 被密碼欄位擋下 → 硬停
        c.tick(at: 12.4)                                           // 話語永遠不會閉合（segmenter 已 hardReset）
        await c.lastIntentTask?.value

        #expect(!polisher.calls.contains { $0.raw.contains("片段二") },
                "焦點在密碼欄時說的話一個字都不得送進雲端 provider；實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("片段二") || ($0.outcomeText?.contains("片段二") ?? false)
        }, "history_exchange 任何一列都不得含被擋片段（明文永久落地）；實際：\(history.exchanges)")
        #expect(!c.ledger.isActive, "session 當場硬停")
        #expect(history.finished.count == 1, "硬停即封存")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        #expect(env.text(in: "P") == "", "密碼欄位一個字都不能進")
        #expect(!clipboard.texts.contains("片段二"),
                "剪貼簿是另一個持久容器（clipboard manager 會留存），同樣不救")
    }

    /// 同一條資安不變式的**第三張表**：`asr_diagnostic`（`HistoryStore.swift:63-71`，
    /// SQLite 的明文 `finalizedText` 欄，設定頁歷史 UI 直接顯示）。
    ///
    /// 上面那條把射程停在雲端 provider 與 `history_exchange`，是因為它的事件都是
    /// `.finalized(_)`——`quality == nil`，`recordASRDiagnostic` 的 `guard let quality` 直接早退，
    /// 這條洩漏路徑在那個骨架下**永遠看不見、永遠會綠**。WhisperKit 每筆定稿都給非 nil quality
    /// （`WhisperKitEngine.swift:240/253`），`settings.historyEnabled` 預設 true——
    /// 預設設定下每一句都會落地。故本條刻意帶 quality 進來，讓 oracle 看得見那張表。
    ///
    /// 釘的不變式：`recordASRDiagnostic` 必須跑在**所有**密碼欄守衛之後，包含本分支新增的
    /// 寫入前閘門。修正前它寫在 `:341` 閘門查詢之後、`insertFinalized` 之前——硬停擋住了雲端
    /// LLM 與 `history_exchange`，卻讓被擋片段的明文先一步進了這張表。
    ///
    /// 斷言用**整份等於** `["我的密碼是"]` 而不是 `!contains`：同時釘住「被擋的那句沒寫」與
    /// 「沒被擋的那句照舊要寫」——否則把 `recordASRDiagnostic` 整個刪掉也會綠。
    @Test func aSecureBlockedSegmentLeavesNoPlaintextInTheASRDiagnosticTable() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("我的密碼是1234。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        // 二進位可精確表示的數（-1/4、9/8）：Float 存進 Double 欄位無損，斷言不會測到浮點表示法
        let quality = TranscriptQuality(minAvgLogprob: -0.25, maxCompressionRatio: 1.125,
                                        segmentCount: 1)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("我的密碼是", quality: quality), at: 10.5)   // 落地於 A
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")
        }
        c.handleTranscript(.finalized("1234", quality: quality), at: 10.8)        // 被密碼欄擋下：硬停
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(history.diagnostics.map(\.finalizedText) == ["我的密碼是"],
                "被擋片段的定稿明文不得落進 asr_diagnostic，落地成功的那句則必須照舊記得到（issue #10 的樣本不能連帶消失）；實際：\(history.diagnostics.map(\.finalizedText))")
        #expect(!polisher.calls.contains { $0.raw.contains("1234") },
                "前提重申：被擋片段同樣不得送雲端；實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("1234") || ($0.outcomeText?.contains("1234") ?? false)
        }, "前提重申：history_exchange 任何一列都不得含被擋片段；實際：\(history.exchanges)")
        #expect(!c.ledger.isActive, "session 當場硬停")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        #expect(env.text(in: "P") == "", "密碼欄位一個字都不能進")
        #expect(!clipboard.texts.contains("1234"), "剪貼簿同樣不救")
    }

    /// 對照組：**`.fieldChanged` 的診斷照舊要寫**。
    ///
    /// 把 `recordASRDiagnostic` 從閘門之前搬到各終點之後，風險有兩面：漏了密碼欄那條是**洩漏**，
    /// 而漏了其他終點是**樣本靜默消失**（issue #10 那筆 id=116 幻覺正是靠這列才追得到）。
    /// 上一條釘住前者，本條釘住後者裡最容易和它混淆的一格——同樣是「閘門擋下、一個字都沒寫」，
    /// 但 `.fieldChanged` 只是換了欄位、不是密碼欄，內容既已進剪貼簿，診斷就沒有不寫的理由。
    /// 兩條一起把那條界線畫死：不是「被擋就不記」，是「**可能是密碼欄**才不記」。
    @Test func aFieldChangedSkipStillRecordsTheASRDiagnostic() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        let quality = TranscriptQuality(minAvgLogprob: -0.25, maxCompressionRatio: 1.125,
                                        segmentCount: 1)
        c.hotkeyPressed(at: 10.0)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("B")                                        // 換欄位，不是密碼欄
        }
        c.handleTranscript(.finalized("這段換了欄位", quality: quality), at: 10.5)

        #expect(env.text(in: "B") == "" && env.text(in: "A") == "", "前提：閘門確實擋下，一個字都沒寫")
        #expect(clipboard.texts == ["這段換了欄位"], "前提：走的是 `.fieldChanged` 那條（救剪貼簿）")
        #expect(history.diagnostics.map(\.finalizedText) == ["這段換了欄位"],
                "不是密碼欄就沒有不記的理由；診斷搬家不得順手把這格的樣本弄丟")
        #expect(c.ledger.isActive, "`.fieldChanged` 不 archive（裁定 Q2）")
    }

    /// 同一條資安不變式的 **`.secureUnknown` 版**（#59 fail closed）：行為逐字相同，
    /// 但必須留下「這是不知道，不是知道」的 metadata——否則 0.2s AX timeout 誤殺多少量不出來。
    @Test func aSubroleUnknownBlockedSegmentHardStopsAndKeepsOnlyMetadata() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("Q", text: "", subroleUnknown: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("片段一片段二。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("Q")
        }
        c.handleTranscript(.finalized("片段二"), at: 10.8)
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(!polisher.calls.contains { $0.raw.contains("片段二") },
                "『可能是密碼欄』的片段同樣不得送雲端；實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("片段二") || ($0.outcomeText?.contains("片段二") ?? false)
        }, "history_exchange 任何一列都不得含被擋片段；實際：\(history.exchanges)")
        #expect(skipEvents(history).last?.outcomeText == "secureUnknown：sessionApp:com.foo.app",
                "分類與 detail 格式必須與 :341 那條逐字相同")
        #expect(skipEvents(history).last?.utteranceRaw == "",
                "只留 metadata，不留句子")
        #expect(!c.ledger.isActive)
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        #expect(env.text(in: "Q") == "")
        #expect(!clipboard.texts.contains("片段二"))
    }

    /// **順序**：診斷必須記在 `abortForSecureField()` **之前**。
    /// `abortForSecureField` 會 `archiveSession()`，而 archive 把 `historySessionID` 清成 nil，
    /// `recordInsertEvent` 沒有 hid 就整筆靜默丟掉——兩行對調，診斷會安靜消失（測試必須死）。
    /// 與 `FieldGateTests.secureUnknownDiagnosticIsRecordedBeforeTheSessionIsArchived` 同型，
    /// 但釘的是**寫入前閘門**（coordinator `.secureField`）這條路徑。
    @Test func theSecureFieldDiagnosticIsRecordedBeforeTheSessionIsArchived() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")
        }
        c.handleTranscript(.finalized("這段不可上屏"), at: 10.5)

        #expect(skipEvents(history).count == 1,
                "診斷若排在 abort 之後，historySessionID 已是 nil，整筆會靜默丟掉")
        #expect(skipEvents(history).first?.sessionID == history.sessions.first?.id,
                "掛在被硬停的那個 session 底下")
        #expect(history.finished.count == 1, "而且確實封存了——不是「沒 abort 所以診斷才記得成」")
    }

    // MARK: - 14. 遲到的 outcomeDropped 診斷也要有世代守衛

    /// `outcomeDropped` 那列用的是**呼叫當下**的 `historySessionID`，而早退位在
    /// `guard ledger.isActive, ledger.generation == generation` **之前**。時序：
    /// session A 部分跳過、LLM 卡住 → Esc 封存 A → 開 session B 並說完一句（B 有自己的 hid）→
    /// A 的舊 outcome 才回來 → 這筆診斷掛到 B 的 hid 下，A 的跳過在資料上變成 B 的。
    @Test func aStaleSkippedOutcomeMustNotWriteItsDiagnosticIntoTheNextSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["片段一片段二"]                        // 只卡 session A 那句
        polisher.outcomeByRaw = ["片段一片段二": .newContent("不該落地。"),
                                 "新的一句": .newContent("新的一句。")]
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher,
                                               clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)          // 部分跳過（.fieldChanged）
        env.focus("A")
        c.tick(at: 12.4)                                           // A 的話語閉合，LLM 卡在 gate
        c.escapePressed()                                          // A 封存（outcome 仍在途）

        c.hotkeyPressed(at: 20.0)                                  // 全新的 session B
        c.handleTranscript(.finalized("新的一句"), at: 20.5)
        c.tick(at: 22.1)
        polisher.release()                                         // A 的 outcome 這時才回來
        await c.lastIntentTask?.value

        #expect(history.sessions.count == 2, "前提：確實開了兩個 session")
        let sessionB = history.sessions.last?.id
        #expect(!droppedEvents(history).contains { $0.sessionID == sessionB },
                "A 遲到的 outcomeDropped 診斷不得掛到 B 的 hid；實際：\(droppedEvents(history))")
    }

    /// 緩衝句落地（`insertDetached`）路徑上焦點切進的是**密碼欄位**：分類同樣走 `secureField`，
    /// `utteranceRaw` 同樣留空。兩個呼叫點都得各自表態——只改 `insertFinalized` 那條，
    /// 這裡會安靜留在 `fieldChanged`，而且把 LLM 的定稿文字寫進可能是密碼欄的診斷列。
    ///
    /// **改寫理由**：分類與不留明文兩條逐字保留；剪貼簿救援與 `secureFieldSkipNotice` 依硬停裁定撤掉。
    /// 這條路徑同樣證明不出「內容不可能含密碼欄時段說的話」——緩衝句的 raw 走的是同一個 segmenter，
    /// 一樣可能含焦點在 P 期間說的片段，故照裁定的預設**不救剪貼簿**、當場封存。
    @Test func aBufferedUtteranceLandingIntoASecureFieldIsClassifiedAsSecureField() async {
        let intent = GatedIntentService()
        intent.gatedRaws = ["第二句"]
        intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                               "第二句": .newContent("補充內容。")]
        let reader = FakeFieldReader()
        reader.context = FieldContext(hasFocusedElement: true, caretLocation: 4,
                                      fieldIdentity: FieldIdentity(token: 1),
                                      selectedRange: .init(location: 4, length: 3),
                                      selectedText: "原文字")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _, key, _, hud) = makeController(polisher: intent, clipboard: clipboard,
                                                    fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("改正式一點"), at: 11.0)
        c.tick(at: 12.6)
        let first = c.lastIntentTask
        c.handleTranscript(.finalized("第二句"), at: 13.0)
        c.tick(at: 14.6)
        await first?.value
        let opsBeforeLanding = key.ops
        reader.context = FieldContext(hasFocusedElement: true, isSecure: true)   // 落地前切進密碼欄
        intent.release()
        await c.lastIntentTask?.value

        #expect(key.ops == opsBeforeLanding, "密碼欄位一個字都不能進")
        #expect(clipboard.texts.isEmpty, "**不救剪貼簿**：與 finalized 那條逐字相同")
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")))
        let skipped = history.exchanges.filter { $0.outcomeKind == "insertSkipped" }
        #expect(skipped.last?.outcomeText == "secureField")
        #expect(skipped.last?.utteranceRaw == "",
                "可能是密碼欄：**這一列**（insertSkipped）不得留明文。收斂成單列而不是整張表——dispatch 頂端那道無條件的 recordExchange 跑在 `.secureField` 偵測之前，`第二句`／`補充內容。` 照樣會另外入表；裁定明示接受該損失（內容已經過 LLM），硬停攔不到。")
        #expect(!history.exchanges.contains { $0.outcomeText?.hasPrefix("fieldChanged") ?? false },
                "不得混進誤判率分母那一組")
        #expect(!c.ledger.isActive, "硬停")
        #expect(history.finished.count == 1,
                "診斷排在 abort 之前才記得成——對調則 historySessionID 已 nil，上面那兩條會全垮")
    }

    /// 同一條 `insertDetached` 路徑的 **`subroleUnknown` 版**（#59 fail closed）：
    /// 分類走 `secureUnknown`、detail 格式與 `:341` 那條逐字相同，`utteranceRaw` 同樣留空，
    /// 且同樣**當場硬停**。
    ///
    /// 骨架**必須**是 `StatefulFieldEnvironment`：`FakeFieldReader` 走 `FieldContextProviding`
    /// 的預設 `fieldGate`（`FieldAccess.swift:180-183`），那裡只剩布林的 `FieldContext.isSecure`、
    /// verdict 已經丟失，**原理上給不出 `.secureUnknown`**——沿用上一條測試的骨架永遠到不了
    /// 這個分支（實測：把這裡的 `utteranceText: ""` 改回 `text`、或把 classification 改成別的字串，
    /// 全量測試都照樣全綠）。兩個呼叫點 × 兩種形態，四格都要有自己的釘子。
    @Test func aBufferedUtteranceLandingIntoASubroleUnknownFieldIsClassifiedAsSecureUnknown() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "前舊字後", bundleID: "com.foo.app")
        env.select(in: "A", location: 1, length: 2)
        env.addField("Q", text: "", subroleUnknown: true)
        let intent = GatedIntentService()
        intent.gatedRaws = ["第二句"]
        intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                               "第二句": .newContent("補充內容。")]
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: intent,
                                                 clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("改正式一點"), at: 11.0)
        c.tick(at: 12.6)
        let first = c.lastIntentTask
        c.handleTranscript(.finalized("第二句"), at: 13.0)          // selectionPending 期間＝緩衝
        c.tick(at: 14.6)
        await first?.value                                          // 首句替換選取，目標轉回 .tail
        let textAfterFirst = env.text(in: "A")
        env.focus("Q")                                              // 落地前切到「問不出 subrole」的欄位
        intent.release()
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == textAfterFirst, "session 欄位不得被補寫")
        #expect(env.text(in: "Q") == "", "可能是密碼欄：一個字都不能進")
        #expect(clipboard.texts.isEmpty, "**不救剪貼簿**：與 `.secure` 那條逐字相同")
        #expect(lastNotice(hud) == "密碼欄位不聽寫")
        #expect(skipEvents(history).last?.outcomeText == "secureUnknown：sessionApp:com.foo.app",
                "分類與 detail 格式必須與 :341 及 finalized 那條逐字相同")
        #expect(skipEvents(history).last?.utteranceRaw == "",
                "『不知道是不是密碼欄』更不該留明文")
        #expect(!c.ledger.isActive, "硬停")
        #expect(history.finished.count == 1, "診斷排在 abort 之前才記得成")
    }
}
