import AVFoundation
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

/// 可手動推進的單調時鐘
@MainActor
final class ManualClock {
    var now: TimeInterval = 100
}

/// CLI 聽寫收到的事件（依序）
@MainActor
final class CLIEventLog {
    var events: [CLIDictationController.Event] = []
    var terminal: CLIDictationController.Event? {
        events.last.flatMap { e in
            switch e {
            case .finished, .failed: return e
            case .started, .partial: return nil
            }
        }
    }
    var partials: [String] {
        events.compactMap { if case .partial(let t) = $0 { return t }; return nil }
    }
}

@MainActor
struct CLIHarness {
    let c: CLIDictationController
    let audio: FakeAudio
    let asr: FakeASR
    let hud: FakeHUD
    let history: FakeHistory
    let clock: ManualClock
    let log: CLIEventLog
    let settings: AppSettings
    var gateCalls: () -> Int

    func start(_ options: DictateOptions = DictateOptions()) {
        c.start(options) { [log] e in log.events.append(e) }
    }

    /// 起手先餵 0.5 秒環境音（底線就位），再講 `seconds` 秒
    func speak(seconds: Double = 1) {
        for _ in 0..<5 { clock.now += 0.1; c.ingestLevel(0.01, session: 1) }
        for _ in 0..<Int(seconds * 10) { clock.now += 0.1; c.ingestLevel(0.5, session: 1) }
    }

    func silence(seconds: Double, session: Int = 1) {
        for _ in 0..<Int(seconds * 10) { clock.now += 0.1; c.ingestLevel(0.01, session: session) }
    }
}

@MainActor
func makeCLI(gate: Bool = true,
             mic: CLIDictationController.MicrophoneAccess = .granted,
             polish: ((String) async -> IntentOutcome)? = nil,
             historyEnabled: Bool = true) -> CLIHarness {
    let audio = FakeAudio()
    let asr = FakeASR()
    let hud = FakeHUD()
    let history = FakeHistory()
    let clock = ManualClock()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                               secrets: InMemorySecretStore())
    settings.historyEnabled = historyEnabled
    var gateCount = 0
    let c = CLIDictationController(
        audio: audio, asr: asr, hud: hud, settings: settings, history: history,
        postProcess: { { "〈\($0)〉" } },          // 看得出有沒有經過後處理
        polish: polish,
        microphoneAccess: { mic },
        hotkeyGate: { gateCount += 1; return gate },
        drainTimeout: { 30 },
        clock: { clock.now },
        now: { Date(timeIntervalSince1970: 0) })
    return CLIHarness(c: c, audio: audio, asr: asr, hud: hud, history: history, clock: clock,
                      log: CLIEventLog(), settings: settings, gateCalls: { gateCount })
}

@MainActor
@Suite struct CLIDictationControllerTests {
    // MARK: - 開始

    @Test func startOpensMicAndShowsHUD() {
        let h = makeCLI()
        h.start()
        #expect(h.log.events == [.started])
        #expect(h.c.phase == .recording)
        #expect(h.audio.startCount == 1)
        #expect(h.asr.startCount == 1)
        #expect(h.hud.states.last == .cliListening(volatile: "", loadingModel: false), "錄音必須看得見")
    }

