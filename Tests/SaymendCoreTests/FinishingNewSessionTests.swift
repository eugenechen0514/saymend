import Testing
@testable import SaymendCore

/// issue #83：放開熱鍵後、辨識還在排空（`.finishing`）時再按熱鍵＝立刻開新 session。
///
/// 「開新 session」這個取捨不變，變的是**舊 session 要先封存乾淨**——比照排空中按 Esc。
/// 以前 `startListening` 直接 `ledger.begin` 覆寫舊 session，完全不經 `archiveSession()`：
/// ① 舊 session 永遠不 `finishSession`（歷史沒定稿）；② 起始欄位的 lease 漏還（#43）；
/// ③ `readerTask?.cancel()` 終止舊的辨識串流，還沒送達的定稿就此消失、零紀錄。
/// ③ 的「捨棄」本身不在本票範圍（保住它是行為變更，另議），但至少要在舊 session 留一列。
@MainActor
@Suite struct FinishingNewSessionTests {

    private func rows(_ history: FakeHistory, session id: String?) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.sessionID == id }
    }

    /// 舊 session 開始潤飾過一句（帳本有內容）、第二句還在排空時按熱鍵：舊 session 要以帳本全文定稿。
    @Test func pressingTheHotkeyWhileDrainingFinishesTheOldHistorySession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("第一句。")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.tick(at: 12.1)                                    // 第一句閉合 → 潤飾
        await c.lastIntentTask?.value
        #expect(c.ledger.sessionText == "第一句。", "前提：帳本已有潤飾後的第一句")
        c.handleTranscript(.finalized("第二句"), at: 12.5)
        c.hotkeyReleased(at: 13.0)                          // 長按放開 → 排空
        #expect(c.isEngaged && c.phase == .idle && !c.isLingering, "前提：在排空窗")

        c.hotkeyPressed(at: 13.5)                           // 排空中按下 → 新 session

        let a = history.sessions.first?.id
        #expect(history.sessions.count == 2, "前提：確實開了新 session")
        #expect(history.finished.map(\.id) == [a], "舊 session 必須在新 session 開始前封存；實際：\(history.finished)")
        #expect(history.finished.first?.finalText == "第一句。", "以封存當下的帳本全文定稿")
        #expect(c.phase == .listening(.hold), "新 session 照常開始")

        c.escapePressed()
        #expect(history.finished.map(\.id) == history.sessions.map(\.id), "兩個 session 各封存一次")
    }

    /// lease（#43）：全部封存之後 registry 一筆都不能剩。
    @Test func pressingTheHotkeyWhileDrainingReleasesTheOldFieldLease() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 排空
        #expect(env.identityEntryCount == 1, "前提：舊 session 持有起始欄位的 lease")

        c.hotkeyPressed(at: 11.5)                           // 排空中按下 → 新 session
        c.escapePressed()                                   // 新 session 封存

        #expect(env.identityEntryCount == 0, "每個 lease 恰歸還一次；殘留＝舊 session 那份漏還")
    }

    /// 被捨棄的排空在**舊** session 留一列：內容不知道（串流已終止、還沒送達），只記事件本身。
    @Test func theAbandonedDrainLeavesARowOnTheOldSession() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 排空
        c.hotkeyPressed(at: 11.5)                           // 排空中按下 → 新 session

        let a = history.sessions.first?.id, b = history.sessions.last?.id
        let abandoned = history.exchanges.filter { $0.outcomeKind == "drainAbandoned" }
        #expect(abandoned.count == 1, "實際：\(history.exchanges)")
        #expect(abandoned.first?.sessionID == a, "掛在被取代的舊 session 底下")
        #expect(abandoned.first?.outcomeText == "newSession")
        #expect(abandoned.first?.utteranceRaw == "", "內容不知道，不記")
        #expect(rows(history, session: b).isEmpty, "新 session 不得多出這一列")
    }

    /// 新 session 照常運作：定稿掛在新 session、上屏接在後面；舊 session 的 session 級覆蓋不得帶過來。
    @Test func theNewSessionStartsCleanAfterTheOldOneIsArchived() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.settings.sessionLanguageOverride = .english        // 舊 session 的臨時語系覆蓋（規格 §4.5）
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 排空
        c.hotkeyPressed(at: 11.5)                           // 排空中按下 → 新 session

        #expect(c.settings.sessionLanguageOverride == nil, "per-session 覆蓋隨舊 session 封存失效")
        c.handleTranscript(.finalized("第二句"), at: 12.0)
        #expect(env.text(in: "A") == "第一句第二句", "新 session 的定稿照常上屏")
        #expect(c.ledger.isActive && !c.ledger.frozen)
        #expect(history.sessions.count == 2)
    }

    /// 延續窗中按下＝同 session 續聽（規格 §3.4），**不得**封存——本票只動排空窗那條路。
    @Test func pressingTheHotkeyDuringLingeringStillResumesTheSameSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)                          // 進延續窗
        await c.lastIntentTask?.value
        #expect(c.isLingering, "前提：在延續窗")

        c.hotkeyPressed(at: 12.0)

        #expect(history.sessions.count == 1, "同 session 續聽，不開新的")
        #expect(history.finished.isEmpty, "不得封存")
        #expect(!history.exchanges.contains { $0.outcomeKind == "drainAbandoned" })
    }
}
