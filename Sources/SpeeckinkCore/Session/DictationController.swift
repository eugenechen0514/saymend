import Foundation

/// 聽寫狀態機（規格 §3.1–§3.4）。
/// 所有系統能力由 protocol 注入；時間一律由呼叫端傳入（可測試）。
@MainActor
public final class DictationController {
    public enum Phase: Equatable {
        case idle
        case listening(ListeningMode)
    }

    public static let tapThreshold: TimeInterval = 0.3
    /// session 延續窗（規格 §3.4）：正常結束後 8 秒內再按＝同 session 延續
    public static let lingerWindow: TimeInterval = 8.0

    /// 內部狀態機：finishing＝排空窗；lingering＝延續窗。兩者對外皆等同 idle。
    private enum InternalPhase {
        case idle
        case listening(ListeningMode)
        case finishing
        case lingering(until: TimeInterval)
    }
    private var internalPhase: InternalPhase = .idle

    public var phase: Phase {
        switch internalPhase {
        case .idle, .finishing, .lingering: return .idle
        case .listening(let mode): return .listening(mode)
        }
    }

    /// 是否在 8 秒延續窗內（HUD 與測試用）
    public var isLingering: Bool {
        if case .lingering = internalPhase { return true }
        return false
    }

    /// 最近一次意圖處理任務；測試以 await 等待完成
    public private(set) var lastIntentTask: Task<Void, Never>?

    private let audio: any AudioCaptureService
    private let asr: any ASREngine
    private let coordinator: InsertionCoordinator
    private let intentService: any IntentServing
    private let hud: any HUDPresenting
    private let settings: AppSettings
    private var segmenter: UtteranceSegmenter
    /// 鐵律最後手段：原文救不回時交給剪貼簿（app 端接 NSPasteboard）
    private let clipboardRescue: ((String) -> Void)?
    /// 聚焦欄位快照：密碼欄位拒絕聽寫、session 起點取 AX 錨位（規格 §4.6／§5.3）
    private let fieldReader: (any FieldContextProviding)?

    /// session 帳本（測試經 @testable 檢視）
    private(set) var ledger = SessionLedger()