    @Test func historySessionIsMarkedCLIAndOnlyCreatedWhenThereIsSomethingToRecord() {
        let h = makeCLI()
        h.start()
        #expect(h.history.sessions.isEmpty, "還沒有內容：不開空白 session")
        h.c.receive(.finalized("內容"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.history.sessions.count == 1)
        #expect(h.history.sessions.first?.targetKind == "cli")
        #expect(h.history.sessions.first?.appName == CLIDictationController.historyAppName)
        #expect(h.history.sessions.first?.startedAt == Date(timeIntervalSince1970: 0))
        #expect(h.history.finished.map(\.finalText) == ["〈內容〉"])

        // 免手動迴圈：沒人說話就放棄的聽寫一筆都不留
        let idle = makeCLI()
        for sid in 1...3 {
            idle.start(DictateOptions(noSpeechSeconds: 1))
            idle.silence(seconds: 1.2, session: sid)
        }
        #expect(idle.log.events.filter { $0 == .failed(.noSpeech) }.count == 3)
        #expect(idle.history.sessions.isEmpty)
        #expect(idle.history.finished.isEmpty)
    }

    @Test func busyWhenHotkeyDictationHoldsTheMicrophone() {
        let h = makeCLI(gate: false)
        h.start()
        #expect(h.log.events == [.failed(.busy("熱鍵聽寫進行中"))])
        #expect(h.audio.startCount == 0, "不得開麥")
        #expect(h.c.phase == .idle)
        #expect(h.history.sessions.isEmpty)
    }

    @Test func busyWhenAnotherCLIDictationIsActiveDoesNotDisturbIt() {
        let h = makeCLI()
        h.start()
        var second: [CLIDictationController.Event] = []
        h.c.start(DictateOptions()) { second.append($0) }
        #expect(second == [.failed(.busy("已有一段 CLI 聽寫進行中"))])
        #expect(h.c.phase == .recording, "第一段照常")
        #expect(h.audio.startCount == 1)
        #expect(h.gateCalls() == 1, "忙碌時連熱鍵閘門都不問（不得因此封存熱鍵的延續窗）")
    }

    @Test func permissionProblemsFailBeforeOpeningTheMic() {
        for access in [CLIDictationController.MicrophoneAccess.denied, .undetermined] {
            let h = makeCLI(mic: access)
            h.start()
            guard case .failed(let f)? = h.log.events.first, f.code == .permissionDenied else {
                Issue.record("\(access) 應回 permissionDenied，實得 \(h.log.events)"); continue
            }
            #expect(f.code.exitCode == 8)
            #expect(h.audio.startCount == 0)
        }
    }

    @Test func microphoneStartFailureIsReported() {
        let h = makeCLI()
        h.audio.failNextStart = true
        h.start()
        guard case .failed(.microphoneUnavailable)? = h.log.events.first else {
            Issue.record("實得 \(h.log.events)"); return
        }
        #expect(h.c.phase == .idle)
        #expect(h.asr.startCount == 0)
    }

    // MARK: - 定稿

    @Test func stopFinalizesWithRawAndPostProcessedTextAndNeverInserts() {
        let h = makeCLI()
        h.start()
        h.clock.now += 2
        h.c.receive(.finalized("你好"), session: 1)
        h.c.receive(.finalized("世界"), session: 1)
        #expect(h.c.stop())
        #expect(h.audio.stopCount == 1)
        #expect(h.c.phase == .transcribing)
        #expect(h.hud.states.last == .transcribing)
        h.clock.now += 5                                   // 排空時間不算進 durationMs
        h.c.streamEnded(session: 1)
        #expect(h.log.terminal == .finished(.init(text: "〈你好世界〉", raw: "你好世界", durationMs: 2000)))
        #expect(h.c.phase == .idle)
        #expect(h.hud.states.last == .hidden)
        #expect(h.history.exchanges.map(\.outcomeKind) == ["cliRaw"])
        #expect(h.history.exchanges.first?.utteranceRaw == "你好世界")
        #expect(h.history.finished.first?.finalText == "〈你好世界〉")
    }

    @Test func partialsCarryTheWholeTextSoFarAndAreDeduplicated() {
        let h = makeCLI()
        h.start()
        h.c.receive(.volatile("你"), session: 1)
        h.c.receive(.volatile("你好"), session: 1)
        h.c.receive(.volatile("你好"), session: 1)            // 相同：不重送
        h.c.receive(.finalized("你好。"), session: 1)
        h.c.receive(.volatile("再"), session: 1)
        #expect(h.log.partials == ["你", "你好", "你好。", "你好。再"])
        #expect(h.hud.states.last == .cliListening(volatile: "你好。再", loadingModel: false))
    }

    @Test func silenceAfterSpeechEndsTheRecordingAutomatically() {
        let h = makeCLI()
        h.start(DictateOptions(silenceMs: 1000))
        h.speak(seconds: 1)
        #expect(h.c.phase == .recording)
        h.silence(seconds: 0.9)
        #expect(h.c.phase == .recording)
        h.silence(seconds: 0.3)
        #expect(h.c.phase == .transcribing, "靜音滿 1 秒自動結束錄音")
        #expect(h.audio.stopCount == 1)
        #expect(h.asr.cancelCount == 0, "是正常定稿，不是取消——辨識器要排空")
    }

    @Test func maxSecondsEndsTheRecordingOnTickEvenWithoutAudio() {
        let h = makeCLI()
        h.start(DictateOptions(maxSeconds: 10))
        h.clock.now += 9.9
        h.c.tick()
        #expect(h.c.phase == .recording)
        h.clock.now += 0.1
        h.c.tick()
        #expect(h.c.phase == .transcribing)
        h.c.receive(.finalized("內容"), session: 1)
        h.c.streamEnded(session: 1)
        #expect(h.log.terminal == .finished(.init(text: "〈內容〉", raw: "內容", durationMs: 10_000)))
    }

    @Test func noSpeechSecondsGivesUpAndDiscards() {
        let h = makeCLI()
        h.start(DictateOptions(noSpeechSeconds: 3))
        h.silence(seconds: 3.1)
        #expect(h.log.terminal == .failed(.noSpeech))
        #expect(h.audio.stopCount == 1)
        #expect(h.asr.cancelCount == 1, "放棄：辨識器不排空")
        #expect(h.c.phase == .idle)
        #expect(h.hud.states.last == .hidden)
    }

    @Test func emptyResultIsExit6EvenAfterSpeech() {
        let h = makeCLI()
        h.start()
        h.speak()
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.log.terminal == .failed(.emptyResult))
        let silent = makeCLI()
        silent.start()
        silent.c.stop()
        silent.c.streamEnded(session: 1)
        #expect(silent.log.terminal == .failed(.noSpeech))
        #expect(CLIDictationController.Failure.emptyResult.code.exitCode == 6)
        #expect(CLIDictationController.Failure.noSpeech.code.exitCode == 6)
    }

