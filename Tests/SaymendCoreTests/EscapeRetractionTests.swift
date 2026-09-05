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
}