    private var pressedAt: TimeInterval?
    private var readerTask: Task<Void, Never>?
    /// 60 秒靜音逾時結束：排空後直接封存，不進延續窗（規格 §3.4 逾時＝凍結觸發器）
    private var archiveAfterDrain = false
    /// 遞增 session 序號：readerTask 事件過濾，避免跨 session 污染
    private(set) var sessionID = 0

    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                coordinator: InsertionCoordinator,
                intent: any IntentServing,
                hud: any HUDPresenting,
                settings: AppSettings,
                segmenter: UtteranceSegmenter = UtteranceSegmenter(),
                clipboardRescue: ((String) -> Void)? = nil,
                fieldReader: (any FieldContextProviding)? = nil) {
        self.audio = audio
        self.asr = asr
        self.coordinator = coordinator
        self.intentService = intent
        self.hud = hud
        self.settings = settings
        self.segmenter = segmenter
        self.clipboardRescue = clipboardRescue
        self.fieldReader = fieldReader
    }

    // MARK: - 熱鍵事件

    public func hotkeyPressed(at t: TimeInterval) {
        switch internalPhase {
        case .idle, .finishing, .lingering:
            // finishing：上一 session 排空中按下＝立刻開新 session（跳號過濾舊事件）。
            // lingering：延續窗內按下＝同 session 續聽（帳本延續，規格 §3.4）。
            pressedAt = t
            startListening(mode: .hold, at: t)
        case .listening:
            pressedAt = t   // 鎖定模式的潛在「結束 tap」；hold 下的 key repeat 只更新時間
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
        case .idle, .finishing, .lingering:
            break
        }
        pressedAt = nil
    }

    public func escapePressed() {
        if isLingering {
            archiveSession()                // 延續窗中按 Esc＝提前定稿（吞掉 Esc 由熱鍵層處理）
            return
        }
        guard case .listening = internalPhase else { return }
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        try? coordinator.discardCurrentUtterance()
        ledger.archive()                    // Esc 不進延續窗（設計裁決 3）
        internalPhase = .idle               // 之後遲到的 stream-end 會被 asrStreamEnded 的相位守衛冪等忽略
        hud.present(.hidden)
    }

    /// 使用者手動活動（打字／滑鼠點擊／切 App；app 端由 HotkeyMonitor 與 NSWorkspace 餵入）。
    /// 聽寫中＝凍結（文字定稿、不再改寫，錄音照常）；延續窗中＝立即封存（設計裁決 2）。
    public func userActivityDetected(at t: TimeInterval) {
        switch internalPhase {
        case .listening, .finishing:
            guard ledger.isActive, !ledger.frozen else { return }
            ledger.freeze()
            hud.present(.notice("偵測到手動輸入，本段不再修正"))
        case .lingering:
            archiveSession()
        case .idle:
            break
        }
    }

    /// HUD 復原按鈕入口（規格 §3.3：HUD 常駐「復原」；與口頭 undo 共用 performUndo）。
    public func undoRequested() {
        switch internalPhase {
        case .idle:
            return                              // 沒有 session：按鈕不該出現，防禦性忽略
        case .listening, .finishing, .lingering:
            break
        }
        guard ledger.isActive, !ledger.frozen else { return }
        guard coordinator.currentUtteranceLength == 0 else {
            hud.present(.notice("說完這句再復原"))   // 半句進行中，尾端不是可回退狀態
            return
        }
        guard ledger.canUndo else {
            hud.present(.notice("沒有可復原的步驟"))
            return
        }
        performUndo(commandSnapshot: coordinator.snapshotAndBeginNext())   // 空快照：無指令話語可退
    }

    // MARK: - 週期與 ASR 事件

    public func tick(at t: TimeInterval) {
        switch internalPhase {
        case .listening:
            process(actions: segmenter.onTick(at: t))
        case .lingering(let until):
            if t >= until { archiveSession() }
        case .idle, .finishing:
            break
        }
    }

    public func handleTranscript(_ event: TranscriptEvent, at t: TimeInterval) {
        switch internalPhase {
        case .idle, .lingering:
            return
        case .listening, .finishing:
            break   // finishing（排空窗）的尾端 finalized 仍須處理，不能丟
        }
        segmenter.onTranscript(event, at: t)
        switch event {
        case .volatile(let text):
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
        // 相位守衛＝冪等：Esc 已直達 idle、或 readerTask 與測試直呼造成的重複 stream-end，
        // 一律忽略——避免第二次進入把 lingering 重新上膛或重複 flush。
        switch internalPhase {
        case .idle, .lingering:
            return
        case .listening, .finishing:
            break
        }
        process(actions: segmenter.flush())
        if archiveAfterDrain || ledger.frozen || !ledger.isActive {
            archiveAfterDrain = false
            archiveSession()
        } else {
            internalPhase = .lingering(until: t + Self.lingerWindow)
            hud.present(.lingering)
        }
    }

    /// readerTask 專用入口：sid 不符的殘留事件一律丟棄
    func receiveTranscript(_ event: TranscriptEvent, session sid: Int, at t: TimeInterval) {
        guard sid == sessionID else { return }
        handleTranscript(event, at: t)
    }

    func receiveStreamEnd(session sid: Int, at t: TimeInterval) {
        guard sid == sessionID else { return }
        asrStreamEnded(at: t)
    }

    // MARK: - 內部

    private func startListening(mode: ListeningMode, at t: TimeInterval) {
        // 密碼欄位拒絕（規格 §5.3）：不錄音、不送 LLM、不開 session
        let field = fieldReader?.snapshot() ?? FieldContext()
        if field.isSecure {
            ledger.archive()
            internalPhase = .idle
            hud.present(.notice("密碼欄位不聽寫"))
            return
        }
        do {
            readerTask?.cancel()
            let resuming = isLingering && ledger.isActive   // 延續窗內＝同 session 續聽
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            archiveAfterDrain = false
            if !resuming {
                ledger.begin(axAnchor: field.caretLocation)   // UTF-16 單位，僅 AX 路徑使用
            }
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
        audio.stop()                 // audio finish → ASR 排空 → asrStreamEnded 收尾
        internalPhase = .finishing
        hud.present(.hidden)
    }

    private func endSession(at t: TimeInterval) {
        archiveAfterDrain = true     // 60 秒靜音逾時走這裡
        endListening(at: t)
    }

    private func archiveSession() {
        ledger.archive()
        internalPhase = .idle
        hud.present(.hidden)
    }

    private func process(actions: [UtteranceSegmenter.Action]) {
        for action in actions {
            switch action {
            case .utteranceEnded(let raw):
                processUtterance(raw: raw)
            case .sessionTimedOut:
                endSession(at: Date().timeIntervalSinceReferenceDate)
            }
        }
    }

    private func processUtterance(raw: String) {
        let snapshot = coordinator.snapshotAndBeginNext()
        let sessionBefore = ledger.sessionText
        lastIntentTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.intentService.process(utteranceRaw: raw, sessionText: sessionBefore)
            await MainActor.run {
                self.dispatch(outcome, snapshot: snapshot)
            }
        }
    }

    private func dispatch(_ outcome: IntentOutcome, snapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard ledger.isActive else { return }   // 延續窗過期已封存：欄位定稿，安靜放下
        switch outcome {
        case .newContent(let text):
            applyNewContent(text, snapshot: snapshot)
        case .editedSession(let corrected):
            applyCorrection(corrected, commandSnapshot: snapshot)
        case .undo:
            performUndo(commandSnapshot: snapshot)
        case .degraded:
            if ledger.frozen {
                hud.present(.notice("未潤飾"))
            } else {
                keepRaw(snapshot, notice: "未潤飾")
            }
        }
    }

    private func applyNewContent(_ text: String, snapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else { hud.present(.notice("未潤飾")); return }
        do {
            if try coordinator.replaceTail(snapshot, with: text) {
                ledger.commit(ledger.sessionText + text)
            } else {
                keepRaw(snapshot, notice: "未潤飾")
            }
        } catch InserterError.replaceFailedRestored {
            keepRaw(snapshot, notice: "未潤飾")
        } catch InserterError.lostText(let original) {
            clipboardRescue?(original)
            hud.present(.notice("插入失敗，原文已複製到剪貼簿"))
        } catch {
            keepRaw(snapshot, notice: "未潤飾")
        }
    }

    private func applyCorrection(_ corrected: String, commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else { hud.present(.notice("已凍結，未修正")); return }
        do {
            switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                  expectedSessionText: ledger.sessionText,
                                                  with: corrected,
                                                  axAnchor: ledger.axAnchor) {
            case .replaced:
                ledger.commit(corrected)
                hud.present(.notice("已修正"))
            case .tailAdvanced:
                keepRaw(commandSnapshot, notice: "未修正（新內容已接續）")   // 指令話語留在欄位，視為內容鏡像
            case .fieldMismatch:
                ledger.freeze()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            hud.present(.notice("修正失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            clipboardRescue?(original)
            ledger.freeze()
            hud.present(.notice("修正失敗，原文已複製到剪貼簿"))
        } catch {
            ledger.freeze()   // 欄位狀態不明：凍結保平安
            hud.present(.notice("修正失敗"))
        }
    }

    /// 復原上一步（口頭 undo 與 Task 9 的 HUD 按鈕共用）。
    private func performUndo(commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else { hud.present(.notice("已凍結，無法復原")); return }
        guard let step = ledger.undo() else {
            // 沒步驟可回：把指令話語從欄位退掉（它不是內容）
            _ = try? coordinator.replaceTail(commandSnapshot, with: "")
            hud.present(.notice("沒有可復原的步驟"))
            return
        }
        do {
            switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                  expectedSessionText: step.from,
                                                  with: step.to,
                                                  axAnchor: ledger.axAnchor) {
            case .replaced:
                hud.present(.notice("已復原"))
            case .tailAdvanced:
                ledger.commit(step.from)      // 帳本回滾成欄位實況
                keepRaw(commandSnapshot, notice: "未復原（新內容已接續）")
            case .fieldMismatch:
                ledger.commit(step.from)
                ledger.freeze()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            ledger.commit(step.from)
            hud.present(.notice("復原失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            clipboardRescue?(original)
            ledger.freeze()
            hud.present(.notice("復原失敗，原文已複製到剪貼簿"))
        } catch {
            ledger.commit(step.from)
            ledger.freeze()
            hud.present(.notice("復原失敗"))
        }
    }

    /// 原文照留：帳本入帳（欄位鏡像）＋提示
    private func keepRaw(_ snapshot: InsertionCoordinator.UtteranceSnapshot, notice: String) {
        if !snapshot.text.isEmpty {
            ledger.commit(ledger.sessionText + snapshot.text)
        }
        hud.present(.notice(notice))
    }
}
