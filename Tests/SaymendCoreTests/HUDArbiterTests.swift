import Foundation
import Testing
@testable import SaymendCore

/// issue #61：`HUDArbiter` 的狀態機本身（計畫 §3.3）。內層是 FakeHUD（arbiter 的輸出端），時間由
/// `FakeHUDScheduler` 的虛擬時鐘推進。一律用絕對時間（`advance(to: 1.9)` 再 `advance(to: 2.0)`），
/// 避免 1.999 + 0.001 這類浮點誤差。
@Suite struct HUDArbiterTests {
    private static let rescue = "欄位已切換，內容已入剪貼簿"
    private static let window = DiffWindow(ops: [.kept("舊"), .added("新")])

    private func make() -> (HUDArbiter, FakeHUD, FakeHUDScheduler) {
        let inner = FakeHUD()
        let scheduler = FakeHUDScheduler()
        return (HUDArbiter(inner: inner, scheduler: scheduler), inner, scheduler)
    }

    // MARK: - A1：沒有保護期＝原樣直通

    @Test func withoutAHoldEveryStatePassesThroughUnchanged() {
        let (a, inner, scheduler) = make()
        let states: [HUDState] = [.listening(mode: .hold, volatile: "a"), .notice("已修正"), .lingering,
                                  .diff([Self.window]), .hidden]
        for s in states { a.present(s) }
        #expect(inner.states == states, "保護期以外必須與沒包 arbiter 時逐位元相同")
        #expect(inner.rescueNotices.isEmpty, "一般 notice 不得被當成救援提示")
        #expect(scheduler.pendingCount == 0, "沒有救援提示就不排任何計時")
    }

    // MARK: - A2：#61 驗收時序（提示之後立刻來一個暫時文字）

