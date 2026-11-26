import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

final class FakePeer: ControlPeer {
    private(set) var sent: [ControlMessage] = []
    private(set) var closeCount = 0
    func send(_ message: ControlMessage) { sent.append(message) }
    func close() { closeCount += 1 }
    var states: [(ControlState, ControlSource?)] {
        sent.compactMap { if case .state(let s, let src, _) = $0 { return (s, src) }; return nil }
    }
}

/// 手動排程：`activityChanged` 的合併點由測試決定何時跑
@MainActor
final class ManualScheduler {
    var pending: [@MainActor () -> Void] = []
    func run() {
        let blocks = pending
        pending = []
        for b in blocks { b() }
    }
}

@MainActor
struct ServiceHarness {
    let service: ControlService
    let cli: CLIHarness
    let scheduler: ManualScheduler
    let hotkey: HotkeyStub
}

@MainActor
final class HotkeyStub {
    var activity: DictationActivity = .idle
}

@MainActor
func makeService(modelReady: Bool = true) -> ServiceHarness {
    let hotkey = HotkeyStub()
    let cli = makeCLI()
    let scheduler = ManualScheduler()
    let service = ControlService(cli: cli.c,
                                 hotkeyActivity: { hotkey.activity },
                                 modelReady: { modelReady },
                                 appVersion: "0.1.0",
                                 now: { Date(timeIntervalSince1970: 0) },
                                 schedule: { scheduler.pending.append($0) })
    cli.c.onPhaseChange = { [weak service] in service?.activityChanged() }
    return ServiceHarness(service: service, cli: cli, scheduler: scheduler, hotkey: hotkey)
}

@MainActor
@Suite struct ControlServiceTests {
    @Test func statusReportsStateSourceAndModelReadinessThenCloses() async {
        let h = makeService(modelReady: false)
        h.hotkey.activity = .recording
        let peer = FakePeer()
        h.service.handle(.status, peer: peer)
        let deadline = Date().addingTimeInterval(3)
        while peer.closeCount == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(peer.sent == [.status(state: .recording, source: .hotkey, modelReady: false)])
        #expect(peer.closeCount == 1)
    }

    @Test func cliDictationTakesPrecedenceInTheSnapshot() {
        let h = makeService()
        #expect(h.service.snapshot() == .init(state: .idle, source: nil))
        h.hotkey.activity = .polishing
        #expect(h.service.snapshot() == .init(state: .polishing, source: .hotkey))
        h.hotkey.activity = .idle
        h.cli.start()
        #expect(h.service.snapshot() == .init(state: .recording, source: .cli))
        h.cli.c.stop()
        #expect(h.service.snapshot() == .init(state: .transcribing, source: .cli))
    }

    @Test func versionRepliesAndCloses() {
        let h = makeService()
        let peer = FakePeer()
        h.service.handle(.version, peer: peer)
        #expect(peer.sent == [.version(app: "0.1.0")])
        #expect(peer.closeCount == 1)
    }