    @Test func captionHallucinationsAreNotPartOfTheResult() {
        let h = makeCLI()
        h.start()
        h.c.receive(.captionHallucination("(字幕製作:貝爾)", quality: nil), session: 1)
        h.c.receive(.finalized("真的話"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.log.terminal == .finished(.init(text: "〈真的話〉", raw: "真的話", durationMs: 0)))
        #expect(h.history.exchanges.map(\.outcomeKind) == ["insertSkipped", "cliRaw"])
    }

    @Test func streamEndingWhileRecordingClosesTheMicAndFinalizes() {
        let h = makeCLI()
        h.start()
        h.c.receive(.finalized("斷線前"), session: 1)
        h.c.streamEnded(session: 1)
        #expect(h.audio.stopCount == 1, "麥克風一定要關")
        #expect(h.log.terminal == .finished(.init(text: "〈斷線前〉", raw: "斷線前", durationMs: 0)))
    }

    // MARK: - 取消與失敗

    @Test func cancelWhileRecordingStopsEverythingAndDiscards() {
        let h = makeCLI()
        h.start()
        h.c.receive(.finalized("不要了"), session: 1)
        #expect(h.c.cancel())
        #expect(h.audio.stopCount == 1)
        #expect(h.asr.cancelCount == 1)
        #expect(h.log.terminal == .failed(.cancelled))
        #expect(h.c.phase == .idle)
        #expect(!h.c.isActive)
        #expect(h.history.exchanges.map(\.outcomeKind) == ["outcomeDropped"])
        #expect(h.history.finished.first?.finalText == nil)
        // 取消之後遲到的事件一律忽略
        let countAfterCancel = h.log.events.count
        h.c.receive(.finalized("遲到"), session: 1)
        h.c.streamEnded(session: 1)
        #expect(h.log.events.count == countAfterCancel)
    }

    @Test func cancelWhileTranscribingDropsTheDrain() {
        let h = makeCLI()
        h.start()
        h.c.stop()
        #expect(h.c.cancel())
        #expect(h.asr.cancelCount == 1)
        #expect(h.audio.stopCount == 1, "錄音結束時已經關過，取消不再重複關")
        #expect(h.log.terminal == .failed(.cancelled))
    }

    @Test func stopAndCancelReportWhetherThereWasAnythingToAct() {
        let h = makeCLI()
        #expect(!h.c.stop())
        #expect(!h.c.cancel())
        h.start()
        h.c.stop()
        #expect(!h.c.stop(), "已經在辨識中：沒有錄音可停")
        #expect(h.c.cancel(), "辨識中仍可取消")
    }

    @Test func failureWhileWaitingForTheModelIsModelNotReady() {
        let h = makeCLI()
        h.start()
        h.c.receive(.loadingModel, session: 1)
        #expect(h.hud.states.last == .cliListening(volatile: "", loadingModel: true), "載入中錄音照常、照樣看得見")
        h.c.receive(.failed(reason: "模型載入失敗"), session: 1)
        #expect(h.log.terminal == .failed(.modelNotReady("模型載入失敗")))
        #expect(h.audio.stopCount == 1)
        #expect(CLIDictationController.Failure.modelNotReady("").code.exitCode == 7)

        let noModel = makeCLI()
        noModel.start()
        noModel.c.receive(.failed(reason: WhisperKitEngine.noModelSelectedReason), session: 1)
        #expect(noModel.log.terminal == .failed(.modelNotReady(WhisperKitEngine.noModelSelectedReason)))

        let plain = makeCLI()
        plain.start()
        plain.c.receive(.loadingModel, session: 1)
        plain.c.receive(.transcribing, session: 1)            // 模型好了
        plain.c.receive(.failed(reason: "HTTP 500"), session: 1)
        #expect(plain.log.terminal == .failed(.asrFailed("HTTP 500")))
    }

    @Test func drainTimeoutGivesUpWithExit7() {
        let h = makeCLI()
        h.start()
        h.c.stop()
        h.clock.now += 29.9
        h.c.tick()
        #expect(h.c.phase == .transcribing)
        h.clock.now += 0.1
        h.c.tick()
        #expect(h.log.terminal == .failed(.timedOut))
        #expect(h.asr.cancelCount == 1)
        #expect(CLIDictationController.Failure.timedOut.code.exitCode == 7)
    }

    // MARK: - 熱鍵

    @Test func hotkeyWhileRecordingFinalizesAndWhileProcessingOnlyNotifies() {
        let h = makeCLI()
        h.start()
        h.c.hotkeyPressed()
        #expect(h.c.phase == .transcribing)
        #expect(h.asr.cancelCount == 0)
        h.c.hotkeyPressed()
        #expect(h.c.phase == .transcribing)
        if case .notice? = h.hud.states.last {} else { Issue.record("處理中按熱鍵要提示，實得 \(String(describing: h.hud.states.last))") }
    }

    // MARK: - 潤飾

    @Test func polishUsesTheProviderAndPostProcessesItsOutput() async {
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("潤飾後")
        let h = makeCLI(polish: { await polisher.process(utteranceRaw: $0, context: IntentContext()) })
        h.start(DictateOptions(polish: true))
        h.c.receive(.finalized("原文"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.c.phase == .polishing)
        #expect(await waitForTerminal(h.log))
        #expect(h.log.terminal == .finished(.init(text: "〈潤飾後〉", raw: "原文", durationMs: 0)))
        #expect(polisher.calls.map(\.raw) == ["原文"], "送去潤飾的是辨識原文")
        #expect(h.history.exchanges.map(\.outcomeKind) == ["newContent"])
    }

    @Test func degradedPolishFallsBackToTheLocalResult() async {
        let polisher = GatedIntentService()
        polisher.outcome = .degraded(reason: "逾時")
        let h = makeCLI(polish: { await polisher.process(utteranceRaw: $0, context: IntentContext()) })
        h.start(DictateOptions(polish: true))
        h.c.receive(.finalized("原文"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(await waitForTerminal(h.log))
        #expect(h.log.terminal == .finished(.init(text: "〈原文〉", raw: "原文", durationMs: 0)),
                "使用者不能白說話：降級＝本機後處理過的原文")
    }

    @Test func withoutPolishFlagTheProviderIsNeverCalled() {
        let polisher = GatedIntentService()
        let h = makeCLI(polish: { await polisher.process(utteranceRaw: $0, context: IntentContext()) })
        h.start()
        h.c.receive(.finalized("原文"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.log.terminal == .finished(.init(text: "〈原文〉", raw: "原文", durationMs: 0)))
        #expect(polisher.calls.isEmpty, "預設全本地：不上雲")
    }

    @Test func cancelDuringPolishDropsTheLateOutcome() async {
        let polisher = GatedIntentService()
        polisher.gated = true
        let h = makeCLI(polish: { await polisher.process(utteranceRaw: $0, context: IntentContext()) })
        h.start(DictateOptions(polish: true))
        h.c.receive(.finalized("原文"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.c.cancel())
        polisher.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.log.terminal == .failed(.cancelled))
        #expect(h.log.events.filter { if case .finished = $0 { return true }; return false }.isEmpty)
    }

    // MARK: - 歷史

    @Test func historyOffRecordsNothing() {
        let h = makeCLI(historyEnabled: false)
        h.start()
        h.c.receive(.finalized("x"), session: 1)
        h.c.stop()
        h.c.streamEnded(session: 1)
        #expect(h.history.sessions.isEmpty)
        #expect(h.history.exchanges.isEmpty)
    }

    // MARK: - 麥克風音訊分流

    @Test func audioIsForwardedToTheRecognizerAndMetered() async throws {
        let h = makeCLI()
        h.start(DictateOptions(silenceMs: 500))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        func chunk(_ value: Float) throws -> AudioChunk {
            let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            b.frameLength = 1600
            for i in 0..<1600 { b.floatChannelData![0][i] = value }
            return AudioChunk(buffer: b)
        }
        let received = Task { () -> Int in
            var n = 0
            for await _ in h.asr.audioStreams[0] { n += 1 }
            return n
        }
        // 位準經 detached task 跳回 main：一塊一塊餵、等它吃進去再推時鐘
        for (i, value) in [Float(0.0005), 0.0005, 0.05, 0.05, 0.05, 0.05].enumerated() {
            h.clock.now += 0.1
            h.audio.continuation?.yield(try chunk(value))
            let deadline = Date().addingTimeInterval(3)
            while h.c.levelSamplesIngested <= i, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(h.c.levelSamplesIngested == 6)
        #expect(h.c.debugSpeechDetected, "麥克風位準有餵進端點判斷")
        h.c.stop()
        #expect(await received.value == 6, "每一塊音訊都原樣交給辨識器，麥克風停了辨識器的輸入跟著結束")
    }
}

@MainActor
func waitForTerminal(_ log: CLIEventLog, timeout: Double = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while log.terminal == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return log.terminal != nil
}
