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

    public private(set) var phase: Phase = .idle
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
        switch phase {
        case .idle:
            pressedAt = t
            startListening(mode: .hold, at: t)
        case .listening:
            pressedAt = t   // 鎖定模式下的潛在「結束 tap」；hold 下的 key repeat 只更新時間
        }
    }

    public func hotkeyReleased(at t: TimeInterval) {
        guard let pressed = pressedAt else { return }
        let isTap = (t - pressed) < Self.tapThreshold
        switch phase {
        case .listening(.hold):
            if isTap {
                phase = .listening(.locked)
                hud.present(.listening(mode: .locked, volatile: ""))
            } else {
                endListening(at: t)
            }
        case .listening(.locked):
            if isTap { endListening(at: t) }
        case .idle:
            break
        }
        pressedAt = nil
    }

    public func escapePressed() {
        guard case .listening = phase else { return }
        endedByEscape = true
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        try? coordinator.discardCurrentUtterance()
        phase = .idle
        hud.present(.hidden)
    }

    // MARK: - 週期與 ASR 事件（行為在 Task 11 完成）

    public func tick(at t: TimeInterval) {
        guard case .listening = phase else { return }
        process(actions: segmenter.onTick(at: t))
    }

    public func handleTranscript(_ event: TranscriptEvent, at t: TimeInterval) {
        guard case .listening(let mode) = phase else { return }
        segmenter.onTranscript(event, at: t)
        switch event {
        case .volatile(let text):
            hud.present(.listening(mode: mode, volatile: text))
        case .finalized(let text):
            do {
                try coordinator.insertFinalized(text)
            } catch {
                hud.present(.notice("插入失敗"))
            }
        }
    }

    public func asrStreamEnded(at t: TimeInterval) {
        guard !endedByEscape else { endedByEscape = false; return }
        process(actions: segmenter.flush())
    }

    // MARK: - 內部

    private func startListening(mode: ListeningMode, at t: TimeInterval) {
        do {
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            endedByEscape = false
            let audioStream = try audio.start()
            let events = asr.start(audio: audioStream, localeIdentifier: settings.asrLocaleIdentifier)
            phase = .listening(mode)
            hud.present(.listening(mode: mode, volatile: ""))
            readerTask = Task { [weak self] in
                for await event in events {
                    await MainActor.run {
                        self?.handleTranscript(event, at: Date().timeIntervalSinceReferenceDate)
                    }
                }
                await MainActor.run {
                    self?.asrStreamEnded(at: Date().timeIntervalSinceReferenceDate)
                }
            }
        } catch {
            phase = .idle
            hud.present(.notice("無法啟動麥克風"))
        }
    }

    private func endListening(at t: TimeInterval) {
        audio.stop()   // audio 串流 finish → ASR 排空 → asrStreamEnded 收尾
        phase = .idle
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
