import Foundation

/// 聽寫狀態機（規格 §3.1–§3.4 的 M1 範圍）。
/// 所有系統能力由 protocol 注入；時間一律由呼叫端傳入（可測試）。
@MainActor
public final class DictationController {
    public enum Phase: Equatable {
        case idle
        case listening(ListeningMode)
    }

    public static let tapThreshold: TimeInterval = 0.3

    /// 內部狀態機：比對外多一個 `.finishing` 排空過渡態。
    /// endListening 後、asrStreamEnded 收尾前處於 finishing——此時 ASR 排空（drain）
    /// 產生的尾端 finalized 仍須上屏＋進 segmenter buffer，不能被丟棄（規格「不能白說話」）。
    private enum InternalPhase {
        case idle
        case listening(ListeningMode)
        case finishing
    }
    private var internalPhase: InternalPhase = .idle

    /// 對外仍只有 idle / listening 兩態；內部的排空窗（finishing）對呼叫端等同 idle。
    public var phase: Phase {
        switch internalPhase {
        case .idle, .finishing: return .idle
        case .listening(let mode): return .listening(mode)
        }
    }
    /// 最近一次潤飾任務；測試以 await 等待完成
    public private(set) var lastPolishTask: Task<Void, Never>?

    private let audio: any AudioCaptureService
    private let asr: any ASREngine
    private let coordinator: InsertionCoordinator
    private let polisher: any PolishServing
    private let hud: any HUDPresenting
    private let settings: AppSettings
    private var segmenter: UtteranceSegmenter