    @Test func dictateForwardsEventsAndClosesOnTheResult() {
        let h = makeService()
        let peer = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: peer)
        h.cli.c.receive(.volatile("你好"), session: 1)
        h.cli.c.receive(.finalized("你好"), session: 1)
        let stopper = FakePeer()
        h.service.handle(.stop, peer: stopper)
        #expect(stopper.sent == [.ok])
        h.cli.c.streamEnded(session: 1)
        #expect(peer.sent == [.started, .partial("你好"), .final(text: "〈你好〉", raw: "你好", durationMs: 0)])
        #expect(peer.closeCount == 1)
    }

    @Test func stopAndCancelWithNothingToActOnAreExit4() {
        let h = makeService()
        for request in [ControlRequest.stop, .cancel] {
            let peer = FakePeer()
            h.service.handle(request, peer: peer)
            #expect(peer.sent.count == 1)
            guard case .error(let code, _)? = peer.sent.first else { Issue.record("\(request)"); continue }
            #expect(code == .nothingToStop)
            #expect(code.exitCode == 4)
            #expect(peer.closeCount == 1)
        }
    }

    @Test func cancelFromAnotherProcessEndsTheWaitingDictateWithCancelled() {
        let h = makeService()
        let waiting = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: waiting)
        let canceller = FakePeer()
        h.service.handle(.cancel, peer: canceller)
        #expect(canceller.sent == [.ok])
        #expect(waiting.sent.last == .error(code: .cancelled, message: "已取消"))
        #expect(waiting.closeCount == 1)
        #expect(h.cli.audio.stopCount == 1)
    }

    /// CLI 被 kill：連線斷了，app 必須自己取消，麥克風絕不能還開著
    @Test func disconnectOfTheWaitingCLICancelsAndClosesTheMic() {
        let h = makeService()
        let waiting = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: waiting)
        #expect(h.cli.c.phase == .recording)
        h.service.peerClosed(waiting)
        #expect(h.cli.c.phase == .idle)
        #expect(h.cli.audio.stopCount == 1)
        #expect(h.cli.asr.cancelCount == 1)
    }

    @Test func disconnectWhileTranscribingAlsoCancels() {
        let h = makeService()
        let waiting = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: waiting)
        h.cli.c.stop()
        h.service.peerClosed(waiting)
        #expect(h.cli.c.phase == .idle)
        #expect(h.cli.asr.cancelCount == 1)
    }

    /// 第二個 dictate 被拒時不得把「斷線就取消」的認領搶走：第一個斷線仍要取消
    @Test func busyDictateDoesNotStealOwnership() {
        let h = makeService()
        let first = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: first)
        let second = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: second)
        #expect(second.sent == [.error(code: .busy, message: "已有一段 CLI 聽寫進行中")])
        #expect(second.closeCount == 1)
        h.service.peerClosed(second)
        #expect(h.cli.c.phase == .recording, "被拒的那條斷線不影響進行中的那段")
        h.service.peerClosed(first)
        #expect(h.cli.c.phase == .idle)
    }

    @Test func hotkeyBusyRejectsDictate() {
        let peer = FakePeer()
        // 熱鍵閘門在 makeCLI 裡預設放行；這裡改用不放行的 CLI
        let blocked = makeCLI(gate: false)
        let service = ControlService(cli: blocked.c, hotkeyActivity: { .recording }, modelReady: { true },
                                     appVersion: "x")
        service.handle(.dictate(DictateOptions()), peer: peer)
        #expect(peer.sent == [.error(code: .busy, message: "熱鍵聽寫進行中")])
        #expect(peer.closeCount == 1)
        #expect(blocked.audio.startCount == 0)
    }

    @Test func signalCancelOnlyCountsOnTheDictateConnection() {
        let h = makeService()
        let waiting = FakePeer()
        h.service.handle(.dictate(DictateOptions()), peer: waiting)
        h.service.handleFollowUp(.cancel, peer: FakePeer())
        #expect(h.cli.c.phase == .recording, "別條連線的後續行不算數")
        h.service.handleFollowUp(.stop, peer: waiting)
        #expect(h.cli.c.phase == .recording, "後續行只認 cancel")
        h.service.handleFollowUp(.cancel, peer: waiting)
        #expect(h.cli.c.phase == .idle)
        #expect(waiting.sent.last == .error(code: .cancelled, message: "已取消"))
    }

    // MARK: - events

    @Test func eventsSendASnapshotFirstThenOnlyRealChanges() {
        let h = makeService()
        let sub = FakePeer()
        h.service.handle(.events, peer: sub)
        #expect(sub.states.map(\.0) == [.idle])
        #expect(sub.closeCount == 0, "長駐串流不關")

        h.hotkey.activity = .recording
        h.service.activityChanged()
        h.service.activityChanged()                       // 同一個 turn 連續通知：合併成一次
        #expect(h.scheduler.pending.count == 1)
        h.scheduler.run()
        h.service.activityChanged()                       // 值沒變：不送
        h.scheduler.run()
        h.hotkey.activity = .transcribing
        h.service.activityChanged()
        h.scheduler.run()
        #expect(sub.states.map(\.0) == [.idle, .recording, .transcribing])
        #expect(sub.states.map(\.1) == [nil, .hotkey, .hotkey])
    }

    /// 同一個 turn 裡一閃而過的狀態（錄音 → 取消 → 閒置）不送出
    @Test func transientStatesWithinOneTurnAreNotBroadcast() {
        let h = makeService()
        let sub = FakePeer()
        h.service.handle(.events, peer: sub)
        h.hotkey.activity = .recording
        h.service.activityChanged()
        h.hotkey.activity = .idle
        h.scheduler.run()
        #expect(sub.states.map(\.0) == [.idle])
    }

    @Test func cliDictationShowsUpInEventsWithCLISource() {
        let h = makeService()
        let sub = FakePeer()
        h.service.handle(.events, peer: sub)
        h.service.handle(.dictate(DictateOptions()), peer: FakePeer())
        h.scheduler.run()
        h.cli.c.stop()
        h.scheduler.run()
        h.cli.c.receive(.finalized("x"), session: 1)
        h.cli.c.streamEnded(session: 1)
        h.scheduler.run()
        #expect(sub.states.map(\.0) == [.idle, .recording, .transcribing, .idle])
        #expect(sub.states.map(\.1) == [nil, .cli, .cli, nil])
    }

    @Test func closedSubscribersStopReceiving() {
        let h = makeService()
        let sub = FakePeer()
        h.service.handle(.events, peer: sub)
        #expect(h.service.subscriberCount == 1)
        h.service.peerClosed(sub)
        #expect(h.service.subscriberCount == 0)
        h.hotkey.activity = .recording
        h.service.activityChanged()
        h.scheduler.run()
        #expect(sub.sent.count == 1)
    }
}

