import Foundation
import Testing
@testable import SaymendCore

/// issue #70：焦點在兩個暫時文字之間「進入密碼欄 P、又離開 P」時，事件驅動的閘門完全看不到。
///
/// #65 之後有兩道密碼欄閘門，都是**事件驅動**的：暫時文字抵達時查一次、定稿抵達時查一次，查的都是
/// 「此刻」的焦點。焦點若在兩個事件之間進出 P，兩道閘門從頭到尾只看到 A——P 期間說的字會畫上 HUD、
/// 插進 A、送 LLM，或經凍結救援寫進剪貼簿與 `history_exchange`。
///
/// 修法：錄音中（`.listening`）掛一個焦點變更監看，焦點一移進密碼欄就當場硬停（與兩道既有閘門的
/// `.secure` 同一個 `abortForSecureField()`）。監看回報的是**變更當下那個元素**的判定，不是事後再查目前焦點。
///
/// `StatefulFieldEnvironment` 同時扮演監看者：`focus(_:)` 照 AX 的 focus-changed 通知，
/// 以新焦點欄位的判定同步通知仍在監看的 watch。這裡全部不包 HUDArbiter。
@Suite @MainActor struct FocusChangeWatchTests {

    private func volatiles(_ states: [HUDState]) -> [String] {
        states.compactMap {
            switch $0 {
            case .listening(_, let v), .selectionListening(_, let v): return v
            default: return nil
            }
        }
    }

    /// 歷史裡任何一格帶到 `needle` 的列（`history_exchange` 的兩個明文欄＋`asr_diagnostic`）
    private func leaks(_ history: FakeHistory, _ needle: String) -> Int {
        history.exchanges.filter { $0.utteranceRaw.contains(needle) || ($0.outcomeText ?? "").contains(needle) }.count
            + history.diagnostics.filter { $0.finalizedText.contains(needle) }.count
    }

    private let quality = TranscriptQuality(minAvgLogprob: -0.25, maxCompressionRatio: 1.125, segmentCount: 1)

