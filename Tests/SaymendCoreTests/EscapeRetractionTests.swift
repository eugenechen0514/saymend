import Testing
@testable import SaymendCore

/// issue #21／#44 的驗收：以 StatefulFieldEnvironment **斷言最終欄位內容**。
/// 規則：所有會刪字的操作一律需要 verified AX（anchor、identity、AX 能力、內容比對四項），缺任一項就不動欄位只提示；
/// 純追加的上屏永遠照常。
@MainActor
@Suite struct EscapeRetractionTests {

    private static let previous = "PREVIOUS"

    /// #21 主場景：文字落地、閉合、潤飾完，再說一句，然後才按 Esc——整個聽寫階段的字都要退掉，前段文字不動。
    @Test func escapeRetractsWholeSessionIncludingPolishedText() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["呃你好": .newContent("你好。"), "再見": .newContent("再見。")]
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "你好。")
        c.handleTranscript(.finalized("再見"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "你好。再見。")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous)
        #expect(hud.states.last == .hidden)
        #expect(c.phase == .idle)
    }

    /// #21 的 1.5 秒窗口：話語閉合、潤飾在途、currentUtteranceText 為空——舊機制在這裡沒有東西可退。
    @Test func escapeDuringInFlightPolishRetractsTheRawText() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.gated = true
        polisher.outcome = .newContent("已經落地的字。")
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("已經落地的字"), at: 10.5)
        c.tick(at: 12.1)                                          // 閉合 → 潤飾發出（被 gate 卡住）
        #expect(env.text(in: "A") == Self.previous + "已經落地的字")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous)
        polisher.release(); await c.lastIntentTask?.value          // 遲到的潤飾：session 已封存，不得再寫
        #expect(env.text(in: "A") == Self.previous)
    }

    /// maxlength 自動跳格：raw 打進 A 後，頁面把焦點程式化移到 B（不觸發使用者活動偵測）。
    /// Esc 必須 fail closed：B 一個字都不少、A 保留、只提示。這是 bundleID+pid 抓不到、只有 element identity 抓得到的情況。
    @Test func escapeAfterFocusJumpedToAnotherFieldFailsClosed() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "")
        env.addField("B", text: "5678")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("1234"), at: 10.5)
        #expect(env.text(in: "A") == "1234")
        env.focus("B")                                            // 頁面 JS 跳格：無 keyDown、無 mouseDown、非切 App
        c.escapePressed()
        #expect(env.text(in: "B") == "5678", "別的欄位一個字都不能少")
        #expect(env.text(in: "A") == "1234", "原欄位的字保留，交給使用者手動處理")
        #expect(hud.states.last == .notice(DictationController.retractionUnverifiedNotice))
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.first?.outcomeText == "fieldMismatch")
        #expect(c.phase == .idle)
    }

    /// 兩個欄位 offset 相同、文字相同、不是同一個：offset＋文字錨點會通過，identity 不會。
    @Test func escapeWithSameOffsetAndSameTextInAnotherFieldFailsClosed() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "")
        env.addField("B", text: "")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("字"), at: 10.5)
        env.focus("B")
        env.typeUserText("字")                                    // B 現在與 A 長得一模一樣
        c.escapePressed()
        #expect(env.text(in: "B") == "字")
        #expect(env.text(in: "A") == "字")
        #expect(hud.states.last == .notice(DictationController.retractionUnverifiedNotice))
    }

    /// PR #36 被否決的原因，必須有測試釘住：沒有 AX 的 App，raw **照常上屏**；潤飾、Esc 只提示、不動欄位、不凍結。
    @Test func withoutAXRawStillAppendsAndDestructiveOpsOnlyNotify() async {
        let env = StatefulFieldEnvironment()
        env.axCapable = false
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("你好。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher, clipboard: clipboard, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        #expect(env.text(in: "A") == Self.previous + "呃你好", "純追加不得因缺 AX 而停")
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "呃你好", "潤飾不得盲退格")
        #expect(hud.states.contains(.notice(insertSkipNotice(.unverified))))
        #expect(!c.ledger.frozen, "沒 AX 是常態，不得凍結——否則連後續純追加都會停")
        #expect(c.ledger.sessionText == "呃你好", "帳本照鏡像入帳")
        c.handleTranscript(.finalized("再說一句"), at: 13.0)
        #expect(env.text(in: "A") == Self.previous + "呃你好再說一句", "後續純追加照常")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "呃你好再說一句", "Esc 不得盲退格")
        #expect(hud.states.last == .notice(DictationController.retractionUnverifiedNotice))
        #expect(clipboard.texts.isEmpty)
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" && $0.outcomeText == "unverified" }.count == 2)
    }

    /// 短潤飾（abcd → a）與長潤飾（abcd → abcdefgh）都只替換該句、前段不動。
    @Test func shortAndLongPolishReplaceExactlyTheUtterance() async {
        for (polished, expected) in [("a", Self.previous + "a"), ("abcdefgh", Self.previous + "abcdefgh")] {
            let env = StatefulFieldEnvironment()
            env.addField("A", text: Self.previous)
            let polisher = GatedIntentService()
            polisher.outcome = .newContent(polished)
            let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
            c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
            c.handleTranscript(.finalized("abcd"), at: 11.0)
            c.tick(at: 12.6); await c.lastIntentTask?.value
            #expect(env.text(in: "A") == expected)
            c.escapePressed()
            #expect(env.text(in: "A") == Self.previous)
        }
    }

    /// 使用者在 session 文字之後手打（偵測漏掉、未凍結）：Esc 只退 session 範圍，手打的字保留。
    @Test func escapePreservesTextTheUserTypedAfterTheSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("你好。")
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        env.typeUserText("手打")
        #expect(env.text(in: "A") == Self.previous + "你好。手打")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "手打")
    }

    /// 選取即目標：Esc 把使用者的原選取還回去，不是刪成空。
    @Test func selectionSessionEscapeRestoresTheOriginalSelection() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "前舊字後")
        env.select(in: "A", location: 1, length: 2)               // 「舊字」
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("新字")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("新字"), at: 11.0)          // 緩衝：不上屏
        #expect(env.text(in: "A") == "前舊字後")
        c.tick(at: 12.6); await c.lastIntentTask?.value            // 選取替換
        #expect(env.text(in: "A") == "前新字後")
        c.escapePressed()
        #expect(env.text(in: "A") == "前舊字後")
        #expect(history.finished.last?.finalText == "舊字", "History 的最終文字要反映退回後的欄位：原選取")
    }

    /// 凍結後 Esc：整段留在欄位上（#39 的守衛；是否仍退由 #46 的設定決定）。
    @Test func frozenEscapeKeepsEverythingOnScreen() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("字"), at: 10.5)
        c.userActivityDetected(at: 10.8)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "字")
        #expect(hud.states.last == .notice("已凍結，未退回文字"))
    }

    /// 沒有 AX 的 App：語音修正與 undo 都只提示，raw 與指令話語都留在欄位、帳本照鏡像入帳。
    @Test func correctionAndUndoWithoutAXKeepRawAndNotify() async {
        let env = StatefulFieldEnvironment()
        env.axCapable = false
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["內容": .newContent("內容。"), "改一下": .editedSession("改。"), "復原": .undo]
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("內容"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value           // 潤飾 unverified → keepRaw（建版本）
        c.handleTranscript(.finalized("改一下"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value           // 修正 unverified
        #expect(hud.states.contains(.notice("未修正（無法確認文字位置）")))
        #expect(env.text(in: "A") == Self.previous + "內容改一下")
        #expect(c.ledger.sessionText == "內容改一下")
        c.handleTranscript(.finalized("復原"), at: 15.0)
        c.tick(at: 16.6); await c.lastIntentTask?.value           // undo unverified
        #expect(hud.states.contains(.notice("未復原（無法確認文字位置）")))
        #expect(env.text(in: "A") == Self.previous + "內容改一下復原")
        #expect(!c.ledger.frozen)
    }

    /// 連續講話：第一句潤飾晚到、第二句已落地 → 就地回收；之後 Esc 仍要把兩句都退掉（鏡像的中段更新要正確）。
    @Test func staleTailRecoveryThenEscapeRetractsEverything() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.gated = true
        polisher.outcomeByRaw = ["第一段": .newContent("第一段。"), "第二段": .newContent("第二段。")]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("第一段"), at: 11.0)
        c.tick(at: 12.6)                                          // 第一段潤飾發出（卡住）
        c.handleTranscript(.finalized("第二段"), at: 13.0)        // 尾端前進
        polisher.gated = false; polisher.release(); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "第一段。第二段", "第一段就地回收，第二段不動")
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "第一段。第二段。")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous)
    }

    /// lease 紀律（#43）在完整 session 裡成立：結束後 registry 沒有殘留持有者。
    @Test func identityRegistryIsBalancedAfterASession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("字。")
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("字"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("再一句"), at: 13.0)
        c.escapePressed()
        #expect(env.identityEntryCount == 0)
    }

    // MARK: - issue #46：兩個設定

    /// 4 格設定 × 是否凍結。欄位：PREV＋「你好。」（已潤飾）＋「再見」（raw、仍在說）。
    struct EscapeSettingCell: Sendable, CustomTestStringConvertible {
        let retractsPolished: Bool
        let retractsFrozen: Bool
        let frozen: Bool
        var testDescription: String { "polished=\(retractsPolished) frozenSetting=\(retractsFrozen) frozen=\(frozen)" }
    }
    static let settingMatrix: [EscapeSettingCell] = [true, false].flatMap { p in
        [true, false].flatMap { f in [false, true].map { EscapeSettingCell(retractsPolished: p, retractsFrozen: f, frozen: $0) } }
    }

    @Test(arguments: settingMatrix) func escapeSettingMatrix(_ cell: EscapeSettingCell) async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["呃你好": .newContent("你好。")]
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher)
        c.settings.escapeRetractsPolishedText = cell.retractsPolished
        c.settings.escapeRetractsFrozenSession = cell.retractsFrozen
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("再見"), at: 13.0)                 // raw，尚未閉合
        #expect(env.text(in: "A") == Self.previous + "你好。再見")
        if cell.frozen { c.userActivityDetected(at: 13.5) }
        c.escapePressed()
        let retracts = !cell.frozen || cell.retractsFrozen
        let expected = !retracts ? Self.previous + "你好。再見"
            : cell.retractsPolished ? Self.previous : Self.previous + "你好。"
        #expect(env.text(in: "A") == expected)
        #expect(hud.states.last == (retracts ? .hidden : .notice("已凍結，未退回文字")))
        #expect(c.phase == .idle)
    }

    /// 只退 raw：A degraded（raw 留在欄位）、B 已潤飾 → 只保留 B。polished 鏡像不能是「最後一次完整全文」。
    @Test func polishedOnlyEscapeDropsDegradedRawButKeepsLaterPolish() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["呃第一句": .degraded(reason: "逾時 3 秒"), "第二句": .newContent("第二句。")]
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃第一句"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("第二句"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "呃第一句第二句。")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "第二句。")
        #expect(history.finished.last?.finalText == "第二句。", "History 反映退回後的欄位")
    }

    /// 只退 raw：語音修正把整段換成 LLM 產物 → 整段都算已潤飾，之後說的 raw 才退。
    @Test func polishedOnlyEscapeKeepsCorrectedSessionText() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["內容": .newContent("內容。"), "改一下": .editedSession("改好了。")]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("內容"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("改一下"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "改好了。")
        c.handleTranscript(.finalized("尾巴"), at: 15.0)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "改好了。")
    }

    /// 只退 raw：undo 之後 polished 鏡像也要回上一版——否則 Esc 會把已復原掉的「二。」寫回欄位。
    @Test func polishedOnlyEscapeAfterUndoDoesNotResurrectUndoneText() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["一": .newContent("一。"), "二": .newContent("二。"), "復原": .undo]
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("一"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("二"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "一。二。")
        c.handleTranscript(.finalized("復原"), at: 15.0)
        c.tick(at: 16.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "一。")
        c.handleTranscript(.finalized("三"), at: 17.0)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "一。")
    }

    /// 只退 raw：undo 因尾端已前進而失敗（欄位沒動）→ 帳本與 polished 鏡像都要回到復原前，
    /// 且先前 degraded 的 raw「呃」不得因此被洗成已潤飾。
    @Test func polishedOnlyEscapeAfterFailedUndoKeepsExactlyThePolishedText() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcomeByRaw = ["呃": .degraded(reason: "逾時 3 秒"), "一": .newContent("一。"), "復原": .undo]
        polisher.gatedRaws = ["復原"]
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.handleTranscript(.finalized("一"), at: 13.0)
        c.tick(at: 14.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == Self.previous + "呃一。")
        c.handleTranscript(.finalized("復原"), at: 15.0)
        c.tick(at: 16.6)                                              // undo 在途（卡 gate）
        c.handleTranscript(.finalized("三"), at: 17.0)                // 尾端前進
        polisher.release(); await c.lastIntentTask?.value
        #expect(hud.states.contains(.notice("未復原（新內容已接續）")))
        #expect(env.text(in: "A") == Self.previous + "呃一。復原三")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "一。")
    }

    /// 只退 raw＋選取即目標：已替換的選取是 LLM 產物，保留；沒有 raw 可退，Esc 只結束聽寫。
    @Test func polishedOnlyEscapeKeepsReplacedSelection() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "前舊字後")
        env.select(in: "A", location: 1, length: 2)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("新字")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("新字"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        #expect(env.text(in: "A") == "前新字後")
        c.escapePressed()
        #expect(env.text(in: "A") == "前新字後")
        #expect(hud.states.last == .hidden)
        #expect(history.finished.last?.finalText == "新字")
    }

    /// 凍結後仍退（設定開）：使用者凍結後在 session 之後手打的字在範圍外，保留；session 範圍退掉。
    @Test func frozenEscapeWithSettingOnRetractsSessionRangeAndKeepsTypedSuffix() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("你好。")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.escapeRetractsFrozenSession = true
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        env.typeUserText("手打"); c.userActivityDetected(at: 13.0)
        #expect(c.ledger.frozen)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "手打")
        #expect(hud.states.last == .hidden)
        #expect(history.finished.last?.finalText == nil, "退光了：History 沒有最終文字")
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.isEmpty)
    }

    /// 凍結後仍退（設定開）：手打進了 session 範圍內＝內容不符，fail closed：一個字不動、只提示。
    @Test func frozenEscapeWithSettingOnFailsClosedWhenUserTypedInsideTheSessionRange() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("你好。")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.escapeRetractsFrozenSession = true
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        env.select(in: "A", location: Self.previous.utf16.count + 1, length: 0)   // 游標移到「你」之後
        env.typeUserText("X"); c.userActivityDetected(at: 13.0)
        #expect(env.text(in: "A") == Self.previous + "你X好。")
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "你X好。")
        #expect(hud.states.last == .notice(DictationController.retractionUnverifiedNotice))
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.last?.outcomeText == "fieldMismatch")
    }

    /// 凍結後仍退（設定開）＋沒有 AX 的 App：一樣 fail closed，只提示。設定不是 verified AX 規則的例外。
    @Test func frozenEscapeWithSettingOnWithoutAXOnlyNotifies() {
        let env = StatefulFieldEnvironment()
        env.axCapable = false
        env.addField("A", text: Self.previous)
        let (c, _, hud) = makeStatefulController(env: env)
        c.settings.escapeRetractsFrozenSession = true
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("字"), at: 10.5)
        c.userActivityDetected(at: 10.8)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "字")
        #expect(hud.states.last == .notice(DictationController.retractionUnverifiedNotice))
    }

    /// 凍結、設定關、只退 raw、而且全部都已潤飾：Esc 本來就不會退任何東西，不該提示「未退回文字」、也不記 insertSkipped。
    @Test func frozenEscapeStaysQuietWhenNothingWouldBeRetracted() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: Self.previous)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("你好。")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.escapeRetractsPolishedText = false
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("呃你好"), at: 11.0)
        c.tick(at: 12.6); await c.lastIntentTask?.value
        c.userActivityDetected(at: 13.0)
        c.escapePressed()
        #expect(env.text(in: "A") == Self.previous + "你好。")
        #expect(hud.states.last == .hidden)
        #expect(history.exchanges.filter { $0.outcomeKind == "insertSkipped" }.isEmpty)
    }
}