    @Test func aVolatileRightAfterARescueNoticeWaitsForTheMinimumHold() {
        let (a, inner, scheduler) = make()
        a.present(.listening(mode: .hold, volatile: "今天"))
        a.presentRescueNotice(Self.rescue)
        a.present(.listening(mode: .hold, volatile: "今天天氣"))
        scheduler.advance(to: 1.9)
        #expect(inner.states == [.listening(mode: .hold, volatile: "今天"), .notice(Self.rescue)],
                "保護期內下游收不到任何非救援的 present")
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.listening(mode: .hold, volatile: "今天"), .notice(Self.rescue),
                                 .listening(mode: .hold, volatile: "今天天氣")])
    }

    // MARK: - A3：到期補送延後的持久狀態

    @Test func aDeferredPersistentStateIsReplayedWhenTheHoldEnds() {
        let (a, inner, scheduler) = make()
        a.present(.hidden)
        a.presentRescueNotice(Self.rescue)
        a.present(.lingering)
        scheduler.advance(to: 1.9)
        #expect(inner.states == [.hidden, .notice(Self.rescue)])
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.hidden, .notice(Self.rescue), .lingering])
    }

    // MARK: - A4：幽靈延續窗（雙延後槽）

    /// 延續窗中遲到的救援提示進入保護期，之後 session 被封存（`.hidden`）並發一則 notice。
    /// 只留單一槽、最後一個勝出的話只會重播 notice——window 的 persistentState 停在 `.lingering`，
    /// 2.5 秒後已封存的 session 會叫回「可修正／復原」。
    @Test func bothSlotsReplayInOrderSoAnArchivedSessionDoesNotComeBack() {
        let (a, inner, scheduler) = make()
        a.present(.lingering)
        a.presentRescueNotice(Self.rescue)
        a.present(.hidden)
        a.present(.notice("密碼欄位不聽寫"))
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.lingering, .notice(Self.rescue), .hidden, .notice("密碼欄位不聽寫")])
    }

    // MARK: - A5：後到的持久狀態清掉先到的暫態

    @Test func aLaterPersistentStateDropsAnEarlierDeferredTransient() {
        let (a, inner, scheduler) = make()
        a.presentRescueNotice(Self.rescue)
        a.present(.notice("已修正"))
        a.present(.listening(mode: .hold, volatile: "v"))
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.notice(Self.rescue), .listening(mode: .hold, volatile: "v")],
                "下游收到持久狀態時本來就會把較早的暫態蓋掉，重播它只會讓畫面閃一下")
    }

    // MARK: - A6：連續救援提示＝取代並重新計時（epoch）

    @Test func aSecondRescueNoticeReplacesTheFirstAndRestartsTheHold() {
        let (a, inner, scheduler) = make()
        a.presentRescueNotice("R1")
        scheduler.advance(to: 1.0)
        a.presentRescueNotice("R2")
        #expect(inner.states == [.notice("R1"), .notice("R2")], "第二則立即下送，不排隊")
        scheduler.advance(to: 1.5)
        a.present(.listening(mode: .hold, volatile: "v"))
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.notice("R1"), .notice("R2")],
                "R1 的計時到期時保護期屬於 R2：過期回呼必須被忽略")
        scheduler.advance(to: 2.9)
        #expect(inner.states == [.notice("R1"), .notice("R2")], "R2 同樣享有完整的 2 秒")
        scheduler.advance(to: 3.0)
        #expect(inner.states == [.notice("R1"), .notice("R2"), .listening(mode: .hold, volatile: "v")])
    }

    // MARK: - A7：新的救援提示作廢延後的暫態

    @Test func aRescueNoticeDropsADeferredTransient() {
        let (a, inner, scheduler) = make()
        a.presentRescueNotice("R1")
        a.present(.notice("已修正"))
        a.presentRescueNotice("R2")
        scheduler.advance(to: 3.0)
        #expect(inner.states == [.notice("R1"), .notice("R2")])
    }

    // MARK: - A15：取代時保留延後的持久狀態

    /// 保護期內 session 被封存（`.hidden`）之後又來一則救援提示——例如緩衝句的救援之後，
    /// `abandonSelectionReplacement` 先 archive 再發提示。取代只作廢延後的**暫態**；延後的 `.hidden`
    /// 若跟著被丟掉，window 的 persistentState 會停在封存前的 `.lingering`，2.5 秒後叫回已封存
    /// session 的「可修正／復原」（與 A4 同一個幽靈延續窗，從取代這條路回來）。
    @Test func aReplacingRescueNoticeKeepsTheDeferredPersistentState() {
        let (a, inner, scheduler) = make()
        a.present(.lingering)
        a.presentRescueNotice("R1")
        scheduler.advance(to: 0.5)
        a.present(.hidden)
        scheduler.advance(to: 1.0)
        a.presentRescueNotice("R2")
        #expect(inner.states == [.lingering, .notice("R1"), .notice("R2")], "前提：.hidden 被延後、R2 立即下送")
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.lingering, .notice("R1"), .notice("R2")], "R1 的過期回呼不得提前補送")
        scheduler.advance(to: 2.9)
        #expect(inner.states == [.lingering, .notice("R1"), .notice("R2")], "R2 享有完整的 2 秒")
        scheduler.advance(to: 3.0)
        #expect(inner.states == [.lingering, .notice("R1"), .notice("R2"), .hidden],
                "R2 的保護期結束時，被延後的 .hidden 必須補送")
    }

    // MARK: - A8：到期不捏造任何狀態

    @Test func anExpiredHoldWithNothingDeferredSendsNothing() {
        let (a, inner, scheduler) = make()
        a.presentRescueNotice(Self.rescue)
        scheduler.advance(to: 5.0)
        #expect(inner.states == [.notice(Self.rescue)],
                "沒有新狀態就讓 window 照今天的 2.5 秒自然收掉：不重送提示、不捏造 .hidden")
        #expect(scheduler.pendingCount == 0)
    }

    // MARK: - A9：diff 是暫態

    @Test func aDiffIsDeferredAsATransientAfterThePersistentState() {
        let (a, inner, scheduler) = make()
        a.presentRescueNotice(Self.rescue)
        a.present(.lingering)
        a.present(.diff([Self.window]))
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.notice(Self.rescue), .lingering, .diff([Self.window])])
    }

    // MARK: - A10：分類與 HUDWindowController 一致

    /// 逐項對齊 `HUDWindowController.present` 的兩組（持久：寫入 persistentState；暫態：自動隱藏）。
    @Test func persistentClassificationMatchesTheWindowController() {
        let persistent: [HUDState] = [.hidden, .listening(mode: .hold, volatile: "x"),
                                      .selectionListening(mode: .locked, volatile: "x"), .lingering,
                                      .transcribing, .loadingModel, .noSpeechDetected(mode: .hold)]
        let transient: [HUDState] = [.notice("x"), .diff([Self.window])]
        for s in persistent { #expect(HUDArbiter.isPersistent(s), "\(s) 應為持久類") }
        for s in transient { #expect(!HUDArbiter.isPersistent(s), "\(s) 應為暫態") }
    }

    // MARK: - A11：保護期短於 notice 壽命

    @Test func minimumHoldIsShorterThanTheNoticeLifetime() {
        #expect(HUDArbiter.minimumHold < HUDTiming.noticeLifetime,
                "否則 window 自己的 hideTask 會先把提示收掉，保證形同虛設")
    }

    // MARK: - A12：往下游轉送的是救援提示，不是一般 notice

    @Test func theRescueNoticeIsForwardedAsARescueNotice() {
        let (a, inner, _) = make()
        a.presentRescueNotice(Self.rescue)
        #expect(inner.rescueNotices == [Self.rescue])
        #expect(inner.states == [.notice(Self.rescue)])
    }

    // MARK: - A13／A14：requirement 與預設實作

    /// `presentRescueNotice` 必須是 protocol requirement：controller 持有的是 `any HUDPresenting`，
    /// 只寫在 extension 的話會靜態派發到預設實作（＝一般 notice），arbiter 的保護期永遠不會啟動。
    @Test func aRescueNoticeThroughTheExistentialReachesTheArbiter() {
        let (a, inner, scheduler) = make()
        let hud: any HUDPresenting = a
        hud.presentRescueNotice(Self.rescue)
        hud.present(.listening(mode: .hold, volatile: "v"))
        #expect(inner.states == [.notice(Self.rescue)])
        scheduler.advance(to: 2.0)
        #expect(inner.states == [.notice(Self.rescue), .listening(mode: .hold, volatile: "v")])
    }

    /// 沒有仲裁能力的實作（HUDWindowController、未包 arbiter 的路徑）：預設實作＝一般 notice，與今天逐位元相同。
    @Test func theDefaultImplementationIsAPlainNotice() {
        final class PlainHUD: HUDPresenting {
            var states: [HUDState] = []
            func present(_ state: HUDState) { states.append(state) }
        }
        let plain = PlainHUD()
        let hud: any HUDPresenting = plain
        hud.presentRescueNotice(Self.rescue)
        #expect(plain.states == [.notice(Self.rescue)])
    }
}