    private func passwordFixture() -> StatefulFieldEnvironment {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true, bundleID: "com.foo.app")
        return env
    }

    // MARK: - F1／F2：issue 的失敗情境本身

    /// 驗收條件 1＋2：「進 P、說話、離開 P」且期間**沒有任何暫時文字**。
    /// 監看缺席時，焦點回到 A 之後才抵達的暫時文字與定稿，兩道閘門都只看得到 A——字會畫上 HUD、插進 A、
    /// 閉合後送 LLM、落進 `asr_diagnostic`。
    @Test func enteringAndLeavingAPasswordFieldBetweenEventsLetsNothingSpokenThereOut() async {
        let env = passwordFixture()
        let polisher = GatedIntentService()
        let history = FakeHistory()
        let spy = ClipboardSpy()
        let (c, asr, hud) = makeStatefulController(env: env, polisher: polisher, clipboard: spy,
                                                   history: history, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("我的密碼是"), at: 10.3)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "我的密碼是"), "前提：一般欄位照常預覽")

        env.focus("P")            // Tab／頁面 JS：不觸發使用者活動偵測，兩個事件之間沒有任何查詢點
        env.focus("A")
        // P 期間說的字，在焦點已回到 A 之後才從辨識器出來
        c.handleTranscript(.volatile("我的密碼是1234"), at: 11.0)
        c.handleTranscript(.finalized("我的密碼是1234", quality: quality), at: 11.2)
        c.tick(at: 13.0)          // 斷句器若沒被清空，靜音到期會閉合話語並送 LLM
        await c.lastIntentTask?.value

        #expect(!volatiles(hud.states).contains { $0.contains("1234") }, "HUD")
        #expect(env.text(in: "A") == "", "欄位 A")
        #expect(env.text(in: "P") == "", "欄位 P")
        #expect(polisher.calls.isEmpty, "LLM")
        #expect(spy.texts.isEmpty, "剪貼簿")
        #expect(leaks(history, "1234") == 0, "history_exchange／asr_diagnostic")
        #expect(!c.ledger.isActive, "與既有兩道閘門的 `.secure` 一致：硬停整個 session")
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(asr.cancelCount == 1, "走的是 abortForSecureField（停辨識）")
        #expect(env.watchStarts == 1 && env.watchStops == 1, "硬停的同時恰停一次監看")
        #expect(env.identityEntryCount == 0, "監看不得替任何元素留持有者（#43 lease）")
    }

    /// 同一個情境走**凍結終點**：使用者先在 A 點了一下（凍結），之後焦點才被搬進 P 又搬回來。
    /// 凍結終點跑在寫入前閘門**之前**，而定稿閘門此刻看到的是 A——監看缺席時，P 期間的字會被救進剪貼簿
    /// （clipboard manager 會留存），並以原文記進 `insertSkipped/frozen` 與 `asr_diagnostic`。
    @Test func aFrozenSessionDoesNotRescueWordsSpokenInsideThePasswordField() async {
        let env = passwordFixture()
        let history = FakeHistory()
        let spy = ClipboardSpy()
        let (c, _, _) = makeStatefulController(env: env, clipboard: spy, history: history, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.userActivityDetected(at: 10.2)                   // 在 A 點一下＝凍結（錄音照常）
        #expect(c.ledger.frozen, "前提：凍結")

        env.focus("P")
        env.focus("A")
        c.handleTranscript(.finalized("1234", quality: quality), at: 11.0)

        #expect(spy.texts.isEmpty, "剪貼簿")
        #expect(leaks(history, "1234") == 0, "history_exchange／asr_diagnostic")
        #expect(!c.ledger.isActive)
    }

    // MARK: - F3／F4：判定的三種結果

    /// `.secureUnknown`（AX 連兩次問不出新焦點的 subrole）：依 #59 fail closed，與定稿閘門的 `.secureUnknown` 相同——
    /// 硬停，並留一列**只有 metadata** 的診斷（`utteranceRaw` 為空）。
    /// 這裡不比照暫時文字閘門「只遮罩」：那條路的內容層 fail closed 交給事後的定稿閘門，
    /// 而 #70 的前提正是事後的閘門看不到這次焦點移動——監看是唯一一個看得到的點。
    /// 來源標成 `via:focusChange`，前綴與既有的 `secureUnknown：sessionApp:` 相同，誤殺樣本合得起來算、也拆得開。
    @Test func secureUnknownOnFocusChangeAbortsAndRecordsMetadataOnly() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("一"), at: 10.2)

        env.focus("U")

        #expect(!c.ledger.isActive)
        #expect(asr.cancelCount == 1)
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(history.exchanges.count == 1)
        #expect(history.exchanges.first?.outcomeKind == "insertSkipped")
        #expect(history.exchanges.first?.outcomeText == "secureUnknown：sessionApp:com.foo.app via:focusChange")
        #expect(history.exchanges.first?.utteranceRaw == "", "一個字都不得落進 history_exchange（#10）")
        #expect(history.diagnostics.isEmpty)
    }

    /// 焦點換到另一個一般欄位：監看不攔（`.different` 的攔阻在寫入前那道閘門），session 照常、監看照常。
    @Test func movingToAnotherOrdinaryFieldDoesNotStopTheSession() {
        let env = passwordFixture()
        env.addField("B", text: "", bundleID: "com.foo.app")
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)

        env.focus("B")
        c.handleTranscript(.volatile("你好"), at: 10.4)

        #expect(c.ledger.isActive)
        #expect(asr.cancelCount == 0)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "你好"))
        #expect(env.activeWatchCount == 1, "監看持續到錄音結束")
        #expect(history.exchanges.isEmpty, "一般欄位不記任何列")
    }

    // MARK: - F5～F8：生命週期（驗收條件 3：註冊／移除恰一次）

    /// 監看只綁錄音中：放開熱鍵（進排空窗）就停。排空窗不再收音，吐出來的定稿全是錄音期間說的；
    /// 排空窗內焦點才進出 P，不得作廢那些定稿——它們照常寫進 A。
    @Test func watchingStopsWhenRecordingStopsAndTheDrainStillLands() {
        let env = passwordFixture()
        let (c, asr, _) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        #expect(env.watchStarts == 1 && env.watchStops == 0, "進入錄音即開始監看")

        c.hotkeyReleased(at: 11.0)                         // hold 放開＝排空窗
        #expect(env.watchStarts == 1 && env.watchStops == 1, "停止收音即停止監看")

        env.focus("P")
        env.focus("A")
        c.handleTranscript(.finalized("你好"), at: 11.3)

        #expect(env.text(in: "A") == "你好", "排空中的定稿照常落地")
        #expect(asr.cancelCount == 0)
    }

    /// 延續窗內再按＝同 session 續聽：重新開始監看，Esc 結束時再停一次。全程 starts == stops、同時最多一個。
    @Test func resumingFromTheLingerWindowWatchesAgainAndEscStopsItOnce() {
        let env = passwordFixture()
        let (c, _, _) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.2)
        #expect(c.isLingering, "前提：延續窗")
        #expect(env.activeWatchCount == 0, "延續窗不收音、不監看")

        c.hotkeyPressed(at: 12.0)                          // 續聽
        #expect(env.watchStarts == 2 && env.activeWatchCount == 1)

        c.escapePressed()
        #expect(env.watchStarts == 2 && env.watchStops == 2)
        #expect(env.activeWatchCount == 0)
    }

    /// 每一條離開錄音的路徑都恰停一次：Esc、ASR 失敗、暫時文字閘門硬停、定稿閘門硬停、鎖定模式點按結束。
    @Test(arguments: ["esc", "asrFailed", "volatileGate", "finalizedGate", "lockedTap"])
    func everyWayOutOfRecordingStopsTheWatchExactlyOnce(_ path: String) {
        let env = passwordFixture()
        let (c, _, _) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        switch path {
        case "esc":
            c.escapePressed()
        case "asrFailed":
            c.handleTranscript(.failed(reason: "x"), at: 10.5)
        case "volatileGate":
            env.focus("P", notifyingWatches: false)        // 這次移動 AX 沒推通知：由暫時文字閘門抓
            c.handleTranscript(.volatile("1"), at: 10.5)
        case "finalizedGate":
            env.focus("P", notifyingWatches: false)
            c.handleTranscript(.finalized("1"), at: 10.5)
        case "lockedTap":
            c.hotkeyReleased(at: 10.1)                     // 點按＝鎖定
            c.hotkeyPressed(at: 11.0)
            c.hotkeyReleased(at: 11.1)                     // 再點按＝結束
        default:
            Issue.record("未知路徑 \(path)")
        }
        #expect(env.watchStarts == 1, "\(path)")
        #expect(env.watchStops == 1, "\(path)：恰停一次")
        #expect(env.activeWatchCount == 0, "\(path)")
    }

    /// 熱鍵按在密碼欄上（不開 session）：根本不開始監看，也就沒有東西要停。
    @Test func pressingInsideAPasswordFieldNeverStartsWatching() {
        let env = passwordFixture()
        env.focus("P")                                     // 尚無 watch，不通知任何人
        let (c, _, hud) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        #expect(hud.states.last == .notice("密碼欄位不聽寫"), "前提：拒絕開 session")
        #expect(env.watchStarts == 0 && env.watchStops == 0)
    }

    /// 已停止的監看送來的遲到通知，不得作用在**之後**的 session 上：controller 自己認得舊 watch，
    /// 不依賴 App 端「移除 observer 後就不會再送」。
    @Test func aLateNotificationFromAStoppedWatchDoesNotAbortTheNextSession() {
        let env = passwordFixture()
        let (c, asr, _) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                         // 第一段停止監看，進排空窗
        c.hotkeyPressed(at: 11.5)                          // 排空中按下＝立刻開新 session
        #expect(env.watchStarts == 2 && env.activeWatchCount == 1, "前提：新 session 有自己的監看")

        env.deliverToStoppedWatches(.secure)

        #expect(c.ledger.isActive, "舊 watch 的通知不算數")
        #expect(asr.cancelCount == 0)
    }

    /// 同一段錄音內也一樣：放開熱鍵後（排空窗）才到的舊通知不得作廢排空中的定稿。
    @Test func aLateNotificationAfterRecordingStoppedIsIgnored() {
        let env = passwordFixture()
        let (c, asr, _) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)

        env.deliverToStoppedWatches(.secure)
        c.handleTranscript(.finalized("你好"), at: 11.3)

        #expect(asr.cancelCount == 0)
        #expect(env.text(in: "A") == "你好")
    }
}