/// 熱鍵聽寫一側只多了兩個掛點：`activity`／`onActivityChange` 與 `yieldForExternalCapture`。
@MainActor
@Suite struct DictationControllerExternalCaptureTests {
    @Test func activityFollowsThePhases() async {
        let polisher = GatedIntentService()
        polisher.gated = true
        let (c, _, _, _, _, _) = makeController(polisher: polisher)
        var changes = 0
        c.onActivityChange = { changes += 1 }
        #expect(c.activity == .idle)
        c.hotkeyPressed(at: 10)
        #expect(c.activity == .recording)
        #expect(changes > 0)
        c.handleTranscript(.finalized("你好"), at: 10.5)
        c.hotkeyReleased(at: 11)                      // 長按放開 → 排空
        #expect(c.activity == .transcribing)
        c.asrStreamEnded(at: 11.1)                    // 排空結束 → 延續窗，潤飾在途
        #expect(c.isLingering)
        #expect(c.activity == .polishing)
        polisher.release()
        await c.lastIntentTask?.value
        #expect(c.activity == .idle, "延續窗對外算閒置")
    }

    @Test func yieldRefusesWhileTheHotkeyUsesTheMicOrRecognizer() async {
        let polisher = GatedIntentService()
        polisher.gated = true
        let (c, audio, _, _, _, _) = makeController(polisher: polisher)
        #expect(c.yieldForExternalCapture(), "閒置：放行")
        c.hotkeyPressed(at: 10)
        #expect(!c.yieldForExternalCapture(), "錄音中")
        c.handleTranscript(.finalized("你好"), at: 10.5)
        c.hotkeyReleased(at: 11)
        #expect(!c.yieldForExternalCapture(), "排空中")
        c.asrStreamEnded(at: 11.1)
        #expect(!c.yieldForExternalCapture(), "潤飾在途")
        #expect(c.isLingering, "拒絕時不得封存延續窗")
        polisher.release()
        await c.lastIntentTask?.value
        #expect(c.yieldForExternalCapture(), "延續窗、沒有在途潤飾：放行")
        #expect(!c.isLingering, "並封存延續窗（同使用者活動）")
        #expect(!c.isEngaged)
        #expect(audio.startCount == 1, "讓出不會碰麥克風")
    }
}
