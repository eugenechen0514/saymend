import Foundation
import Testing
@testable import SaymendCore

/// issue #61：controller ＋ `HUDArbiter` ＋ FakeHUD 的端到端時序。FakeHUD 是 arbiter 的**輸出端**，
/// 也就是 window 實際會收到的序列；時間由 `FakeHUDScheduler` 的虛擬時鐘推進（與 controller 的 `t` 無關）。
///
/// 每條都先用前提斷言證明救援出口真的走過（剪貼簿 spy、欄位內容、`isLingering`），
/// 再看提示在保護期內是否留在畫面上——避免「被殺掉卻沒走到那條路」的假陽性。
@Suite @MainActor struct RescueNoticeDwellTests {

    private func arbitrated(_ scheduler: FakeHUDScheduler) -> (FakeHUD) -> any HUDPresenting {
        { HUDArbiter(inner: $0, scheduler: scheduler) }
    }

    // MARK: - C1：issue 驗收「notice 發出後立刻來一個 .volatile」

    @Test func aVolatileRightAfterTheFieldChangedNoticeWaitsForTheMinimumHold() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let spy = ClipboardSpy()
        let scheduler = FakeHUDScheduler()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy, wrapHUD: arbitrated(scheduler))
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")                                     // Tab／頁面 JS：不凍結、session 繼續
        c.handleTranscript(.finalized("第二句"), at: 11.0)  // 寫入前閘門 → fieldChanged → 救援
        c.handleTranscript(.volatile("第三"), at: 11.2)     // 數百毫秒內就到的下一個暫時文字

        #expect(spy.texts == ["第二句"], "前提：走的是 fieldChanged 救援出口")
        #expect(env.text(in: "B") == "", "前提：B 一個字都沒進")
        #expect(c.ledger.isActive, "前提：session 繼續（裁定 Q2），下一個暫時文字才會來")
        scheduler.advance(to: 1.9)
        #expect(hud.states.last == .notice(DictationController.fieldChangedNotice), "保護期內提示留在畫面上")
        scheduler.advance(to: 2.0)
        #expect(hud.states.last == .listening(mode: .hold, volatile: "第三"), "到期後預覽恢復成最新文字")
    }

    // MARK: - C2：hold 流程、批次形狀（救援之後緊接 .lingering）

    @Test func theInsertFailureNoticeIsNotCoveredByTheLingeringThatFollows() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "PREVIOUS", bundleID: "com.foo.app")
        env.failInsertsRemaining = 2                       // keystroke 與 paste 都失敗 → catch 出口
        let spy = ClipboardSpy()
        let scheduler = FakeHUDScheduler()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy, wrapHUD: arbitrated(scheduler))
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                         // 非 tap → 排空（.hidden，保護期外直通）
        c.handleTranscript(.finalized("整句"), at: 11.1)
        c.asrStreamEnded(at: 11.2)                         // 相鄰的 MainActor turn 立刻送 .lingering

        #expect(spy.texts == ["整句"], "前提：走的是插入失敗救援出口")
        #expect(env.text(in: "A") == "PREVIOUS")
        #expect(c.isLingering, "前提：進了延續窗（controller 確實送了 .lingering）")
        scheduler.advance(to: 1.9)
        #expect(hud.states.last == .notice("插入失敗，內容已入剪貼簿"))
        #expect(!hud.states.contains(.lingering), "保護期內 .lingering 不得蓋掉提示")
        scheduler.advance(to: 2.0)
        #expect(hud.states.last == .lingering)
    }

    // MARK: - C3：凍結救援之後緊接封存的 .hidden

    @Test func theFrozenRescueNoticeIsNotHiddenByTheArchiveThatFollows() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let spy = ClipboardSpy()
        let scheduler = FakeHUDScheduler()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy, wrapHUD: arbitrated(scheduler))
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 10.5)                         // 非 tap → 排空（Whisper 遠端的上傳窗）
        c.userActivityDetected(at: 11.0)                   // 上傳中點別處 → 凍結
        c.handleTranscript(.finalized("x"), at: 11.5)      // 遲到的批次結果 → 凍結救援
        c.asrStreamEnded(at: 11.6)                         // 凍結 → 封存 → .hidden

        #expect(spy.texts == ["x"], "前提：走的是凍結救援出口")
        #expect(!c.ledger.isActive, "前提：已封存（controller 確實送了 .hidden）")
        scheduler.advance(to: 1.9)
        #expect(hud.states.last == .notice("已凍結，內容已入剪貼簿"), "保護期內不得被 .hidden 收掉")
        scheduler.advance(to: 2.0)
        #expect(hud.states.last == .hidden)
    }

    // MARK: - C4：#61 × #65（保護期中切進密碼欄）

    /// 唯一接點：遮罩／硬停發生在 arbiter **上游**，arbiter 的延後槽永遠存不到密碼文字。
    /// 注意保護期會掩蓋「閘門查詢位置後移」這個 mutation（被延後的字最後被 .hidden 取代），
    /// 那個 mutation 的真正守衛是 `VolatileSecureFieldTests` 的 V1。
    @Test func aPasswordFieldDuringTheHoldNeverReachesTheWindowAndAbortsInOrder() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let spy = ClipboardSpy()
        let scheduler = FakeHUDScheduler()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy, wrapHUD: arbitrated(scheduler))
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)
        c.handleTranscript(.volatile("第三"), at: 11.2)
        #expect(spy.texts == ["第二句"], "前提：已進保護期")

        env.focus("P")
        c.handleTranscript(.volatile("密碼1234"), at: 11.4)
        #expect(!c.ledger.isActive, "前提：暫時文字閘門已硬停")
        scheduler.advance(to: 2.0)

        let shown: [String] = hud.states.compactMap {
            switch $0 {
            case .listening(_, let v), .selectionListening(_, let v): return v
            default: return nil
            }
        }
        #expect(!shown.contains { $0.contains("1234") }, "密碼欄的字不得出現在 window 收到的任何狀態裡")
        #expect(Array(hud.states.suffix(2)) == [.hidden, .notice("密碼欄位不聽寫")],
                "硬停的 .hidden 與提示在保護期結束時依序重播")
    }
}
