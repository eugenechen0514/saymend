import Testing
@testable import SaymendCore

/// issue #20／#11：使用者說的話「沒上屏、也沒留下任何紀錄」的路徑。
///
/// #20 的實機證據是：尾端補發的一整段沒上屏、`history_exchange` 裡一列都沒有。
/// 當時查得到的兩條嫌疑路徑都是零紀錄——
/// ① `handleTranscript` 開頭的相位守衛（`.idle`／`.lingering` 直接 return）；
/// ② `insertFinalized` 擲錯（只救剪貼簿、發提示，不記 insertEvent）。
/// 而 #11 是第三條：session 封存之後才回來的 LLM outcome，連「被丟棄」都不會記。
///
/// 這三條**不需要重現就能補**，補了才有機會抓到下一次。本檔每條測試都先用前提斷言證明
/// 真的走到了那條路（剪貼簿 spy、欄位內容、相位），再看歷史裡有沒有留下可回查的那一列。
@MainActor
@Suite struct SilentDropDiagnosticsTests {

    private func rows(_ history: FakeHistory, session id: String?) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.sessionID == id }
    }

    private func kinds(_ history: FakeHistory, session id: String?) -> [String] {
        rows(history, session: id).map(\.outcomeKind)
    }

    private func droppedTranscripts(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "finalizedDropped" }
    }

    /// 歷史裡任何一個文字欄位出現過這段字（明文外洩檢查用）
    private func historyMentions(_ history: FakeHistory, _ text: String) -> Bool {
        history.exchanges.contains { $0.utteranceRaw.contains(text) || ($0.outcomeText ?? "").contains(text) }
            || history.diagnostics.contains { $0.finalizedText.contains(text) }
            || history.finished.contains { ($0.finalText ?? "").contains(text) }
    }

    // MARK: - #20 ②：插入擲錯

    /// raw 定稿的 `insertFinalized` 擲錯：剪貼簿救援與救援提示照舊（#41／#61 起就有），
    /// 但歷史裡必須多一列 `insertFailed`——否則救援提示一旦沒被看到，事後完全查不到這段話去了哪裡。
    @Test func aRawInsertFailureLeavesAnInsertFailedRow() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "PREVIOUS", bundleID: "com.foo.app")
        env.failInsertsRemaining = 2                       // keystroke 與 paste 都失敗 → catch 出口
        let spy = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, clipboard: spy, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("順便買個午餐"), at: 10.5)

        #expect(env.text(in: "A") == "PREVIOUS", "前提：一個字都沒進欄位")
        #expect(spy.texts == ["順便買個午餐"], "前提：走的是插入失敗的救援出口")
        let session = history.sessions.first?.id
        let failed = rows(history, session: session).filter { $0.outcomeKind == "insertFailed" }
        #expect(failed.count == 1, "插入擲錯必須留一列；實際：\(history.exchanges)")
        #expect(failed.first?.utteranceRaw == "順便買個午餐", "記的是沒落地的那段話（它同時也進了剪貼簿）")
        #expect(failed.first?.outcomeText == "raw：postFailed", "分類標出是 raw 定稿那條、detail 帶錯誤")
    }

    /// 緩衝句的 `insertDetached` 擲錯：與 raw 那條同一個規則，分類標 `buffered`。
    /// 兩條原本都以「彼此一致」為由不記——一致是對的，該一起記。
    @Test func aBufferedInsertFailureLeavesAnInsertFailedRow() async {
        let intent = GatedIntentService()
        intent.gatedRaws = ["第二句"]
        intent.outcomeByRaw = ["改正式一點": .editedSession("正式版"),
                               "第二句": .newContent("補充內容。")]
        let reader = FakeFieldReader()
        reader.context = selectionField("原文字", location: 4)
        let paste = RecordingInserter()
        let spy = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, _, key, _, _) = makeController(polisher: intent, pasteInserter: paste,
                                                  rangeReplacer: FakeRangeReplacer(), clipboard: spy,
                                                  fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0); c.hotkeyReleased(at: 10.1)
        c.handleTranscript(.finalized("改正式一點"), at: 11.0)
        c.tick(at: 12.6)                                    // 首句：緩衝＋建 task
        let first = c.lastIntentTask
        c.handleTranscript(.finalized("第二句"), at: 13.0)
        c.tick(at: 14.6)                                    // 第二句：仍 .selectionPending → 緩衝
        await first?.value
        #expect(c.ledger.sessionText == "正式版", "前提：首句已替換選取、轉回 .tail")
        key.failInsertsRemaining = 1                        // 主 inserter 與備援都失敗 → catch 出口
        paste.failInsertsRemaining = 1
        intent.release()
        await c.lastIntentTask?.value

        #expect(spy.texts == ["補充內容。"], "前提：走的是緩衝句插入失敗的救援出口")
        let failed = history.exchanges.filter { $0.outcomeKind == "insertFailed" }
        #expect(failed.map(\.outcomeText) == ["buffered：postFailed"], "實際：\(history.exchanges)")
        #expect(failed.first?.utteranceRaw == "補充內容。")
        #expect(failed.first?.sessionID == history.sessions.first?.id)
    }

    // MARK: - #20 ①：相位守衛丟掉的定稿

    /// 排空中按 Esc（`asr.cancel()`＋封存 → `.idle`），之後辨識器仍送來尾端定稿：
    /// 相位守衛照舊丟掉它（Esc 就是要丟），但歷史裡要留一列，掛在剛封存的那個 session 底下。
    ///
    /// **只記字數，不記文字**：走到 `.idle` 的封存原因裡包含密碼欄硬停（`abortForSecureField`），
    /// 那之後送來的定稿可能正是焦點在密碼欄期間說的話（#10 的不變式）。這裡不追蹤封存原因，
    /// 一律只留 metadata——判讀「有沒有發生、發生在哪個 session、多長」已經足夠。
    @Test func aFinalizedArrivingAfterArchiveLeavesAMetadataOnlyRow() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("今天天氣不錯"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 長按放開 → 排空
        c.escapePressed()                                   // 排空中 Esc → 封存 → .idle
        #expect(!c.isEngaged, "前提：已回到 idle")
        #expect(history.finished.count == 1, "前提：session 已封存")

        c.handleTranscript(.finalized("順便買個午餐"), at: 11.5)

        let dropped = droppedTranscripts(history)
        #expect(dropped.count == 1, "相位守衛丟掉的定稿必須留一列；實際：\(history.exchanges)")
        #expect(dropped.first?.sessionID == history.sessions.first?.id, "掛在剛封存的那個 session 底下")
        #expect(dropped.first?.outcomeText == "idle：chars:6")
        #expect(dropped.first?.utteranceRaw == "", "不記文字")
        #expect(!historyMentions(history, "順便買個午餐"), "被丟掉的文字不得出現在歷史的任何欄位")
        #expect(env.text(in: "A") == "今天天氣不錯", "相位守衛照舊：不上屏")
    }

    /// 密碼欄硬停之後送來的定稿：這正是「只記字數」的理由——一個字都不能留。
    @Test func aFinalizedArrivingAfterASecureAbortLeavesNoText() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true, bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        env.focus("P")                                      // 焦點被搬進密碼欄（沒有 focusWatcher）
        c.handleTranscript(.finalized("我的密碼是"), at: 10.5)  // 定稿閘門 → .secure → 硬停
        #expect(hud.states.contains(.notice("密碼欄位不聽寫")), "前提：走的是密碼欄硬停")
        #expect(!c.isEngaged, "前提：已回到 idle")

        c.handleTranscript(.finalized("1234"), at: 10.8)    // 硬停前已在辨識器裡的那段

        #expect(droppedTranscripts(history).map(\.outcomeText) == ["idle：chars:4"])
        #expect(!historyMentions(history, "1234"), "密碼欄期間的字一個都不能進歷史")
        #expect(!historyMentions(history, "我的密碼是"))
        #expect(env.text(in: "P") == "")
    }

    /// 延續窗中收到定稿（目前的 readerTask 順序讓它不該發生——正因如此更要有警報）。
    /// session 還沒封存，掛在目前的 session 底下。
    @Test func aFinalizedArrivingDuringLingeringLeavesAMetadataOnlyRow() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("第一句。")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)                          // flush → 潤飾；進延續窗
        await c.lastIntentTask?.value
        #expect(c.isLingering, "前提：在延續窗")
        let fieldBefore = env.text(in: "A")

        c.handleTranscript(.finalized("遲到的定稿"), at: 12.0)

        let dropped = droppedTranscripts(history)
        #expect(dropped.map(\.outcomeText) == ["lingering：chars:5"], "實際：\(history.exchanges)")
        #expect(dropped.first?.sessionID == history.sessions.first?.id)
        #expect(dropped.first?.utteranceRaw == "")
        #expect(env.text(in: "A") == fieldBefore, "相位守衛照舊：不上屏")
        #expect(c.isLingering, "也不改變相位")
    }

    /// 只有「有內容的定稿」才算使用者的話被丟掉：暫時文字、空定稿、示警事件都不記。
    @Test func nonContentEventsAfterArchiveLeaveNoRow() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.escapePressed()
        #expect(history.finished.count == 1, "前提：session 已封存")

        c.handleTranscript(.volatile("暫時"), at: 10.5)
        c.handleTranscript(.finalized(""), at: 10.6)
        c.handleTranscript(.noSpeechDetected, at: 10.7)

        #expect(history.exchanges.isEmpty, "實際：\(history.exchanges)")
    }

    /// 封存時的「上一個 session」必須每次封存都覆寫——包括沒有歷史 id 的 session。
    /// 否則：A（有記錄）封存 → B（歷史關閉時開的、沒有 id）封存 → 遲到的定稿會被掛到 **A** 底下。
    @Test func aLateFinalizedNeverAttachesToAnOlderSession() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.escapePressed()                                   // A 封存（有 id）
        c.settings.historyEnabled = false
        c.hotkeyPressed(at: 20.0)
        c.escapePressed()                                   // B 封存（沒有 id）
        c.settings.historyEnabled = true
        #expect(history.sessions.count == 1, "前提：只有 A 有歷史 session")

        c.handleTranscript(.finalized("B 的尾端"), at: 20.5)

        #expect(history.exchanges.isEmpty, "B 的遲到定稿不得掛到 A 底下；實際：\(history.exchanges)")
    }

    // MARK: - #11：封存後才回來的 outcome

    /// issue #11 的觸發路徑：延續窗中點擊滑鼠 → 靜默封存 → 潤飾稍後才回來。
    /// 以前：`historySessionID` 已清成 nil，outcome 列與丟棄都零紀錄。
    /// 現在：outcome 列照記（掛在**話語閉合當下**的 session），後面跟一列說明它被丟棄了。
    @Test func anOutcomeReturningAfterArchiveIsRecordedAndMarkedDropped() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gated = true
        polisher.outcome = .newContent("第一句。")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)                          // flush → 潤飾在途；進延續窗
        #expect(c.isLingering, "前提：在延續窗")
        c.userActivityDetected(at: 11.5)                    // 延續窗點擊 → 靜默封存
        #expect(history.finished.count == 1, "前提：session 已封存")
        polisher.release()
        await c.lastIntentTask?.value

        let session = history.sessions.first?.id
        #expect(kinds(history, session: session) == ["newContent", "outcomeDropped"],
                "實際：\(history.exchanges)")
        let outcome = rows(history, session: session).first
        #expect(outcome?.utteranceRaw == "第一句")
        #expect(outcome?.outcomeText == "第一句。")
        let dropped = rows(history, session: session).last
        #expect(dropped?.outcomeText == "sessionEnded")
        #expect(dropped?.utteranceRaw == "第一句")
        #expect(env.text(in: "A") == "第一句", "遲到的潤飾照舊不落地")
    }

    /// 遲到的 outcome 回來時使用者已經開了新 session B：outcome 列必須掛在 **A** 底下。
    /// 以前 `dispatch` 用的是**呼叫當下**的 `historySessionID`，A 的 outcome 會被記成 B 的。
    @Test func anOutcomeReturningAfterTheNextSessionStartedIsRecordedUnderItsOwnSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["第一句"]                      // 只卡 A 那句
        polisher.outcomeByRaw = ["第一句": .newContent("第一句。"), "第二句": .newContent("第二句。")]
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)
        c.userActivityDetected(at: 11.5)                    // A 封存（outcome 在途）
        c.hotkeyPressed(at: 20.0)                           // 全新的 session B
        c.handleTranscript(.finalized("第二句"), at: 20.5)
        c.tick(at: 22.1)                                    // B 的話語閉合（套用排在 A 之後）
        polisher.release()                                  // A 的 outcome 這時才回來
        await c.lastIntentTask?.value

        #expect(history.sessions.count == 2, "前提：確實開了兩個 session")
        let a = history.sessions.first?.id, b = history.sessions.last?.id
        #expect(kinds(history, session: a) == ["newContent", "outcomeDropped"], "實際：\(history.exchanges)")
        #expect(rows(history, session: a).first?.outcomeText == "第一句。")
        #expect(!rows(history, session: b).contains { $0.utteranceRaw == "第一句" || $0.outcomeText == "第一句。" },
                "A 的 outcome 不得記到 B 底下；實際：\(rows(history, session: b))")
        #expect(kinds(history, session: b) == ["newContent"], "B 自己那句照常")
    }

    /// A 開始時歷史是關的（沒有 id），遲到的 outcome 回來時 B 已經有 id：A 的東西一列都不能進 B。
    /// 釘的是「話語閉合當下沒有 id＝不記」，不是「沒有就借用現在的」。
    @Test func anOutcomeFromASessionWithoutHistoryIsNeverRecordedUnderTheNextOne() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["第一句"]
        polisher.outcomeByRaw = ["第一句": .newContent("第一句。"), "第二句": .newContent("第二句。")]
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.settings.historyEnabled = false
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)
        c.userActivityDetected(at: 11.5)                    // A 封存（沒有歷史 id）
        c.settings.historyEnabled = true
        c.hotkeyPressed(at: 20.0)                           // B 有歷史 id
        c.handleTranscript(.finalized("第二句"), at: 20.5)
        c.tick(at: 22.1)
        polisher.release()
        await c.lastIntentTask?.value

        #expect(history.sessions.count == 1, "前提：只有 B 有歷史 session")
        #expect(!historyMentions(history, "第一句"), "實際：\(history.exchanges)")
    }

    /// 話語閉合當下有在記錄、outcome 回來之前使用者把歷史關掉：一列都不補——
    /// outcome 列與 `sessionEnded` 那列都一樣。捕捉的是「掛在哪個 session」，不是「准不准記」，
    /// 准不准記永遠以寫入當下的設定為準。
    @Test func turningHistoryOffBeforeALateOutcomeReturnsRecordsNothing() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gated = true
        polisher.outcome = .newContent("第一句。")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)
        c.userActivityDetected(at: 11.5)                    // 封存（outcome 在途）
        #expect(history.sessions.count == 1, "前提：閉合當下有在記錄")
        c.settings.historyEnabled = false                   // 使用者關掉歷史
        c.handleTranscript(.finalized("尾端"), at: 11.6)     // 順便：相位丟棄那列也不得補記
        polisher.release()
        await c.lastIntentTask?.value

        #expect(history.exchanges.isEmpty, "關閉之後一列都不補；實際：\(history.exchanges)")
    }

    /// 選取即目標的緩衝句在封存後才回來：內容照舊救進剪貼簿（既有行為），
    /// 歷史裡 outcome 列之後跟一列 `insertSkipped/sessionEnded`——內容沒丟，是沒寫進欄位。
    @Test func aBufferedOutcomeRescuedAfterArchiveIsRecordedAsSkipped() async {
        let intent = GatedIntentService()
        intent.gatedRaws = ["改正式一點"]
        intent.outcomeByRaw = ["改正式一點": .editedSession("正式版")]
        let reader = FakeFieldReader()
        reader.context = selectionField("原文字", location: 4)
        let spy = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, asr, key, _, _) = makeController(polisher: intent, rangeReplacer: FakeRangeReplacer(),
                                                    clipboard: spy, fieldReader: reader, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("改正式一點"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        asr.continuation?.finish()
        c.asrStreamEnded(at: 11.1)                          // 延續窗（LLM 在途）
        c.userActivityDetected(at: 11.5)                    // 延續窗點別處 ＝ 立即封存
        intent.release()
        await c.lastIntentTask?.value

        #expect(spy.texts == ["正式版"], "前提：走的是世代過期的緩衝句救援")
        #expect(key.ops.isEmpty)
        let session = history.sessions.first?.id
        #expect(kinds(history, session: session) == ["editedSession", "insertSkipped"], "實際：\(history.exchanges)")
        #expect(rows(history, session: session).last?.outcomeText == "sessionEnded")
        #expect(rows(history, session: session).last?.utteranceRaw == "改正式一點")
    }

    /// 部分片段被寫入前閘門跳過的那句（#37），outcome 在封存、開新 session 之後才回來：
    /// 以前怕記錯 session 而乾脆不記（世代守衛）；現在用話語閉合當下的 id，記在 A 底下。
    @Test func aStaleSkippedRawOutcomeIsRecordedUnderItsOwnSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let polisher = GatedIntentService()
        polisher.gatedRaws = ["片段一片段二"]
        polisher.outcomeByRaw = ["片段一片段二": .newContent("不該落地。"),
                                 "新的一句": .newContent("新的一句。")]
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher,
                                               clipboard: ClipboardSpy(), history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("片段一"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("片段二"), at: 10.8)  // 部分跳過（.fieldChanged）
        env.focus("A")
        c.tick(at: 12.4)                                    // A 的話語閉合，LLM 卡在 gate
        c.escapePressed()                                   // A 封存
        c.hotkeyPressed(at: 20.0)                           // 全新的 session B
        c.handleTranscript(.finalized("新的一句"), at: 20.5)
        c.tick(at: 22.1)
        polisher.release()
        await c.lastIntentTask?.value

        let a = history.sessions.first?.id, b = history.sessions.last?.id
        let droppedA = rows(history, session: a).filter { $0.outcomeKind == "outcomeDropped" }
        #expect(droppedA.map(\.outcomeText) == ["skippedRaw"], "實際：\(rows(history, session: a))")
        #expect(!rows(history, session: b).contains { $0.outcomeKind == "outcomeDropped" })
    }
}

/// 有 AX 的選取欄位（同 DictationControllerTests 的同名 helper；那邊是 file-private）
private func selectionField(_ text: String, location: Int) -> FieldContext {
    FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: location,
                 fieldIdentity: FieldIdentity(token: 1),
                 selectedRange: .init(location: location, length: text.utf16.count),
                 selectedText: text)
}
