import AVFoundation
import Testing
@testable import SaymendCore

/// issue #85：放開熱鍵後、辨識還在排空（`.finishing`）時再按熱鍵＝**先錄、等排空跑完再接手**。
///
/// #83／#84 的做法是捨棄排空、立刻開新 session：舊串流被取消，還沒送達的定稿就此消失——Whisper 遠端的排空
/// 就是在等整段話的上傳結果，會整段遺失。現在按下當下就開麥克風（音訊先留著），舊串流照常跑完
/// （定稿上屏、潤飾），之後的接手與「排空跑完才按」走同一條路：舊 session 沒被凍結或封存＝同 session 續聽
/// （延續窗規則），否則開新 session。辨識器同一時間只跑一條串流。
///
/// 這裡的 `asrStreamEnded`／`handleTranscript` 一律代表**上一段**的串流——排隊期間辨識器上只有它。
@MainActor
@Suite struct PressDuringDrainTests {

    private func fixture() -> StatefulFieldEnvironment {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true, bundleID: "com.foo.app")
        return env
    }

    /// 可辨識的音訊片段：以 frameLength 當標記
    private func chunk(_ frames: AVAudioFrameCount) -> AudioChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return AudioChunk(buffer: buffer)
    }

    private func frames(of stream: AsyncStream<AudioChunk>) async -> [AVAudioFrameCount] {
        var out: [AVAudioFrameCount] = []
        for await c in stream { out.append(c.buffer.frameLength) }
        return out
    }

    // MARK: - 核心：排空的字不丟，接手同 session

    /// issue 的情境本身：排空中按下，排空送來的定稿照常上屏；排空結束才把排隊的錄音交給辨識器，同 session 續聽。
    @Test func theDrainingTextLandsAndTheQueuedAudioResumesTheSameSession() async throws {
        let env = fixture()
        let audio = FakeAudio()
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 排空

        c.hotkeyPressed(at: 11.5)                           // 排空中按下

        #expect(c.phase == .listening(.hold), "對外：正在錄音")
        #expect(hud.states.last == .listening(mode: .hold, volatile: ""))
        #expect(audio.startCount == 2, "按下當下就開麥克風，不等排空")
        #expect(asr.startCount == 1, "辨識器同一時間只跑一條：排隊的錄音還沒交出去")
        #expect(asr.cancelCount == 0, "舊串流不得被取消")

        c.handleTranscript(.finalized("第二句"), at: 12.0)  // 舊串流排空送來的尾端
        #expect(env.text(in: "A") == "第一句第二句", "排空中的定稿照常上屏——這正是以前會丟掉的部分")

        c.asrStreamEnded(at: 12.5)                          // 舊串流結束 → 接手

        #expect(asr.startCount == 2, "排空結束才把排隊的錄音交給辨識器")
        #expect(c.phase == .listening(.hold))
        #expect(!c.isLingering)
        #expect(history.sessions.count == 1, "同 session 續聽（延續窗規則），不開新的")
        #expect(history.finished.isEmpty, "不得封存")
        #expect(!history.exchanges.contains { $0.outcomeKind == "drainAbandoned" }, "什麼都沒捨棄")

        // 前提用 #require：不成立時下面的讀取會永遠等下去
        try #require(audio.startCount == 2, "接手不再開一次麥克風，用的是排隊中那條錄音")
        try #require(asr.audioStreams.count == 2)
        audio.continuation?.yield(chunk(7))                 // 接手之後錄到的音訊流向新的辨識串流
        var it = asr.audioStreams[1].makeAsyncIterator()
        #expect(await it.next()?.buffer.frameLength == 7, "交給辨識器的就是排隊中那條錄音")

        c.handleTranscript(.finalized("第三句"), at: 13.0)
        #expect(env.text(in: "A") == "第一句第二句第三句", "接在同一段後面")
    }

    /// 放開之後、排空還沒結束又按：再錄一條。接手時依序串成一條交給辨識器，兩次都已放開＝直接進排空。
    @Test func severalPressesWhileDrainingAreConcatenatedInOrder() async throws {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                          // 排空

        c.hotkeyPressed(at: 11.5)                           // 第一條
        audio.continuation?.yield(chunk(10))
        c.hotkeyReleased(at: 12.5)
        #expect(audio.stopCount == 2, "放開即停麥克風")
        #expect(hud.states.last == .transcribing, "說完了，在等辨識")
        #expect(c.phase == .idle && c.isEngaged, "對外不在錄音，但 session 工作仍在進行")
        #expect(asr.startCount == 1, "排空還沒結束")

        c.hotkeyPressed(at: 13.0)                           // 第二條
        #expect(c.phase == .listening(.hold))
        #expect(audio.startCount == 3)
        audio.continuation?.yield(chunk(20))
        c.hotkeyReleased(at: 14.0)
        try #require(audio.stopCount == 3, "兩條都已收完（否則下面的讀取永遠等不到結束）")

        c.asrStreamEnded(at: 14.5)                          // 舊串流結束 → 接手

        try #require(asr.startCount == 2, "兩條一起交給同一個辨識串流")
        try #require(audio.startCount == 3, "接手不再開一次麥克風（否則下面的讀取永遠等不到結束）")
        #expect(await frames(of: asr.audioStreams[1]) == [10, 20], "依錄音順序串接，且兩條都收完才結束")
        #expect(c.phase == .idle && !c.isLingering && c.isEngaged, "已放開：直接進新一段的排空")

        c.asrStreamEnded(at: 15.0)                          // 新一段排空結束
        #expect(c.isLingering, "照常進延續窗")
    }

    /// 排隊中與 `.listening` 同一套 tap／長按規則：短按＝鎖定，接手後仍是鎖定，再 tap 才結束。
    @Test func aTapWhileQueuedLocksAndTheLockSurvivesTheHandOver() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                          // 排空
        c.hotkeyPressed(at: 11.5)
        c.hotkeyReleased(at: 11.6)                          // tap → 鎖定

        #expect(c.phase == .listening(.locked))
        #expect(hud.states.last == .listening(mode: .locked, volatile: ""))
        #expect(audio.stopCount == 1, "鎖定不停麥克風（只有第一段放開時停過一次）")

        c.asrStreamEnded(at: 12.0)
        #expect(c.phase == .listening(.locked), "接手後仍是鎖定")
        #expect(asr.startCount == 2)

        c.hotkeyPressed(at: 13.0)
        c.hotkeyReleased(at: 13.1)                          // 鎖定中 tap → 結束
        #expect(audio.stopCount == 2)
        #expect(c.phase == .idle && !c.isLingering)
    }

    /// 鎖定中排隊，再 tap 一次＝這一條錄完（與 `.listening(.locked)` 相同），等排空結束後直接進排空。
    @Test func tappingAgainWhileQueuedAndLockedEndsTheCapture() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                          // 排空
        c.hotkeyPressed(at: 11.5)
        c.hotkeyReleased(at: 11.6)                          // 鎖定
        c.hotkeyPressed(at: 12.0)
        c.hotkeyReleased(at: 12.1)                          // 再 tap → 這條錄完

        #expect(audio.stopCount == 2)
        #expect(c.phase == .idle && c.isEngaged)
        #expect(hud.states.last == .transcribing)

        c.asrStreamEnded(at: 12.5)
        #expect(asr.startCount == 2)
        #expect(c.phase == .idle && !c.isLingering, "已錄完：接手後直接排空")
    }

    // MARK: - 舊 session 已凍結／封存 → 開新 session（#84 的封存行為不退化）

    /// 排空期間使用者手動編輯過（凍結）：舊 session 照排空結束的規則封存（以帳本全文定稿），接手開新 session。
    @Test func aFrozenOldSessionIsArchivedAndTheQueuedAudioStartsANewOne() async {
        let env = fixture()
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("第一句。")
        let history = FakeHistory()
        let audio = FakeAudio()
        let (c, asr, _) = makeStatefulController(env: env, polisher: polisher, history: history, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.settings.sessionLanguageOverride = .english        // 舊 session 的臨時語系覆蓋（規格 §4.5）
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.tick(at: 12.1)                                    // 第一句閉合 → 潤飾
        await c.lastIntentTask?.value
        c.hotkeyReleased(at: 13.0)                          // 排空
        c.userActivityDetected(at: 13.2)                    // 凍結
        c.hotkeyPressed(at: 13.5)                           // 排空中按下 → 排隊

        #expect(history.sessions.count == 1, "接手前不封存、不開新的")
        c.asrStreamEnded(at: 14.0)

        let a = history.sessions.first?.id
        #expect(history.sessions.count == 2, "凍結的 session 不續聽：開新 session")
        #expect(history.finished.map(\.id) == [a], "舊 session 在新 session 開始前封存；實際：\(history.finished)")
        #expect(history.finished.first?.finalText == "第一句。", "以封存當下的帳本全文定稿")
        #expect(c.settings.sessionLanguageOverride == nil, "per-session 覆蓋隨舊 session 封存失效")
        #expect(c.ledger.isActive && !c.ledger.frozen, "新 session 乾淨開始")
        #expect(c.phase == .listening(.hold))
        #expect(asr.startCount == 2)
        #expect(audio.stopCount == 1, "封存舊 session 不得停掉排隊中還在錄的麥克風（只有第一段放開時停過）")

        c.escapePressed()
        #expect(history.finished.map(\.id) == history.sessions.map(\.id), "兩個 session 各封存一次")
    }

    /// 排隊中按著熱鍵時手動輸入（打字、點擊）：與錄音中相同，舊 session 凍結；接手時因此開新 session。
    @Test func userActivityWhileQueuedFreezesTheOldSession() {
        let env = fixture()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)

        c.userActivityDetected(at: 12.0)

        #expect(c.ledger.frozen)
        #expect(hud.states.last == .notice("偵測到手動輸入，本段不再修正"))
        c.asrStreamEnded(at: 12.5)
        #expect(history.sessions.count == 2, "凍結的 session 不續聽")
    }

    /// lease（#43）：兩條接手路徑走完、全部封存之後，registry 一筆都不能剩。
    @Test(arguments: [false, true]) func everyLeaseIsReturnedOnBothHandOverPaths(oldSessionFrozen: Bool) {
        let env = fixture()
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)                          // 排空
        if oldSessionFrozen { c.userActivityDetected(at: 11.2) }
        c.hotkeyPressed(at: 11.5)
        #expect(env.identityEntryCount == 1, "前提：只有舊 session 持有起始欄位的 lease（排隊不 snapshot）")
        c.asrStreamEnded(at: 12.0)                          // 接手（續聽或新 session）
        c.escapePressed()

        #expect(env.identityEntryCount == 0, "每個 lease 恰歸還一次")
    }

    /// 延續窗中按下＝同 session 續聽（規格 §3.4），行為不變。
    @Test func pressingTheHotkeyDuringLingeringStillResumesTheSameSession() async {
        let env = fixture()
        let history = FakeHistory()
        let (c, asr, _) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)                          // 進延續窗
        await c.lastIntentTask?.value
        #expect(c.isLingering, "前提：在延續窗")

        c.hotkeyPressed(at: 12.0)

        #expect(asr.startCount == 2, "延續窗沒有在跑的串流，立刻開始辨識")
        #expect(history.sessions.count == 1, "同 session 續聽，不開新的")
        #expect(history.finished.isEmpty, "不得封存")
    }

    // MARK: - 舊串流失敗／沒偵測到語音：提示不得被接手蓋掉

    /// 上一段失敗（例如遠端上傳逾時＝整段沒了）：排隊的錄音不是失敗的那段，照樣接手成新 session；
    /// 失敗提示走救援提示通道，否則接手的錄音畫面會立刻把使用者唯一的線索蓋掉。
    @Test func theOldStreamsFailureIsShownAndTheQueuedAudioStillStarts() {
        let env = fixture()
        let audio = FakeAudio()
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, audio: audio)
        c.hotkeyPressed(at: 10.0)
        let a = c.sessionID
        c.hotkeyReleased(at: 11.0)                          // 排空
        c.hotkeyPressed(at: 11.5)                           // 排隊，仍按著

        c.handleTranscript(.failed(reason: "逾時"), at: 20.0)

        #expect(hud.rescueNotices == ["辨識失敗（逾時）"], "走救援提示通道（HUDArbiter 保證停留）")
        #expect(audio.stopCount == 1, "排隊的錄音不得被停掉（只有第一段放開時停過）")
        #expect(asr.cancelCount == 1, "失敗的舊串流照舊取消")
        #expect(asr.startCount == 2, "排隊的錄音照樣接手")
        #expect(c.phase == .listening(.hold))
        #expect(history.sessions.count == 2, "舊 session 已因失敗封存：開新 session")
        #expect(history.finished.map(\.id) == [history.sessions.first?.id])

        c.receiveStreamEnd(session: a, at: 20.1)            // 失敗的舊串流隨後結束：已跳號，不得收掉新 session
        #expect(c.phase == .listening(.hold))
    }

    /// 已放開才失敗：同樣接手（直接排空），提示同樣走救援提示通道。
    @Test func aFailureAfterTheQueuedCaptureEndedStillHandsOver() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        c.hotkeyReleased(at: 12.5)                          // 排隊的這條錄完

        c.handleTranscript(.failed(reason: "逾時"), at: 20.0)

        #expect(hud.rescueNotices == ["辨識失敗（逾時）"])
        #expect(asr.startCount == 2)
        #expect(c.phase == .idle && c.isEngaged && !c.isLingering, "已錄完：接手後直接排空")
    }

    /// 上一段整段沒偵測到語音：提示同樣不得被接手蓋掉。
    @Test func theNoSpeechNoticeOfTheOldSessionSurvivesTheHandOver() {
        let env = fixture()
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.noSpeechDetected, at: 13.0)
        c.hotkeyReleased(at: 14.0)
        c.hotkeyPressed(at: 14.5)

        c.asrStreamEnded(at: 15.0)

        #expect(hud.rescueNotices == [DictationController.noSpeechNotice])
        #expect(asr.startCount == 2)
        #expect(history.sessions.count == 2, "沒產出任何字的 session 封存，不續聽")
        #expect(c.phase == .listening(.hold))
    }

    /// 排空正常結束時沒有要說的事：不走救援提示，也不閃一下延續窗。
    @Test func aNormalHandOverShowsNoNoticeAndNoLingering() {
        let env = fixture()
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        let before = hud.states.count

        c.asrStreamEnded(at: 12.0)

        #expect(hud.rescueNotices.isEmpty)
        #expect(!hud.states.dropFirst(before).contains(.lingering), "馬上就接手，不顯示「可修正」")
        #expect(hud.states.last == .listening(mode: .hold, volatile: ""))
    }

    /// 包上真的 `HUDArbiter`：失敗提示先停在畫面上，接手的錄音畫面延後到保護期之後才重播。
    /// 提示若在接手**之後**才送，錄音畫面會先畫出來、提示雖然還在，但順序錯了（arbiter 只延後保護期內到達的狀態）。
    @Test func withTheArbiterTheOldSessionsNoticeStaysUpBeforeTheRecordingState() {
        let env = fixture()
        let scheduler = FakeHUDScheduler()
        let (c, _, inner) = makeStatefulController(env: env, wrapHUD: { HUDArbiter(inner: $0, scheduler: scheduler) })
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        let before = inner.states.count

        c.handleTranscript(.failed(reason: "逾時"), at: 20.0)

        #expect(Array(inner.states.dropFirst(before)) == [.hidden, .notice("辨識失敗（逾時）")],
                "接手的錄音畫面被延後；實際：\(inner.states.dropFirst(before))")
        scheduler.advance(to: HUDArbiter.minimumHold)
        #expect(inner.states.last == .listening(mode: .hold, volatile: ""), "保護期過後重播錄音中")
    }

    // MARK: - 畫面

    /// 排隊中按著熱鍵時，畫面屬於正在說的這一段：舊串流的「辨識中…」「載入模型中…」不得蓋掉它。
    @Test func theOldStreamsStatusDoesNotCoverTheQueuedRecording() {
        let env = fixture()
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)

        c.handleTranscript(.transcribing, at: 12.0)
        c.handleTranscript(.loadingModel, at: 12.1)

        #expect(hud.states.last == .listening(mode: .hold, volatile: ""))
    }

    /// 一般的錄音中照舊顯示（本機模型首次載入要讓人知道在等什麼，#17）。
    @Test func theStatusStillShowsWhileListeningNormally() {
        let env = fixture()
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.loadingModel, at: 10.2)
        #expect(hud.states.last == .loadingModel)
        c.handleTranscript(.transcribing, at: 10.3)
        #expect(hud.states.last == .transcribing)
    }

    /// 排隊中按 HUD 的復原：與排空窗相同，作用在舊 session 上。
    @Test func undoWhileQueuedActsOnTheOldSession() {
        let env = fixture()
        let (c, _, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)

        c.undoRequested()

        #expect(hud.states.last == .notice("沒有可復原的步驟"), "有處理（只是沒有步驟可退），不是被當成 idle 忽略")
    }

    // MARK: - Esc、麥克風

    /// 排隊中按 Esc＝比照排空中按 Esc：中止排空並封存；排隊的錄音停掉、丟棄，之後不再接手。
    @Test func escapeWhileQueuedAbortsBothAndStopsTheMicrophone() {
        let env = fixture()
        let audio = FakeAudio()
        let history = FakeHistory()
        let (c, asr, _) = makeStatefulController(env: env, history: history, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)

        c.escapePressed()

        #expect(asr.cancelCount == 1, "中止排空")
        #expect(audio.stopCount == 2, "排隊的錄音停掉，麥克風不得漏開")
        #expect(!c.isEngaged && c.phase == .idle)
        #expect(history.finished.count == 1)
        #expect(env.text(in: "A") == "第一句", "沒辨識過的錄音沒有字可退，已上屏的不動")

        c.asrStreamEnded(at: 12.0)                          // 被取消的舊串流隨後結束
        #expect(asr.startCount == 1, "丟棄的錄音不得接手")
        #expect(!c.isEngaged)
    }

    /// 麥克風開不起來：這次按下沒錄到東西，但排空照常跑完，舊 session 的字一個都不丟。
    @Test func aMicrophoneFailureWhileDrainingLeavesTheDrainAlone() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        audio.failNextStart = true

        c.hotkeyPressed(at: 11.5)

        #expect(hud.states.last == .notice("無法啟動麥克風"))
        #expect(c.phase == .idle && c.isEngaged, "仍在排空")
        c.handleTranscript(.finalized("尾端"), at: 12.0)
        #expect(env.text(in: "A") == "尾端")
        c.asrStreamEnded(at: 12.5)
        #expect(c.isLingering, "照常進延續窗，沒有東西要接手")
        #expect(asr.startCount == 1)
    }

    // MARK: - 密碼欄（#10 的不變式）

    /// 在密碼欄按下：不錄，照舊封存舊 session（與 #85 之前相同）。
    @Test func pressingInsideAPasswordFieldWhileDrainingDoesNotRecord() {
        let env = fixture()
        let audio = FakeAudio()
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        env.focus("P")

        c.hotkeyPressed(at: 11.5)

        #expect(audio.startCount == 1, "不開麥克風")
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(!c.isEngaged)
        #expect(history.finished.count == 1)
        c.asrStreamEnded(at: 12.0)
        #expect(asr.startCount == 1)
    }

    /// 問不出 subrole（#59）也一樣 fail closed。
    @Test func pressingWhereTheSubroleIsUnknownWhileDrainingDoesNotRecord() {
        let env = fixture()
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.foo.app")
        let audio = FakeAudio()
        let (c, _, hud) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        env.focus("U")

        c.hotkeyPressed(at: 11.5)

        #expect(audio.startCount == 1)
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
    }

    /// 排隊中按著熱鍵時焦點移進密碼欄：與錄音中相同，當場硬停——排空與排隊的錄音一起丟，不留任何字。
    @Test func focusMovingIntoAPasswordFieldWhileQueuedAbortsEverything() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, focusWatcher: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        #expect(env.activeWatchCount == 1, "前提：排隊的錄音有監看")

        env.focus("P")

        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(asr.cancelCount == 1)
        #expect(audio.stopCount >= 2, "麥克風停掉")
        #expect(!c.isEngaged)
        #expect(env.activeWatchCount == 0)
        c.asrStreamEnded(at: 12.0)
        #expect(asr.startCount == 1, "不接手")
    }

    /// 監看開始前就已移進密碼欄（按下當下的閘門之後、observer 掛上之前）：補查一次就攔下。
    @Test func focusMovingBeforeTheQueuedWatchStartsIsCaught() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, hud) = makeStatefulController(env: env, focusWatcher: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        env.beforeStartWatching = { env.focus("P", notifyingWatches: false) }

        c.hotkeyPressed(at: 11.5)

        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(asr.cancelCount == 1)
        #expect(!c.isEngaged)
    }

    /// 跨行程的焦點移動靠 tick 的 resync 發現（#70）：排隊中按著熱鍵時同樣要查。
    @Test func resyncWhileQueuedCatchesAPasswordFieldInAnotherProcess() {
        let env = fixture()
        let (c, asr, hud) = makeStatefulController(env: env, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        env.resyncReport = .secure

        c.tick(at: 12.0)

        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(asr.cancelCount == 1)
        #expect(!c.isEngaged)
    }

    /// 接手當下焦點已在密碼欄（放開後才移過去，監看已停）：錄好的音訊一個字都不辨識。
    @Test func aPasswordFieldAtHandOverDiscardsTheQueuedAudio() {
        let env = fixture()
        let history = FakeHistory()
        let (c, asr, hud) = makeStatefulController(env: env, history: history, focusWatcher: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)
        c.hotkeyReleased(at: 12.5)                          // 錄完，監看停止
        #expect(env.activeWatchCount == 0, "放開即停監看：只在錄音期間持有（#70）")
        env.focus("P")

        c.asrStreamEnded(at: 13.0)

        #expect(asr.startCount == 1, "不交給辨識器")
        #expect(asr.cancelCount == 0, "是接手時拒絕；放開後監看已停，不會在那之前硬停")
        #expect(hud.states.last == .notice("密碼欄位不聽寫"))
        #expect(!c.isEngaged)
        #expect(history.finished.count == 1, "舊 session 封存")
        #expect(history.sessions.count == 1, "不開新 session")
    }

    /// 同上，但接手時還按著熱鍵（焦點移動沒有送通知）：還在錄的麥克風要停掉。
    @Test func aPasswordFieldAtHandOverStopsAStillRunningCapture() {
        let env = fixture()
        let audio = FakeAudio()
        let (c, asr, _) = makeStatefulController(env: env, audio: audio)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)                           // 仍按著
        env.focus("P", notifyingWatches: false)

        c.asrStreamEnded(at: 12.0)

        #expect(asr.startCount == 1)
        #expect(audio.stopCount == 2, "麥克風不得漏開")
        #expect(!c.isEngaged)
        c.hotkeyReleased(at: 13.0)
        #expect(audio.stopCount == 2, "已封存：放開不再有動作")
    }
}
