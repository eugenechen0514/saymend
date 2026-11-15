import Foundation
import Testing
@testable import SaymendCore

/// issue #65：暫時文字（volatile）上 HUD 之前的密碼欄閘門。
///
/// 轉錄文字進 HUD 只有一條路：`.volatile` 分支以非空 text 呼叫 `presentListening`。
/// M2 以來那條路完全沒有守衛——密碼欄守衛只掛在 `.finalized` 上，所以「對 A 說話 → Tab 進密碼欄 P →
/// 說數字」時，數字會在 `.finalized` 觸發硬停**之前**逐字畫在 Saymend 自己的浮條上（螢幕分享／錄影可見）。
///
/// 判定表（計畫 §4.1）：
/// - 空字串／已遮罩：顯示 `""`，不查閘門
/// - `.same`／`.different`／`.unknown` 且起點就沒有 identity（#21）：照常顯示
/// - `.unknown` 且 session 有 identity（讀不到焦點）、`.secureUnknown`：遮罩＋熔斷（本段不再查）
/// - `.secure`：不呈現，`abortForSecureField()` 硬停（與定稿路徑逐字相同，不記 insertEvent）
///
/// 這裡全部**不包 HUDArbiter**：FakeHUD 直接觀察 controller 的原始輸出。
@Suite @MainActor struct VolatileSecureFieldTests {

    /// HUD 上所有「聽寫中」狀態帶的暫時文字（依序）。
    private func volatiles(_ states: [HUDState]) -> [String] {
        states.compactMap {
            switch $0 {
            case .listening(_, let v), .selectionListening(_, let v): return v
            default: return nil
            }
        }
    }

    // MARK: - V1：空窗期（尚無任何定稿時就切進密碼欄）

