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

    /// 是否有進行中的 session 工作（listening／排空窗 finishing／延續窗 lingering）。
    /// app 層以此 gate「吞 Esc」與「使用者活動偵測」——若只看 phase，排空窗會被誤判 idle，
    /// 排空期間的手動打字就餵不進 userActivityDetected，在途的潤飾回來會退格吃掉使用者的字。
    public var isEngaged: Bool {
        if case .idle = internalPhase { return false }
        return true
    }

    /// 最近一次意圖處理任務；測試以 await 等待完成
    public private(set) var lastIntentTask: Task<Void, Never>?

    private let audio: any AudioCaptureService
    private let asr: any ASREngine
    private let coordinator: InsertionCoordinator
    private let intentService: any IntentServing
    private let hud: any HUDPresenting
    /// @testable 可見：session 語系覆蓋等 M4 設定的斷言需直接讀取（規格 §4.5）
    let settings: AppSettings
    private var segmenter: UtteranceSegmenter
    /// 鐵律最後手段：原文救不回時交給剪貼簿（app 端接 NSPasteboard）
    private let clipboardRescue: ((String) -> Void)?
    /// 聚焦欄位快照：密碼欄位拒絕聽寫、session 起點取 AX 錨位（規格 §4.6／§5.3）
    private let fieldReader: (any FieldContextProviding)?
    /// 視覺回饋層（規格 §3.5）：Core 只發語意事件，App 端 FeedbackCoordinator 決定畫不畫、畫哪裡
    private let feedback: (any SessionFeedbackPresenting)?

    /// session 帳本（測試經 @testable 檢視）
    private(set) var ledger = SessionLedger()

    private var pressedAt: TimeInterval?
    private var readerTask: Task<Void, Never>?
    /// 60 秒靜音逾時結束：排空後直接封存，不進延續窗（規格 §3.4 逾時＝凍結觸發器）
    private var archiveAfterDrain = false
    /// 遞增 session 序號：readerTask 事件過濾，避免跨 session 污染
    private(set) var sessionID = 0
    /// 在途（已派發、尚未 dispatch 完成）的意圖任務數：undo 按鈕的在途防護（測試經 @testable 檢視）
    private(set) var pendingIntents = 0

    /// 選取即目標（規格 §3.6，M3 設計裁決 1–3）。
    /// selectionPending＝已鎖定選取為替換目標、尚未落地：finalized 全部緩衝不上屏
    /// （打字會蓋掉選取），意圖解析完成才一次替換。首次替換成功即轉回 .tail——
    /// AXInserter 已把游標釘在新 span 尾端，「session 即尾端」恢復成立，後續修正走 M2 機械。
    private enum SessionTarget: Equatable {
        case tail
        case selectionPending(range: FieldContext.SelectedRange, original: String)
    }
    private var sessionTarget: SessionTarget = .tail
    /// 每個 generation 只救援一次剪貼簿：放棄路徑先救「替換結果」（最有價值），
    /// 之後同 generation 的緩衝句 outcome 不得覆蓋它（剪貼簿只有一格）。
    private var lastRescueGeneration: Int?
    /// 熱鍵按下當下的前後文窗口（LLM 語境；tail 與 selection 模式皆用）
    private var capturedContextBefore: String?
    private var capturedContextAfter: String?

    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                coordinator: InsertionCoordinator,
                intent: any IntentServing,
                hud: any HUDPresenting,
                settings: AppSettings,
                segmenter: UtteranceSegmenter = UtteranceSegmenter(),
                clipboardRescue: ((String) -> Void)? = nil,
                fieldReader: (any FieldContextProviding)? = nil,
                feedback: (any SessionFeedbackPresenting)? = nil) {
        self.audio = audio
        self.asr = asr
        self.coordinator = coordinator
        self.intentService = intent
        self.hud = hud
        self.settings = settings
        self.segmenter = segmenter
        self.clipboardRescue = clipboardRescue
        self.fieldReader = fieldReader
        self.feedback = feedback
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
                presentListening(mode: .locked, volatile: "")
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
        if case .finishing = internalPhase {
            // 排空窗中按 Esc＝中止排空並定稿——否則 Esc 被熱鍵層吞掉又無作用，整顆蒸發
            asr.cancel()
            archiveSession()
            return
        }
        guard case .listening = internalPhase else { return }
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        if case .selectionPending = sessionTarget {
            coordinator.clearCurrentUtterance()        // 緩衝：螢幕沒字，不得退格（須在 archiveSession 重置 sessionTarget 前判斷）
        } else {
            try? coordinator.discardCurrentUtterance()
        }
        // Esc 不進延續窗（設計裁決 3）＝提前封存。統一走 archiveSession 清乾淨 session 級狀態
        // （sessionTarget／sessionLanguageOverride，設計裁決 4「archive 時自動清除」）——
        // internalPhase 已設 idle，之後遲到的 stream-end 會被 asrStreamEnded 的相位守衛冪等忽略。
        archiveSession()
    }

    /// 使用者手動活動（打字／滑鼠點擊／切 App；app 端由 HotkeyMonitor 與 NSWorkspace 餵入）。
    /// 聽寫中＝凍結（文字定稿、不再改寫，錄音照常）；延續窗中＝立即封存（設計裁決 2）。
    public func userActivityDetected(at t: TimeInterval) {
        switch internalPhase {
        case .listening, .finishing:
            guard ledger.isActive, !ledger.frozen else { return }
            ledger.freeze()
            feedback?.sessionFrozen()
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
        guard pendingIntents == 0 else {
            // 最後一句的 LLM 仍在途：欄位尾端還掛著未落定的原文，此刻按長度回退必吃錯字（終審 critical）
            hud.present(.notice("說完這句再復原"))
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
                presentListening(mode: mode, volatile: text)
            }
        case .finalized(let text):
            // M2 遺留債：聽寫中焦點切進密碼欄位（Tab、程式切換焦點——滑鼠/鍵盤活動已由凍結涵蓋，
            // 但焦點可以不經這兩者移動）。規格 §5.3：密碼欄位一個字都不能進。硬停整個 session。
            if let field = fieldReader?.snapshot(), field.isSecure {
                abortForSecureField()
                return
            }
            if case .selectionPending = sessionTarget {
                coordinator.accumulateFinalized(text)      // 緩衝：不上屏（M3 設計裁決 1）
            } else {
                do {
                    try coordinator.insertFinalized(text)
                    emitFeedback()                             // 底線延伸至新上屏文字
                } catch {
                    hud.present(.notice("插入失敗"))
                }
            }
        }
    }

    /// 聽寫中的 HUD 狀態依 sessionTarget 分流：選取目標模式顯示 selectionListening
    /// （緩衝不上屏，volatile 是使用者唯一的「聽到了」回饋），一般模式維持 listening。
    private func presentListening(mode: ListeningMode, volatile: String) {
        if case .selectionPending = sessionTarget {
            hud.present(.selectionListening(mode: mode, volatile: volatile))
        } else {
            hud.present(.listening(mode: mode, volatile: volatile))
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
            // 延續窗中改在密碼欄按下：封存前一 session（含清除 session 級語系覆蓋，設計裁決 4）。
            // hud.present 須在 archiveSession（會發 .hidden）之後，否則 notice 被蓋掉。
            archiveSession()
            hud.present(.notice("密碼欄位不聽寫"))
            return
        }
        do {
            readerTask?.cancel()
            let resuming = isLingering && ledger.isActive   // 延續窗內＝同 session 續聽
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            archiveAfterDrain = false
            capturedContextBefore = field.contextBefore
            capturedContextAfter = field.contextAfter
            if !resuming {
                if field.hasSelection, let range = field.selectedRange, let original = field.selectedText {
                    // 選取即目標：anchor＝選取起點，帳本以原選取文字為種子（undo 可回到它）
                    sessionTarget = .selectionPending(range: range, original: original)
                    ledger.begin(axAnchor: range.location, initialText: original)
                } else {
                    sessionTarget = .tail
                    ledger.begin(axAnchor: field.caretLocation)   // UTF-16 單位，僅 AX 路徑使用
                }
            }
            sessionID &+= 1
            let sid = sessionID
            let audioStream = try audio.start()
            let events = asr.start(audio: audioStream, localeIdentifier: settings.asrLocaleIdentifier)
            internalPhase = .listening(mode)
            presentListening(mode: mode, volatile: "")
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
            // 麥克風啟動失敗＝session 夭折：封存不留 idle＋isActive 的孤兒帳本（活動偵測在 idle 下不設防），
            // 並清除 session 級語系覆蓋（設計裁決 4）。notice 須在 archiveSession 發 .hidden 之後。
            archiveSession()
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
        feedback?.sessionEnded()            // 封存：overlay 立即隱藏
        internalPhase = .idle
        hud.present(.hidden)
        sessionTarget = .tail               // 封存即重置目標模式
        settings.sessionLanguageOverride = nil   // per-session 臨時覆蓋隨封存失效（規格 §4.5）
    }

    /// 密碼欄位中途切入：立即停止錄音與辨識、封存 session、不上屏任何後續文字（規格 §5.3）。
    /// 停止順序比照 escapePressed 的「聽寫中」路徑（segmenter.hardReset／asr.cancel／audio.stop），
    /// 僅通知文字不同。hud.present 須在 archiveSession（會發 .hidden）之後，否則 notice 被蓋掉。
    private func abortForSecureField() {
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        archiveSession()
        hud.present(.notice("密碼欄位不聽寫"))
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
        let generation = ledger.generation
        // LLM 目標依 sessionTarget 分流（M3 設計裁決 7）：選取目標模式的 targetText＝原選取文字
        let context: IntentContext
        switch sessionTarget {
        case .tail:
            context = IntentContext(targetKind: .session, targetText: sessionBefore,
                                    contextBefore: capturedContextBefore, contextAfter: capturedContextAfter)
        case .selectionPending(_, let original):
            context = IntentContext(targetKind: .selection, targetText: original,
                                    contextBefore: capturedContextBefore, contextAfter: capturedContextAfter)
        }
        // 這句話是否在 selectionPending 期間被緩衝（從未上屏）——dispatch 時據此走緩衝落地路徑
        let wasBuffered = { if case .selectionPending = sessionTarget { return true }; return false }()
        let previous = lastIntentTask
        pendingIntents += 1
        lastIntentTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.intentService.process(utteranceRaw: raw, context: context)
            // 串行化「套用」：LLM 呼叫照樣平行，但落地依 utterance 順序——
            // 否則第 N 句逾時、第 N+1 句先回時，欄位與帳本會左右對調（終審 finding）。
            _ = await previous?.value
            await MainActor.run {
                self.dispatch(outcome, snapshot: snapshot, sessionBefore: sessionBefore,
                              generation: generation, wasBuffered: wasBuffered)
            }
        }
    }

    private func dispatch(_ outcome: IntentOutcome,
                          snapshot: InsertionCoordinator.UtteranceSnapshot,
                          sessionBefore: String,
                          generation: Int,
                          wasBuffered: Bool) {
        pendingIntents = max(0, pendingIntents - 1)
        // 世代檢查：archive→begin 之後，舊 session 在途的 outcome 一律丟棄——
        // 不能用 sessionID（延續窗 resume 也跳號，會誤殺同 session 的合法在途潤飾）。
        // 但緩衝句（選取模式）的 outcome 不能無聲蒸發：它的原文從未上屏，丟棄＝使用者白說話。
        // 典型時序：說完指令→放開→進延續窗→點別處（延續窗活動＝立即封存）→LLM 此刻才回來。
        // 規格 §3.6「放棄替換，結果進 HUD 供複製」：救進剪貼簿＋提示（實機回報的驗收缺口）。
        guard ledger.isActive, ledger.generation == generation else {
            if wasBuffered, lastRescueGeneration != generation {
                switch outcome {
                case .newContent(let text), .editedSession(let text):
                    lastRescueGeneration = generation
                    clipboardRescue?(text)
                    hud.present(.notice("選取已變動，結果已入剪貼簿"))
                case .undo, .degraded:
                    break                              // 無內容可救，安靜丟棄即可
                }
            }
            return
        }
        // 選取目標尚未落地：pending 期間的所有 outcome 一律走選取分派（首次替換的三種結局）
        if case .selectionPending(let range, let original) = sessionTarget {
            dispatchSelection(outcome, range: range, original: original, commandRaw: snapshot.text)
            return
        }
        // 緩衝句的落地（M3）：這句話在 selectionPending 期間被緩衝（從未上屏），
        // 輪到它時首句已把目標轉回 .tail。既有 tail 機械（replaceTail／keepRaw）都假設
        // 「utterance 原文在螢幕上」，對緩衝句會退格或記帳到不存在的字——一律改走直接落地：
        // newContent＝鍵入接在 span 尾端（游標已釘定）；editedSession 基準必然過期（首句剛改過全文）
        // ＝提示重說；undo 用零長度指令快照（螢幕上沒有指令話語可退）。
        if wasBuffered {
            switch outcome {
            case .newContent(let text):
                // Freeze 契約（規格 §3.4「文字定稿、不再改寫」）：首句替換選取後轉 .tail、帳本仍活著，
                // 此時使用者手動活動會凍結——但緩衝的第二句其 LLM 仍在途。凍結後游標可能已被使用者移走，
                // 若照樣 insertDetached 會把合成鍵入打在使用者現在的游標處（write-after-hands-off）。
                // 比照所有落地路徑（applyNewContent／applyCorrection 等）的 frozen 守衛，改走剪貼簿急救。
                guard !ledger.frozen else {
                    clipboardRescue?(text)
                    hud.present(.notice("已凍結，內容已入剪貼簿"))
                    return
                }
                do {
                    try coordinator.insertDetached(text)
                    ledger.commit(ledger.sessionText + text)
                    emitFeedback()                         // 緩衝後續句落地：底線延伸至新內容
                } catch {
                    clipboardRescue?(text)
                    hud.present(.notice("插入失敗，內容已入剪貼簿"))
                }
            case .editedSession:
                hud.present(.notice("未修正（內容已變動，請再說一次）"))
            case .undo:
                // 零長度、「現時」counter 的指令快照：緩衝句的原快照 counter 是首句替換前取的，
                // 首句的 replaceSelection 已推進 insertCounter，用舊 counter 必吃 tailAdvanced 而
                // 永遠復原失敗。currentTailSnapshot() 零副作用（不動可能正在累積的下一句緩衝），
                // text 為空——螢幕上也確實沒有指令話語可退。
                performUndo(commandSnapshot: coordinator.currentTailSnapshot())
            case .degraded(let reason):
                clipboardRescue?(snapshot.text)
                hud.present(.notice("未處理（\(reason)），轉錄已入剪貼簿"))
            }
            return
        }
        switch outcome {
        case .newContent(let text):
            applyNewContent(text, snapshot: snapshot)
        case .editedSession(let corrected):
            // 基準檢查：corrected 以「呼叫當下」的全文為基礎；期間若有新內容落定＝基準過期，
            // 直接套用會無聲抹掉後來的話（終審 finding）。降級保留指令話語並提示重說。
            guard sessionBefore == ledger.sessionText else {
                keepRaw(snapshot, notice: "未修正（內容已變動，請再說一次）")
                return
            }
            applyCorrection(corrected, commandSnapshot: snapshot)
        case .undo:
            // undo 不需要文字基準——回退目標在「套用時」由帳本現值決定，串行化已保證順序
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
        let old = ledger.sessionText + snapshot.text   // 替換前的欄位鏡像（raw 已上屏）
        do {
            if try coordinator.replaceTail(snapshot, with: text) {
                ledger.commit(ledger.sessionText + text)
                emitFeedback(oldText: old)             // 潤飾異動高亮
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
        let old = ledger.sessionText + commandSnapshot.text   // 修正前全文＋指令話語（皆已上屏）
        do {
            switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                  expectedSessionText: ledger.sessionText,
                                                  with: corrected,
                                                  axAnchor: ledger.axAnchor) {
            case .replaced:
                ledger.commit(corrected)
                hud.present(.notice("已修正"))
                emitFeedback(oldText: old)             // 修正異動高亮
            case .tailAdvanced:
                keepRaw(commandSnapshot, notice: "未修正（新內容已接續）")   // 指令話語留在欄位，視為內容鏡像
            case .fieldMismatch:
                ledger.freeze()
                feedback?.sessionFrozen()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            hud.present(.notice("修正失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            clipboardRescue?(original)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("修正失敗，原文已複製到剪貼簿"))
        } catch {
            ledger.freeze()   // 欄位狀態不明：凍結保平安
            feedback?.sessionFrozen()
            hud.present(.notice("修正失敗"))
        }
    }

    /// 選取 session 的意圖分派（規格 §3.6）。undo 在首句前沒有意義；degraded 時
    /// 不動選取（M3 設計裁決 4：寧可不動不可亂改）——緩衝模式沒有「原文照留」可言，raw 從未上屏。
    private func dispatchSelection(_ outcome: IntentOutcome, range: FieldContext.SelectedRange,
                                   original: String, commandRaw: String) {
        switch outcome {
        case .newContent(let text), .editedSession(let text):
            applySelectionReplacement(text, range: range, original: original)
        case .undo:
            hud.present(.notice("沒有可復原的內容"))
        case .degraded(let reason):
            // M3 設計裁決 4：LLM 失敗不動選取（寧可不動不可亂改），轉錄入剪貼簿
            clipboardRescue?(commandRaw)
            hud.present(.notice("未替換（\(reason)），轉錄已入剪貼簿"))
        }
    }

    /// 一次性替換選取範圍。三種結局（M3 設計裁決 3）：
    /// replaced＝轉常規 session；selectionChanged＝放棄、結果入剪貼簿、封存；
    /// unsupported＝打字蓋選取＋立即凍結（無 AX 不可續改）。
    private func applySelectionReplacement(_ text: String, range: FieldContext.SelectedRange, original: String) {
        guard !ledger.frozen else {                 // 聽寫中手動活動已凍結：選取完整性不明，放棄
            lastRescueGeneration = ledger.generation
            clipboardRescue?(text)
            archiveSession()
            hud.present(.notice("選取已變動，結果已入剪貼簿"))
            return
        }
        switch coordinator.replaceSelection(location: range.location, expected: original, with: text) {
        case .replaced:
            ledger.commit(text)
            sessionTarget = .tail
            hud.present(.notice("已替換選取"))
            emitFeedback(oldText: original)           // 選取替換全 span 高亮
        case .selectionChanged:
            lastRescueGeneration = ledger.generation
            clipboardRescue?(text)
            archiveSession()
            hud.present(.notice("選取已變動，結果已入剪貼簿"))
        case .unsupported:
            do {
                try coordinator.insertDetached(text)
                ledger.commit(text)
                emitFeedback(oldText: original)       // 高亮先發（此刻仍 active），再凍結
                ledger.freeze()
                feedback?.sessionFrozen()             // 立即凍結：無 AX 不可續改
                sessionTarget = .tail
                hud.present(.notice("已取代選取（此 App 不支援後續語音修正）"))
            } catch {
                lastRescueGeneration = ledger.generation
                clipboardRescue?(text)
                archiveSession()
                hud.present(.notice("無法替換，結果已入剪貼簿"))
            }
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
                emitFeedback(oldText: step.from)      // 復原後底線罩回舊版
            case .tailAdvanced:
                ledger.commit(step.from)      // 帳本回滾成欄位實況
                keepRaw(commandSnapshot, notice: "未復原（新內容已接續）")
            case .fieldMismatch:
                ledger.commit(step.from)
                ledger.freeze()
                feedback?.sessionFrozen()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            ledger.commit(step.from)
            hud.present(.notice("復原失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            clipboardRescue?(original)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("復原失敗，原文已複製到剪貼簿"))
        } catch {
            ledger.commit(step.from)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("復原失敗"))
        }
    }

    /// 原文照留：帳本入帳（欄位鏡像）＋提示
    private func keepRaw(_ snapshot: InsertionCoordinator.UtteranceSnapshot, notice: String) {
        if !snapshot.text.isEmpty {
            ledger.commit(ledger.sessionText + snapshot.text)
        }
        hud.present(.notice(notice))
        emitFeedback()
    }

    /// 底線＝session 已定文字＋進行中 utterance；異動時附 highlight 與舊文供降級 diff。
    private func emitFeedback(oldText: String? = nil) {
        guard ledger.isActive else { return }
        let text = ledger.sessionText + coordinator.currentUtteranceText
        var highlight: SpanUTF16? = nil
        if let old = oldText {
            highlight = InlineDiff.changedSpanUTF16(old: old, new: text)
        }
        feedback?.sessionUpdated(FeedbackUpdate(anchor: ledger.axAnchor, text: text,
                                                highlight: highlight, oldText: oldText))
    }
}