    private var pressedAt: TimeInterval?
    private var readerTask: Task<Void, Never>?
    private var endedByEscape = false
    /// 遞增的 session 序號：readerTask 攜帶啟動當下的序號，事件抵達時比對，
    /// 舊 session 的殘留事件（快速停→再開的重疊視窗）一律丟棄，避免跨 session 污染。
    private(set) var sessionID = 0

    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                coordinator: InsertionCoordinator,
                polisher: any PolishServing,
                hud: any HUDPresenting,
                settings: AppSettings,
                segmenter: UtteranceSegmenter = UtteranceSegmenter()) {
        self.audio = audio
        self.asr = asr
        self.coordinator = coordinator
        self.polisher = polisher
        self.hud = hud
        self.settings = settings
        self.segmenter = segmenter
    }

    // MARK: - 熱鍵事件

    public func hotkeyPressed(at t: TimeInterval) {
        switch internalPhase {
        case .idle, .finishing:
            // finishing（上一 session 尚在排空）期間按下＝立刻開新 session；
            // startListening 會取消舊 readerTask 並跳號，舊事件因此被過濾。
            pressedAt = t
            startListening(mode: .hold, at: t)
        case .listening:
            pressedAt = t   // 鎖定模式下的潛在「結束 tap」；hold 下的 key repeat 只更新時間
        }
    }

    public func hotkeyReleased(at t: TimeInterval) {
        guard let pressed = pressedAt else { return }
        let isTap = (t - pressed) < Self.tapThreshold
        switch internalPhase {
        case .listening(.hold):
            if isTap {
                internalPhase = .listening(.locked)
                hud.present(.listening(mode: .locked, volatile: ""))
            } else {
                endListening(at: t)
            }
        case .listening(.locked):
            if isTap { endListening(at: t) }
        case .idle, .finishing:
            break
        }
        pressedAt = nil
    }

    public func escapePressed() {
        guard case .listening = internalPhase else { return }
        endedByEscape = true
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        try? coordinator.discardCurrentUtterance()
        internalPhase = .idle
        hud.present(.hidden)
    }

    // MARK: - 週期與 ASR 事件（行為在 Task 11 完成）

    public func tick(at t: TimeInterval) {
        guard case .listening = internalPhase else { return }
        process(actions: segmenter.onTick(at: t))
    }

    public func handleTranscript(_ event: TranscriptEvent, at t: TimeInterval) {
        switch internalPhase {
        case .idle:
            return
        case .listening, .finishing:
            break   // finishing（排空窗）期間仍須處理 finalized，不能丟
        }
        segmenter.onTranscript(event, at: t)
        switch event {
        case .volatile(let text):
            // 只有真正在聽時才更新 HUD 預覽；排空窗 HUD 已隱藏，不回頭顯示 volatile。
            if case .listening(let mode) = internalPhase {
                hud.present(.listening(mode: mode, volatile: text))
            }
        case .finalized(let text):
            do {
                try coordinator.insertFinalized(text)
            } catch {
                hud.present(.notice("插入失敗"))
            }
        }
    }

    public func asrStreamEnded(at t: TimeInterval) {
        defer { internalPhase = .idle }   // 排空完成才轉 idle
        guard !endedByEscape else { endedByEscape = false; return }
        process(actions: segmenter.flush())
    }

    /// readerTask 專用入口：只處理當前 session 的 transcript，
    /// 舊 session 的殘留事件（sid 不符）一律丟棄，避免跨 session 文字注入。
    func receiveTranscript(_ event: TranscriptEvent, session sid: Int, at t: TimeInterval) {
        guard sid == sessionID else { return }
        handleTranscript(event, at: t)
    }

    /// readerTask 專用入口：只認當前 session 的串流結束，
    /// 舊 session 的 stream-end（sid 不符）忽略，避免提早 flush 新 session 的半句。
    func receiveStreamEnd(session sid: Int, at t: TimeInterval) {
        guard sid == sessionID else { return }
        asrStreamEnded(at: t)
    }

    // MARK: - 內部

    private func startListening(mode: ListeningMode, at t: TimeInterval) {
        do {
            readerTask?.cancel()   // 取消上一 session 的讀取，避免殘留事件污染新 session
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            endedByEscape = false
            sessionID &+= 1
            let sid = sessionID
            let audioStream = try audio.start()
            let events = asr.start(audio: audioStream, localeIdentifier: settings.asrLocaleIdentifier)
            internalPhase = .listening(mode)
            hud.present(.listening(mode: mode, volatile: ""))
            readerTask = Task { [weak self] in
                for await event in events {
                    await MainActor.run {
                        self?.receiveTranscript(event, session: sid, at: Date().timeIntervalSinceReferenceDate)
                    }
                }
                await MainActor.run {
                    self?.receiveStreamEnd(session: sid, at: Date().timeIntervalSinceReferenceDate)
                }
            }
        } catch {
            internalPhase = .idle
            hud.present(.notice("無法啟動麥克風"))
        }
    }

    private func endListening(at t: TimeInterval) {
        audio.stop()             // audio 串流 finish → ASR 排空 → drain finalized → asrStreamEnded 收尾
        internalPhase = .finishing   // 進入排空窗：drain 的尾端 finalized 仍要收，待 asrStreamEnded 才轉 idle
        hud.present(.hidden)
    }

    private func endSession(at t: TimeInterval) {
        // 鎖定模式逾時（sessionTimedOut）走這裡
        endListening(at: t)
    }

    private func process(actions: [UtteranceSegmenter.Action]) {
        for action in actions {
            switch action {
            case .utteranceEnded(let raw):
                polishAndReplace(raw: raw)
            case .sessionTimedOut:
                endSession(at: Date().timeIntervalSinceReferenceDate)
            }
        }
    }

    private func polishAndReplace(raw: String) {
        let snapshot = coordinator.snapshotAndBeginNext()
        lastPolishTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.polisher.polish(utteranceRaw: raw)
            await MainActor.run {
                switch outcome {
                case .polished(let text):
                    let replaced = (try? self.coordinator.replaceTail(snapshot, with: text)) ?? false
                    if !replaced {
                        self.hud.present(.notice("未潤飾"))
                    }
                case .degraded:
                    self.hud.present(.notice("未潤飾"))
                }
            }
        }
    }
}