    /// 失敗情境本身（issue #65）：對 A 說「我的密碼是」→ 不放開熱鍵、焦點被搬進密碼欄 P → 說「1234」。
    /// 定稿還沒抵達，定稿路徑的守衛根本沒機會跑——只有暫時文字這一道擋得住。
    @Test func focusMovedIntoAPasswordFieldBeforeAnyFinalizedNeverShowsTheDigits() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let (c, asr, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("我的密碼是"), at: 10.3)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "我的密碼是"), "前提：一般欄位照常預覽")

        env.focus("P")                                     // Tab／頁面 JS，不觸發使用者活動偵測
        c.handleTranscript(.volatile("我的密碼是1234"), at: 10.6)

        #expect(!volatiles(hud.states).contains { $0.contains("1234") }, "密碼欄的字一個都不得畫上 HUD")
        #expect(!c.ledger.isActive, "與定稿路徑的 `.secure` 一致：硬停整個 session")
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(asr.cancelCount == 1, "前提：走的是 abortForSecureField（停辨識）")
        #expect(env.fieldGateCalls == 2, "每個非空暫時文字在顯示前各查一次閘門")
        #expect(env.text(in: "P") == "")
    }

    // MARK: - V2／V3：secureUnknown 只遮罩、不 abort、不寫 DB；遮罩不得短路定稿閘門

    /// `.secureUnknown`（AX 連兩次問不出 subrole）＝「不知道」：預覽遮掉、本段之後都不再查（熔斷），
    /// 但 session 照常——內容層的 fail closed 交給定稿路徑那道既有閘門。
    /// 隱私不變式（#10）：暫時文字路徑**不得**寫任何持久容器。
    @Test func secureUnknownMasksTheRestOfTheSegmentWithoutAbortingOrRecording() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        #expect(history.sessions.count == 1, "前提：歷史確實在記錄（否則下面的「沒寫」是空話）")
        let before = hud.states.count

        c.handleTranscript(.volatile("一"), at: 10.2)
        env.focus("U")
        c.handleTranscript(.volatile("一二"), at: 10.4)
        env.focus("A")                                     // 焦點回到 A 也不解除：本段已遮
        c.handleTranscript(.volatile("一二三"), at: 10.6)

        #expect(volatiles(Array(hud.states.dropFirst(before))) == ["一", "", ""])
        #expect(c.ledger.isActive, "secureUnknown 只遮罩，不硬停")
        #expect(asr.cancelCount == 0)
        #expect(history.exchanges.isEmpty, "暫時文字路徑不得呼叫 recordInsertEvent（#10）")
        #expect(history.diagnostics.isEmpty, "暫時文字路徑不得呼叫 recordASRDiagnostic（#10）")
        #expect(env.fieldGateCalls == 2, "遮罩後不再查閘門（熔斷）：第三則不查")
    }

    /// §5.3 回歸：遮罩不得讓定稿路徑的閘門被省略。接 V2 的已遮狀態，定稿在 U 抵達。
    @Test func maskedSegmentStillAbortsOnAFinalizedInASecureUnknownField() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let (c, _, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("一"), at: 10.2)
        env.focus("U")
        c.handleTranscript(.volatile("一二"), at: 10.4)    // 遮罩
        c.handleTranscript(.finalized("x"), at: 10.8)

        #expect(!c.ledger.isActive, "定稿閘門照跑：secureUnknown 硬停")
        let rows = history.exchanges.filter { ($0.outcomeText ?? "").hasPrefix("secureUnknown") }
        #expect(rows.count == 1)
        #expect(rows.first?.utteranceRaw == "", "定稿文字一個字都不得落進 history_exchange")
        #expect(history.exchanges.count == 1)
        #expect(env.text(in: "U") == "")
    }

    /// 同一條 §5.3 回歸的**承重版**：上一條在 tail 路徑上，就算遮罩短路掉 controller 的定稿閘門，
    /// `InsertionCoordinator` 寫入前那道閘門也會回 `.secureField(subroleUnknown: true)`，記下逐字相同的一列再 abort——
    /// 黑箱看不出差別。凍結終點跑在 `insertFinalized` **之前**，controller 的閘門是唯一一道：
    /// 短路掉它，定稿文字就會被救進剪貼簿、記進 `insertSkipped/frozen`（`utteranceRaw` 帶原文）與 `asr_diagnostic`。
    /// 情境本身很實際：使用者用滑鼠點進那個欄位＝ mouseDown ＝凍結。
    @Test func maskedSegmentStillRunsTheFinalizedGateBeforeTheFrozenRescue() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let spy = ClipboardSpy()
        let (c, _, _) = makeStatefulController(env: env, clipboard: spy, history: history)
        let quality = TranscriptQuality(minAvgLogprob: -0.25, maxCompressionRatio: 1.125, segmentCount: 1)
        c.hotkeyPressed(at: 10.0)
        env.focus("U")
        c.handleTranscript(.volatile("密"), at: 10.4)      // secureUnknown → 遮罩
        c.userActivityDetected(at: 10.5)                   // 點進 U ＝凍結
        #expect(c.ledger.frozen, "前提：走到凍結終點之前")
        c.handleTranscript(.finalized("密碼1234", quality: quality), at: 10.8)

        #expect(!c.ledger.isActive, "定稿閘門照跑：secureUnknown 硬停")
        #expect(spy.texts.isEmpty, "可能是密碼欄：不得救進剪貼簿")
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("1234") }, "不得落進 asr_diagnostic")
        #expect(!history.exchanges.contains { $0.utteranceRaw.contains("1234") }, "不得落進 history_exchange")
        #expect(history.exchanges.filter { ($0.outcomeText ?? "").hasPrefix("secureUnknown") }.count == 1)
    }

    // MARK: - V4：讀不到焦點的熔斷

    /// session 起點有 identity，之後卻問不出焦點（含 AX 逾時）＝不知道現在在哪個欄位：遮罩，且不再查——
    /// 逾時型的慢 App 每查一次就是 0.2s，熔斷把代價壓在每段最多一次。
    @Test func unreadableFocusWithASessionIdentityMasksAndStopsQuerying() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        #expect(c.ledger.fieldIdentity != nil, "前提：session 起點有 identity")
        c.handleTranscript(.volatile("a"), at: 10.2)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "a"))

        env.blur()
        let before = hud.states.count
        c.handleTranscript(.volatile("ab"), at: 10.4)
        c.handleTranscript(.volatile("abc"), at: 10.6)

        #expect(volatiles(Array(hud.states.dropFirst(before))) == ["", ""])
        #expect(env.fieldGateCalls == 2, "a 與 ab 各查一次；遮罩後 abc 不查")
        #expect(c.ledger.isActive, "讀不到焦點不是密碼欄：只遮罩")
    }

    // MARK: - V5：與 #21 一致

    /// 起點就沒有 AX 焦點（沒有 identity 的 App）：`.unknown` 是常態，照常預覽——
    /// 把所有 `.unknown` 一律遮掉的話，這類 App 的使用者從此看不到任何預覽。
    @Test func noIdentityFromTheStartKeepsShowingThePreview() {
        let reader = FakeFieldReader()                     // 有聚焦元素、無 identity
        let (c, _, _, _, _, hud) = makeController(fieldReader: reader)
        c.hotkeyPressed(at: 10.0)
        #expect(c.ledger.fieldIdentity == nil, "前提：起點就沒有 identity")
        c.handleTranscript(.volatile("你"), at: 10.5)
        #expect(reader.snapshots == 2, "前提：閘門確實查過（預設閘門由 snapshot 推導）")
        #expect(hud.states.last == .listening(mode: .hold, volatile: "你"))
    }

    // MARK: - V6：換到別的一般欄位不遮

    @Test func aDifferentNonSecureFieldStillShowsThePreview() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.volatile("x"), at: 10.3)
        #expect(env.fieldGateCalls == 1, "前提：閘門查過且回 .different")
        #expect(hud.states.last == .listening(mode: .hold, volatile: "x"),
                "預覽只是本機畫面；寫入層的 .different 攔阻由定稿路徑負責")
    }

    // MARK: - V7：空字串不查

    @Test func emptyVolatileDoesNotQueryTheGate() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        let before = hud.states.count
        c.handleTranscript(.volatile(""), at: 10.3)
        #expect(hud.states.count == before + 1, "前提：這則確實有呈現")
        #expect(hud.states.last == .listening(mode: .hold, volatile: ""))
        #expect(env.fieldGateCalls == 0, "沒有字可洩漏，不付 AX IPC")
    }

    // MARK: - V8：遮罩在下一段重置

    /// 遮罩是「本段」的：Esc 結束、回到一般欄位重新按下熱鍵，預覽要恢復。
    @Test func maskResetsWhenANewSegmentStarts() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("a"), at: 10.2)
        env.blur()
        c.handleTranscript(.volatile("ab"), at: 10.4)
        #expect(hud.states.last == .listening(mode: .hold, volatile: ""), "前提：已遮")

        c.escapePressed()
        #expect(!c.ledger.isActive)
        env.focus("A")
        c.hotkeyPressed(at: 20.0)
        c.handleTranscript(.volatile("新"), at: 20.3)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "新"))
    }

    /// 延續窗內續聽也是「新的一段」（`startListening` 是進入 `.listening` 的唯一入口）。
    @Test func maskResetsWhenResumingInsideTheLingerWindow() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, asr, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("a"), at: 10.2)
        env.blur()
        c.handleTranscript(.volatile("ab"), at: 10.4)
        #expect(hud.states.last == .listening(mode: .hold, volatile: ""), "前提：已遮")

        c.hotkeyReleased(at: 11.0)                         // 非 tap → 排空
        asr.continuation?.finish()
        c.asrStreamEnded(at: 11.1)
        #expect(c.isLingering, "前提：進了延續窗")
        env.focus("A")
        c.hotkeyPressed(at: 12.0)                          // 延續窗內再按＝續聽
        #expect(c.phase == .listening(.hold))
        #expect(c.ledger.isActive, "前提：同一個 session 續聽，不是新 session")
        c.handleTranscript(.volatile("續"), at: 12.3)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "續"))
    }

    // MARK: - V9：選取即目標

    /// 選取即目標模式的 volatile 走 `.selectionListening`——閘門不得只套在 `.listening` 那一支。
    @Test func selectionTargetPreviewIsGatedToo() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "原文字", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        env.select(in: "A", location: 0, length: 3)
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        #expect(hud.states.last == .selectionListening(mode: .hold, volatile: ""), "前提：選取即目標")
        env.focus("U")
        let before = hud.states.count
        c.handleTranscript(.volatile("改"), at: 10.3)
        #expect(hud.states.count == before + 1, "前提：這則確實有呈現")
        #expect(env.fieldGateCalls == 1)
        #expect(hud.states.last == .selectionListening(mode: .hold, volatile: ""))
        #expect(!volatiles(hud.states).contains("改"))
    }

    // MARK: - V10：排空窗不呈現也不查

    @Test func finishingPhaseNeitherShowsNorQueries() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                         // 非 tap → finishing
        #expect(hud.states.last == .hidden, "前提：進了排空窗")
        c.handleTranscript(.volatile("x"), at: 11.2)
        #expect(!volatiles(hud.states).contains("x"))
        #expect(env.fieldGateCalls == 0, "排空窗本來就不呈現，查閘門只是白付 AX IPC")
    }

    // MARK: - V11：#43 lease 不變式

    /// 暫時文字路徑只能呼叫 `fieldGate`，絕不呼叫 `snapshot()`：snapshot 會登記一個 identity 持有者，
    /// controller 不歸還就是 lease 洩漏。用預設閘門（由 snapshot 推導、當場歸還）的 reader 驗帳。
    @Test func volatileGateKeepsTheLeaseBalancedWithTheDefaultGate() {
        let r = FakeFieldReader.sessionField()
        let (c, _, _, _, _, _) = makeController(fieldReader: r)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("一"), at: 10.2)
        c.handleTranscript(.volatile("一二"), at: 10.4)
        c.handleTranscript(.volatile("一二三"), at: 10.6)
        #expect(r.snapshots == 4, "前提：起點一次＋三則暫時文字各查一次閘門")
        c.escapePressed()
        #expect(r.released.count == r.snapshots, "每個非 nil token 恰歸還一次（#43）")
    }

    /// 同一條不變式用輕量閘門（只用 `registry.matches`、不登記持有者）驗：Esc 之後 registry 必須清空。
    @Test func volatileGateKeepsTheLeaseBalancedWithTheLightweightGate() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("一"), at: 10.2)
        c.handleTranscript(.volatile("一二"), at: 10.4)
        c.handleTranscript(.volatile("一二三"), at: 10.6)
        #expect(env.fieldGateCalls == 3, "前提：走的是輕量閘門")
        c.escapePressed()
        #expect(env.identityEntryCount == 0)
    }

    // MARK: - V12：穿越封堵（Q5 的守衛）

    /// 暫時文字在密碼欄查到 `.secure` 為什麼要**硬停**而不是只遮罩：只遮罩的話 session 繼續，
    /// 焦點回到 A 之後，那段在密碼欄說的話會以定稿形式寫進 A、送雲端 LLM、落進歷史。
    @Test func abortingOnAVolatileInAPasswordFieldLetsNothingLeakLater() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let polisher = GatedIntentService()
        let history = FakeHistory()
        let spy = ClipboardSpy()
        let (c, _, _) = makeStatefulController(env: env, polisher: polisher, clipboard: spy, history: history)
        let quality = TranscriptQuality(minAvgLogprob: -0.25, maxCompressionRatio: 1.125, segmentCount: 1)
        c.hotkeyPressed(at: 10.0)
        env.focus("P")
        c.handleTranscript(.volatile("1234"), at: 10.3)
        #expect(!c.ledger.isActive, "前提：在暫時文字階段就已硬停")

        env.focus("A")
        c.handleTranscript(.finalized("1234", quality: quality), at: 10.6)
        c.tick(at: 12.6)                                   // 若 session 還活著，這裡會閉合話語、送 LLM
        await c.lastIntentTask?.value

        #expect(env.text(in: "A") == "", "密碼欄期間說的話不得穿越到 A")
        #expect(polisher.calls.isEmpty, "不得送雲端 LLM")
        #expect(!history.exchanges.contains { $0.utteranceRaw.contains("1234") || ($0.outcomeText ?? "").contains("1234") })
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("1234") })
        #expect(spy.texts.isEmpty)
    }
}
