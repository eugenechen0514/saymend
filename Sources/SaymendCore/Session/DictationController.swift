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
    private let fieldReader: any FieldContextProviding
    /// 視覺回饋層（規格 §3.5）：Core 只發語意事件，App 端 FeedbackCoordinator 決定畫不畫、畫哪裡
    private let feedback: (any SessionFeedbackPresenting)?
    /// 聽寫歷史（規格 §4.9）：nil＝不記錄。寫入失敗不得影響聽寫主流程。
    private let history: (any HistoryRecording)?
    /// OCR 備援上下文（規格 §4.7）：AX 讀不到前後文時的非同步截圖辨識，App 端注入；nil＝停用。
    private let contextOCR: (() async -> String?)?
    /// 時間來源（歷史記錄時戳）；測試可注入固定時鐘。
    private let now: () -> Date

    /// session 帳本（測試經 @testable 檢視）
    private(set) var ledger = SessionLedger()
    /// 本聽寫階段目前實際掌控的欄位文字鏡像，包含已閉合但 intent 尚在途的 raw。
    /// `ledger.sessionText` 只記已落定結果，無法單獨支撐 issue #21 的全階段 Esc。
    private var displayedSessionText = ""
    /// 舊測試專用：保留 issue #21 前的 keystroke polish harness，避免非欄位安全測試
    /// 被迫改驗 AX 實作。production 永遠 false；資料安全 tests 使用 stateful verified field。
    private var allowsUnverifiedWritesForTesting = false
    private var pressedAt: TimeInterval?
    private var readerTask: Task<Void, Never>?
    /// 60 秒靜音逾時結束：排空後直接封存，不進延續窗（規格 §3.4 逾時＝凍結觸發器）
    private var archiveAfterDrain = false
    /// issue #18：本 session 是否收過「沒偵測到語音」示警。收尾時據此決定要不要發 notice。
    private var sawNoSpeechWarning = false
    /// issue #18：本 session 是否辨識出過任何文字。示警的解除訊號。
    private var sawTextThisSession = false

    /// 收尾時的提示文案。兩條出路都給：物理上的（靠近麥克風）與設定上的（調低門檻）。
    /// 只寫「沒偵測到語音」而不給方向的話，使用者只會重試一次同樣的動作然後放棄。
    public static let noSpeechNotice =
        "沒偵測到語音。麥克風可能太遠，或到「設定 › 進階：串流參數」調低靜音門檻"
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
    /// 使用者明確按 Esc 的 generation：其 late selection outcome 是「已取消」，不得再救進 clipboard。
    /// 與 selectionChanged／延續窗外部活動的 abandonment 分開，後兩者仍維持既有 rescue 契約。
    private var cancelledGenerations: Set<Int> = []
    /// 熱鍵按下當下的前後文窗口（LLM 語境；tail 與 selection 模式皆用）
    private var capturedContextBefore: String?
    private var capturedContextAfter: String?
    /// 進行中 session 的歷史 id（nil＝未記錄，如歷史關閉或密碼欄位）
    private var historySessionID: String?
    /// 熱鍵按下當下的前景 App 名稱（第 7 層動態上下文，規格 §4.7）
    private var capturedFrontAppName: String?
    /// OCR 備援落地的螢幕參考文字（趕上哪句算哪句——M4 設計裁決 5）
    private var capturedOCRText: String?
    /// internal 供測試 await（OCR 非同步落地，趕上哪句算哪句——M4 設計裁決 5）
    private(set) var ocrTask: Task<Void, Never>?

    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                coordinator: InsertionCoordinator,
                intent: any IntentServing,
                hud: any HUDPresenting,
                settings: AppSettings,
                segmenter: UtteranceSegmenter = UtteranceSegmenter(),
                clipboardRescue: ((String) -> Void)? = nil,
                fieldReader: any FieldContextProviding,
                feedback: (any SessionFeedbackPresenting)? = nil,
                history: (any HistoryRecording)? = nil,
                contextOCR: (() async -> String?)? = nil,
                now: @escaping () -> Date = Date.init) {
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
        self.history = history
        self.contextOCR = contextOCR
        self.now = now
    }

    /// @testable-only convention seam；production source 不得呼叫。
    func allowUnverifiedWritesForTesting() {
        allowsUnverifiedWritesForTesting = true
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
            cancelledGenerations.insert(ledger.generation)
            archiveSession()                // 延續窗中按 Esc＝提前定稿（吞掉 Esc 由熱鍵層處理）
            return
        }
        if case .finishing = internalPhase {
            // 排空窗中按 Esc＝中止排空並定稿——這兩個 phase 沿用既有「定稿」契約，不做退字。
            cancelledGenerations.insert(ledger.generation)
            asr.cancel()
            archiveSession()
            return
        }
        guard case .listening = internalPhase else { return }
        let cancelledGeneration = ledger.generation
        segmenter.hardReset()
        asr.cancel()
        audio.stop()

        var historyFinalOverride: String?
        var failureNotice: String?
        if case .selectionPending = sessionTarget {
            coordinator.clearCurrentUtterance()        // 緩衝：螢幕沒字，不得退格（須在 archiveSession 重置 sessionTarget 前判斷）
        } else if !ledger.frozen || settings.escapeRetractsFrozenSession {
            let currentField = fieldReader.snapshot()
            // 即使使用者 opt-in 允許凍結後退字，secure field 仍是不可覆蓋的絕對 veto。
            if currentField.isSecure {
                if currentField.fieldIdentity != ledger.fieldIdentity {
                    fieldReader.releaseFieldIdentity(currentField.fieldIdentity)
                }
                failureNotice = "目前是密碼欄位，未退字"
            } else if ledger.fieldIdentity == nil {
                fieldReader.releaseFieldIdentity(currentField.fieldIdentity)
                failureNotice = "無法驗證原欄位，未退字"
            } else if let expectedField = ledger.fieldIdentity,
                      currentField.fieldIdentity != expectedField {
                fieldReader.releaseFieldIdentity(currentField.fieldIdentity)
                failureNotice = "欄位已變動，未退字"
            } else if !coordinator.canVerifySessionRange(
                axAnchor: ledger.axAnchor, fieldIdentity: ledger.fieldIdentity) {
                // Whole-session deletion 比舊的 current-utterance Backspace 風險大得多：不論 frozen 與否，
                // 缺 identity-bound AX range 都 fail closed，不能把 mirror 長度盲送到目前 focused field。
                failureNotice = ledger.frozen
                    ? "已凍結且無法驗證原欄位，未退字"
                    : "無法驗證原欄位，未退字"
            } else {
                let retained = ledger.escapeRetractionTarget(
                    includingPolishedText: settings.escapeRetractsPolishedText)
                switch coordinator.retractSession(expectedScreenText: displayedSessionText,
                                                  to: retained,
                                                  axAnchor: ledger.axAnchor,
                                                  fieldIdentity: ledger.fieldIdentity) {
                case .retracted:
                    displayedSessionText = retained
                    historyFinalOverride = retained
                case .fieldMismatch:
                    failureNotice = "欄位已變動，未退字"
                }
            }
        }
        cancelledGenerations.insert(cancelledGeneration)
        // Esc 不進延續窗（設計裁決 3）＝提前封存。成功退字時 history 以實際 retained text 收尾，
        // 不把已從欄位撤回的文字誤標為 finalText。失敗則保留原 ledger mirror 供回查。
        archiveSession(finalTextOverride: historyFinalOverride)
        if let failureNotice { hud.present(.notice(failureNotice)) }
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
        // **示警不進斷句器**（issue #18）：斷句器對任何辨識事件都會重置靜音計時，
        // 而本事件與「有沒有人在講話」無關。放進去會讓靜音間隔延後到期、話語晚閉合，
        // 方向上正是 #14 最怕的那種失效。這裡提前 return，走在 segmenter 之前。
        if case .noSpeechDetected = event {
            sawNoSpeechWarning = true
            if case .listening(let mode) = internalPhase {
                hud.present(.noSpeechDetected(mode: mode))
            }
            return
        }
        releaseNoSpeechWarningIfTextArrived(event)
        segmenter.onTranscript(event, at: t)
        switch event {
        case .volatile(let text):
            if case .listening(let mode) = internalPhase {
                presentListening(mode: mode, volatile: text)
            }
        case .finalized(let text, let quality):
            // M2 遺留債：聽寫中焦點切進密碼欄位（Tab、程式切換焦點——滑鼠/鍵盤活動已由凍結涵蓋，
            // 但焦點可以不經這兩者移動）。規格 §5.3：密碼欄位一個字都不能進。硬停整個 session。
            let focusedField = fieldReader.snapshot()
            if focusedField.isSecure {
                if focusedField.fieldIdentity != ledger.fieldIdentity {
                    fieldReader.releaseFieldIdentity(focusedField.fieldIdentity)
                }
                abortForSecureField()
                return
            }
            // **必須在密碼欄位守衛之後**（issue #10）：診斷列會把定稿文字原樣落進資料庫，
            // 寫在守衛之前等於在密碼欄位裡留下一份使用者說的話。
            recordASRDiagnostic(text: text, quality: quality)
            if case .selectionPending = sessionTarget {
                coordinator.accumulateFinalized(text)      // 緩衝：不上屏（M3 設計裁決 1）
            } else {
                // Session 起始有 AX identity 時，每次 raw 寫入前都重驗目前 focused field。
                // 程式化切焦點不一定產生 userActivity；只靠 freeze event 會把文字打進另一欄。
                if !allowsUnverifiedWritesForTesting {
                    let current = focusedField
                    guard let expectedField = ledger.fieldIdentity,
                          current.fieldIdentity == expectedField else {
                        if current.fieldIdentity != ledger.fieldIdentity {
                            fieldReader.releaseFieldIdentity(current.fieldIdentity)
                        }
                        recordInsertEvent(kind: "insertSkipped", classification: "fieldIdentityMismatch",
                                          utteranceText: text)
                        if !ledger.frozen {
                            ledger.freeze()
                            feedback?.sessionFrozen()
                        }
                        clipboardRescue?(text)
                        hud.present(.notice("欄位已切換，內容已入剪貼簿"))
                        return
                    }
                }
                // 凍結守衛（合併阻擋級 finding）：raw 插入路徑先前缺這道守衛，其他每條落地路徑都有
                // （applyNewContent:599／wasBuffered:545／applyCorrection 等）。freeze() 只設 frozen 旗標、
                // 不動 internalPhase，而本函式開頭的相位守衛放 .finishing 通過。Whisper 遠端是批次上傳：
                // 放開熱鍵後 phase 為 .finishing、上傳最長達 timeout（120s），期間使用者切 App／點別欄位
                // 會觸發 freeze——稍後到達的 .finalized 若照樣 insertFinalized，整段辨識會被合成鍵入／貼上
                // 打進「目前聚焦的別 App」。SpeechAnalyzer 的 <1s 窗口可忽略，Whisper 讓它常態化。
                // raw 尚未上屏（不同於 applyNewContent 的 raw 已在螢幕上），故比照 wasBuffered(:545) 走剪貼簿
                // 急救＋記診斷事件（applyNewContent 的 insertSkipped/frozen）。segmenter 殘留不在此清除——
                // 與其他每條路徑一致，交由下游 polish 的凍結守衛（applyNewContent:599／applyCorrection:647）
                // 統一處理，不特別短路。別讓使用者白說話、也別打進錯 App。
                guard !ledger.frozen else {
                    recordInsertEvent(kind: "insertSkipped", classification: "frozen", utteranceText: text)
                    clipboardRescue?(text)
                    hud.present(.notice("已凍結，內容已入剪貼簿"))
                    return
                }
                do {
                    try coordinator.insertFinalized(text)
                    displayedSessionText += text
                    emitFeedback()                             // 底線延伸至新上屏文字
                } catch {
                    recordInsertEvent(kind: "insertFailed", classification: "rawInsertFailed",
                                      utteranceText: text, detail: "\(error)")
                    clipboardRescue?(text)
                    hud.present(.notice("插入失敗，內容已入剪貼簿"))
                }
            }
        case .transcribing:
            hud.present(.transcribing)          // 批次引擎等待結果中；不動 ledger、不動欄位
        case .loadingModel:
            hud.present(.loadingModel)          // 本機模型載入中（首次較久）；同樣不動 ledger、不動欄位
        case .failed(let reason):
            handleASRFailure(reason: reason)
        case .noSpeechDetected:
            break   // 前方已提前 return（刻意不進 segmenter），此處不可達；列出僅為窮盡性
        }
    }

    /// 辨識品質診斷（issue #10）：記在**定稿當下**，不等話語閉合、不等語言模型回應。
    ///
    /// 錨在這裡是被實機資料逼出來的：id=116 那筆幻覺（`请不吝点赞 订阅 转发…`）在歷史裡
    /// 只留下一列 `insertSkipped/frozen`，沒有 outcome 列——潤飾回來時 session 已封存、
    /// `historySessionID` 已清空。診斷若掛在話語或 outcome 上，**最需要的樣本恰好記不到**。
    ///
    /// 沒有品質資料就不寫列：系統內建引擎與遠端 Whisper 都給不出這兩個數字，
    /// 寫一堆空值只會在統計時混進假樣本。
    private func recordASRDiagnostic(text: String, quality: TranscriptQuality?) {
        guard let quality, settings.historyEnabled, let hid = historySessionID else { return }
        history?.recordASRDiagnostic(.init(sessionID: hid, at: now(), finalizedText: text,
                                           minAvgLogprob: Double(quality.minAvgLogprob),
                                           maxCompressionRatio: Double(quality.maxCompressionRatio),
                                           segmentCount: quality.segmentCount))
    }

    /// 辨識出任何文字＝確實偵測到語音，「沒偵測到語音」示警就此解除（issue #18）。
    ///
    /// 用「有沒有辨識出文字」而非 `ledger.sessionText.isEmpty` 判斷：帳本要等潤飾回來才提交，
    /// 而潤飾是非同步的——收尾時很可能還在途中、帳本仍是空的，會誤判成「整段沒講話」。
    ///
    /// **HUD 也必須在這裡復原，不能只靠 `.volatile` 分支。** `.finalized` 分支不碰 HUD，
    /// 所以文字若以定稿形式回來（尾端補發就是這條路），畫面會整段停在橘色示警，
    /// 而 notice 又因為「有產出文字」而不發——沒有任何機制會糾正它。
    /// 只在示警確實還掛在畫面上時才復原，否則每筆定稿都會把正在顯示的暫時文字清掉。
    private func releaseNoSpeechWarningIfTextArrived(_ event: TranscriptEvent) {
        let text: String
        switch event {
        case .finalized(let t, _), .volatile(let t): text = t
        default: return
        }
        guard !text.isEmpty else { return }
        let warningOnScreen = sawNoSpeechWarning && !sawTextThisSession
        sawTextThisSession = true
        guard warningOnScreen, case .listening(let mode) = internalPhase else { return }
        presentListening(mode: mode, volatile: "")
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
        // issue #18：整段沒偵測到語音且確實一個字都沒產出——發提示**取代**延續窗。
        //
        // 取代而非疊加有兩個理由。語意上：沒偵測到語音就沒有東西可修正，延續窗本來就沒意義。
        // 實務上：M8 code review 第 4 個 finding 記載「notice 會被緊接的 lingering 蓋掉」，
        // 走這條路就不會有那個坑。
        //
        // 「一個字都沒產出」同時**就是示警的解除機制**——使用者在示警之後才開口時文字會產出，
        // 這裡自然不發，不需要另一個解除事件。notice 必須排在 archiveSession 之後，
        // 否則會被它發的 .hidden 蓋掉。
        if sawNoSpeechWarning, !sawTextThisSession {
            archiveAfterDrain = false
            archiveSession()
            hud.present(.notice(Self.noSpeechNotice))
            return
        }
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
        var field = fieldReader.snapshot()
        if field.isSecure {
            // 延續窗中改在密碼欄按下：封存前一 session（含清除 session 級語系覆蓋，設計裁決 4）。
            // hud.present 須在 archiveSession（會發 .hidden）之後，否則 notice 被蓋掉。
            archiveSession()
            fieldReader.releaseFieldIdentity(field.fieldIdentity) // secure snapshot 未被 ledger 採用
            hud.present(.notice("密碼欄位不聽寫"))
            return
        }
        // 延續窗只有同一個 AX element 才能 resume。程式化切焦點不一定產生鍵鼠活動；
        // identity 不同／不可驗證時先封存舊 session，這次按鍵改開新 session。
        let mustArchiveOldSession = (isLingering && ledger.isActive
                                     && (ledger.fieldIdentity == nil
                                         || field.fieldIdentity != ledger.fieldIdentity))
            || (!isLingering && ledger.isActive)
        if mustArchiveOldSession {
            // finishing 同欄也必須重抓：第一次 snapshot 拿到的 token 會被 archive release。
            archiveSession()
            fieldReader.releaseFieldIdentity(field.fieldIdentity) // 第一份 snapshot 未被新 ledger 採用
            field = fieldReader.snapshot()
            if field.isSecure {
                fieldReader.releaseFieldIdentity(field.fieldIdentity)
                hud.present(.notice("密碼欄位不聽寫"))
                return
            }
        }
        do {
            readerTask?.cancel()
            let resuming = isLingering && ledger.isActive   // 延續窗內、同 field＝同 session 續聽
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            archiveAfterDrain = false
            sawNoSpeechWarning = false
            sawTextThisSession = false
            capturedContextBefore = field.contextBefore
            capturedContextAfter = field.contextAfter
            if !resuming {
                if field.hasSelection, let range = field.selectedRange, let original = field.selectedText {
                    // 選取即目標：anchor＝選取起點，帳本以原選取文字為種子（undo 可回到它）
                    sessionTarget = .selectionPending(range: range, original: original)
                    ledger.begin(axAnchor: range.location, fieldIdentity: field.fieldIdentity,
                                 initialText: original)
                    displayedSessionText = original
                } else {
                    sessionTarget = .tail
                    ledger.begin(axAnchor: field.caretLocation,
                                 fieldIdentity: field.fieldIdentity) // UTF-16 anchor＋原 field identity
                    displayedSessionText = ""
                }
                capturedFrontAppName = field.frontAppName
                if settings.historyEnabled, let history {
                    let hid = UUID().uuidString
                    historySessionID = hid
                    let kind = { if case .selectionPending = sessionTarget { return "selection" }; return "tail" }()
                    history.beginSession(.init(id: hid, startedAt: now(),
                                               appBundleID: field.frontAppBundleID,
                                               appName: field.frontAppName,
                                               targetKind: kind, finalText: nil))
                }
                // OCR 備援（規格 §4.7 降級序：AX 讀得到就不動用）；非同步，結果趕上哪句算哪句。
                capturedOCRText = nil
                ocrTask?.cancel()
                ocrTask = nil
                if field.contextBefore == nil, field.contextAfter == nil, !field.isSecure,
                   let contextOCR {
                    ocrTask = Task { [weak self] in
                        let text = await contextOCR()
                        await MainActor.run { self?.capturedOCRText = text }
                    }
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

    private func archiveSession(finalTextOverride: String? = nil) {
        // 定稿入史（規格 §4.9）：ledger.archive() 會清空 sessionText，故先抓最終全文。
        // issue #21：Esc 成功撤回後以實際 retained text 覆寫，避免歷史把已刪內容標成 final。
        if let hid = historySessionID {
            let final = finalTextOverride ?? ledger.sessionText
            history?.finishSession(id: hid, finalText: final.isEmpty ? nil : final)
            historySessionID = nil
        }
        ocrTask?.cancel()
        ocrTask = nil
        capturedOCRText = nil
        fieldReader.releaseFieldIdentity(ledger.fieldIdentity)
        ledger.archive()
        displayedSessionText = ""
        feedback?.sessionEnded()            // 封存：overlay 立即隱藏
        internalPhase = .idle
        hud.present(.hidden)
        sessionTarget = .tail               // 封存即重置目標模式
        settings.sessionLanguageOverride = nil   // per-session 臨時覆蓋隨封存失效（規格 §4.5）
        settings.sessionCoreModeID = nil     // per-session 核心模式覆蓋隨封存失效（規格 §3.2）
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

    /// ASR 辨識失敗（M8 spec §5.3）：不上屏、不入帳本，且必須停錄音＋封存＋最後才通知。
    /// 順序逐字比照 abortForSecureField，三個坑缺一不可：
    /// ① 不封存 → asrStreamEnded 會進 lingering，跳出空的「可修正／復原」窗；
    /// ② 不 audio.stop() → archiveSession 把 phase 設 idle 後，hotkeyReleased 會落入
    ///    `case .idle, .finishing, .lingering: break`，endListening 的 stop 永不執行＝麥克風漏開；
    /// ③ notice 早於 archiveSession → 被其發出的 .hidden 蓋掉（HUDWindowController 開頭 hideTask.cancel）。
    private func handleASRFailure(reason: String) {
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        archiveSession()
        hud.present(.notice("辨識失敗（\(reason)）"))
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
                                    contextBefore: capturedContextBefore, contextAfter: capturedContextAfter,
                                    frontAppName: capturedFrontAppName, ocrText: capturedOCRText)
        case .selectionPending(_, let original):
            context = IntentContext(targetKind: .selection, targetText: original,
                                    contextBefore: capturedContextBefore, contextAfter: capturedContextAfter,
                                    frontAppName: capturedFrontAppName, ocrText: capturedOCRText)
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
        // 歷史記錄（規格 §4.9）：丟棄的 outcome 也入史——回查除錯正是要看見被丟棄的（守衛之前記）。
        if settings.historyEnabled, let hid = historySessionID {
            history?.recordExchange(.init(sessionID: hid, at: now(),
                                          utteranceRaw: snapshot.text.isEmpty ? sessionBefore : snapshot.text,
                                          outcomeKind: outcome.historyKind, outcomeText: outcome.historyText))
        }
        // 世代檢查：archive→begin 之後，舊 session 在途的 outcome 一律丟棄——
        // 不能用 sessionID（延續窗 resume 也跳號，會誤殺同 session 的合法在途潤飾）。
        // 但緩衝句（選取模式）的 outcome 不能無聲蒸發：它的原文從未上屏，丟棄＝使用者白說話。
        // 典型時序：說完指令→放開→進延續窗→點別處（延續窗活動＝立即封存）→LLM 此刻才回來。
        // 規格 §3.6「放棄替換，結果進 HUD 供複製」：救進剪貼簿＋提示（實機回報的驗收缺口）。
        guard ledger.isActive, ledger.generation == generation else {
            if wasBuffered, !cancelledGenerations.contains(generation), lastRescueGeneration != generation {
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
                    switch try coordinator.replaceSession(
                        commandSnapshot: coordinator.currentTailSnapshot(),
                        expectedSessionText: ledger.sessionText,
                        with: ledger.sessionText + text,
                        axAnchor: ledger.axAnchor,
                        fieldIdentity: ledger.fieldIdentity
                    ) {
                    case .replaced:
                        displayedSessionText += text
                        ledger.appendPolished(text)
                        emitFeedback()                     // identity-bound AX 追加後才延伸底線
                    case .tailAdvanced, .fieldMismatch:
                        invalidateDisplayedSessionMirror()
                        clipboardRescue?(text)
                        hud.present(.notice("欄位已切換，內容已入剪貼簿"))
                    }
                } catch {
                    invalidateDisplayedSessionMirror()
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
                recordInsertEvent(kind: "insertSkipped", classification: "basisExpired",
                                  utteranceText: snapshot.text)
                keepRaw(snapshot, notice: "未修正（內容已變動，請再說一次）")
                return
            }
            applyCorrection(corrected, commandSnapshot: snapshot)
        case .undo:
            // undo 不需要文字基準——回退目標在「套用時」由帳本現值決定，串行化已保證順序
            performUndo(commandSnapshot: snapshot)
        case .degraded(let reason):
            // M7 §3.4：reason 是真因（逾時 N 秒／HTTP N／無法連線…），不可再吞掉
            if ledger.frozen {
                hud.present(.notice("未潤飾（\(reason)）"))
            } else {
                keepRawWithoutVersion(snapshot, notice: "未潤飾（\(reason)）")   // A4：mirror 但不建版本
            }
        }
    }

    private func applyNewContent(_ text: String, snapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else {
            recordInsertEvent(kind: "insertSkipped", classification: "frozen", utteranceText: snapshot.text)
            hud.present(.notice(insertSkipNotice(.frozen)))
            return
        }
        if allowsUnverifiedWritesForTesting {
            applyNewContentUnverifiedForTesting(text, snapshot: snapshot)
            return
        }
        let current = fieldReader.snapshot()
        guard let expectedField = ledger.fieldIdentity,
              current.fieldIdentity == expectedField else {
            if current.fieldIdentity != ledger.fieldIdentity {
                fieldReader.releaseFieldIdentity(current.fieldIdentity)
            }
            recordInsertEvent(kind: "insertSkipped", classification: "fieldIdentityMismatch",
                              utteranceText: snapshot.text)
            keepRaw(snapshot, notice: "欄位已切換，保留原文")
            invalidateDisplayedSessionMirror()
            return
        }
        // 替換前的欄位鏡像（raw 已上屏）。必須含 currentUtteranceText——回收路徑走到這裡時，
        // 下一句的原文已經落在螢幕上；漏掉它會讓 diff 把使用者還沒被碰的那句也框成「剛改動」。
        // 一般路徑的 currentUtteranceText 是空的，加了不影響。
        let old = ledger.sessionText + snapshot.text + coordinator.currentUtteranceText
        let location = ledger.axAnchor.map { $0 + ledger.sessionText.utf16.count }
        let replacement = location.map {
            coordinator.replaceTailVerified(snapshot, at: $0, with: text,
                                            fieldIdentity: ledger.fieldIdentity)
        } ?? .fieldMismatch
        switch replacement {
        case .replaced:
            guard replaceDisplayedUtterance(snapshot, after: ledger.sessionText, with: text) else {
                invalidateDisplayedSessionMirror()
                hud.present(.notice("欄位鏡像失效，本段停止修正"))
                return
            }
            ledger.appendPolished(text)
            emitFeedback(oldText: old)                 // 潤飾異動高亮
        case .tailAdvanced:
            if !recoverStaleTail(text, snapshot: snapshot, previousMirror: old) {
                recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                                  utteranceText: snapshot.text)
                keepRaw(snapshot, notice: insertSkipNotice(.tailAdvanced))
            }
        case .fieldMismatch:
            recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                              utteranceText: snapshot.text)
            keepRaw(snapshot, notice: "欄位已切換或無法驗證，保留原文")
            invalidateDisplayedSessionMirror()
        }
    }

    /// 舊測試 harness 專用；production 不可達。行為保持原本的 counter＋keystroke 路徑，
    /// 讓 intent/history 測試不必假裝自己在驗 AX field safety。
    private func applyNewContentUnverifiedForTesting(
        _ text: String,
        snapshot: InsertionCoordinator.UtteranceSnapshot
    ) {
        let old = ledger.sessionText + snapshot.text + coordinator.currentUtteranceText
        do {
            if try coordinator.replaceTail(snapshot, with: text) {
                guard replaceDisplayedUtterance(snapshot, after: ledger.sessionText, with: text) else {
                    invalidateDisplayedSessionMirror(); return
                }
                ledger.appendPolished(text)
                emitFeedback(oldText: old)
            } else {
                recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                                  utteranceText: snapshot.text)
                keepRaw(snapshot, notice: insertSkipNotice(.tailAdvanced))
            }
        } catch InserterError.replaceFailedRestored {
            recordInsertEvent(kind: "insertFailed", classification: "replaceFailedRestored",
                              utteranceText: snapshot.text)
            keepRaw(snapshot, notice: insertSkipNotice(.writeFailed))
        } catch InserterError.lostText(let original) {
            recordInsertEvent(kind: "insertFailed", classification: "lostText",
                              utteranceText: snapshot.text)
            _ = replaceDisplayedUtterance(snapshot, after: ledger.sessionText, with: "")
            clipboardRescue?(original)
            hud.present(.notice("插入失敗，原文已複製到剪貼簿"))
        } catch {
            recordInsertEvent(kind: "insertFailed", classification: "unknown",
                              utteranceText: snapshot.text, detail: "\(error)")
            keepRaw(snapshot, notice: insertSkipNotice(.unknown))
        }
    }

    private func applyCorrection(_ corrected: String, commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else {
            recordInsertEvent(kind: "insertSkipped", classification: "frozen",
                              utteranceText: commandSnapshot.text)
            hud.present(.notice("已凍結，未修正")); return
        }
        let old = ledger.sessionText + commandSnapshot.text   // 修正前全文＋指令話語（皆已上屏）
        do {
            switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                  expectedSessionText: ledger.sessionText,
                                                  with: corrected,
                                                  axAnchor: ledger.axAnchor,
                                                  fieldIdentity: ledger.fieldIdentity) {
            case .replaced:
                displayedSessionText = corrected
                ledger.commit(corrected)
                hud.present(.notice("已修正"))
                emitFeedback(oldText: old)             // 修正異動高亮
            case .tailAdvanced:
                recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                                  utteranceText: commandSnapshot.text)
                keepRaw(commandSnapshot, notice: "未修正（新內容已接續）")   // 指令話語留在欄位，視為內容鏡像
            case .fieldMismatch:
                recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                                  utteranceText: commandSnapshot.text)
                ledger.freeze()
                feedback?.sessionFrozen()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            recordInsertEvent(kind: "insertFailed", classification: "replaceFailedRestored",
                              utteranceText: commandSnapshot.text)
            displayedSessionText = ledger.sessionText // command 已先刪，只有原 session 被回復
            hud.present(.notice("修正失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            recordInsertEvent(kind: "insertFailed", classification: "lostText",
                              utteranceText: commandSnapshot.text)
            displayedSessionText = ""              // command 與 controlled session 都已不在可信欄位鏡像
            clipboardRescue?(original)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("修正失敗，原文已複製到剪貼簿"))
        } catch {
            recordInsertEvent(kind: "insertFailed", classification: "unknown",
                              utteranceText: commandSnapshot.text, detail: "\(error)")
            displayedSessionText = "" // 欄位狀態不明：不得讓 frozen opt-in 依過期 mirror 盲退
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
            recordInsertEvent(kind: "insertSkipped", classification: "frozen", utteranceText: text)
            lastRescueGeneration = ledger.generation
            clipboardRescue?(text)
            archiveSession()
            hud.present(.notice("選取已變動，結果已入剪貼簿"))
            return
        }
        switch coordinator.replaceSelection(location: range.location, expected: original, with: text,
                                            fieldIdentity: ledger.fieldIdentity) {
        case .replaced:
            displayedSessionText = text
            ledger.commit(text)
            sessionTarget = .tail
            hud.present(.notice("已替換選取"))
            emitFeedback(oldText: original)           // 選取替換全 span 高亮
        case .selectionChanged:
            recordInsertEvent(kind: "insertSkipped", classification: "selectionChanged", utteranceText: text)
            lastRescueGeneration = ledger.generation
            clipboardRescue?(text)
            archiveSession()
            hud.present(.notice("選取已變動，結果已入剪貼簿"))
        case .unsupported:
            do {
                try coordinator.insertDetached(text)
                displayedSessionText = text
                ledger.commit(text)
                emitFeedback(oldText: original)       // 高亮先發（此刻仍 active），再凍結
                ledger.freeze()
                feedback?.sessionFrozen()             // 立即凍結：無 AX 不可續改
                sessionTarget = .tail
                hud.present(.notice("已取代選取（此 App 不支援後續語音修正）"))
            } catch {
                recordInsertEvent(kind: "insertFailed", classification: "detachedInsertFailed",
                                  utteranceText: text, detail: "\(error)")
                lastRescueGeneration = ledger.generation
                clipboardRescue?(text)
                archiveSession()
                hud.present(.notice("無法替換，結果已入剪貼簿"))
            }
        }
    }

    /// 復原上一步（口頭 undo 與 Task 9 的 HUD 按鈕共用）。
    private func performUndo(commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else {
            recordInsertEvent(kind: "insertSkipped", classification: "frozen",
                              utteranceText: commandSnapshot.text)
            hud.present(.notice("已凍結，無法復原")); return
        }
        guard let step = ledger.undo() else {
            // 沒步驟可回：只有 identity-bound AX 能安全移除指令。無 AX 時保留 raw；tail 已前進
            // 時同樣推進 ledger。漏帳會讓下一句 mirror splice 從錯誤 offset 開始（issue #21 HIGH）。
            guard coordinator.canVerifySessionRange(axAnchor: ledger.axAnchor,
                                                     fieldIdentity: ledger.fieldIdentity) else {
                keepRaw(commandSnapshot, notice: "沒有可復原的步驟")
                return
            }
            do {
                switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                      expectedSessionText: ledger.sessionText,
                                                      with: ledger.sessionText,
                                                      axAnchor: ledger.axAnchor,
                                                      fieldIdentity: ledger.fieldIdentity) {
                case .replaced:
                    guard replaceDisplayedUtterance(commandSnapshot, after: ledger.sessionText,
                                                    with: "") else {
                        invalidateDisplayedSessionMirror()
                        hud.present(.notice("欄位鏡像失效，本段停止修正"))
                        return
                    }
                    hud.present(.notice("沒有可復原的步驟"))
                case .tailAdvanced:
                    keepRaw(commandSnapshot, notice: "沒有可復原的步驟")
                case .fieldMismatch:
                    if !commandSnapshot.text.isEmpty {
                        ledger.commitRaw(ledger.sessionText + commandSnapshot.text)
                    }
                    invalidateDisplayedSessionMirror()
                    hud.present(.notice("欄位已切換，未復原"))
                }
            } catch {
                if !commandSnapshot.text.isEmpty {
                    ledger.commitRaw(ledger.sessionText + commandSnapshot.text)
                }
                invalidateDisplayedSessionMirror()
                hud.present(.notice("未復原（欄位狀態不明）"))
            }
            return
        }
        do {
            switch try coordinator.replaceSession(commandSnapshot: commandSnapshot,
                                                  expectedSessionText: step.from,
                                                  with: step.to,
                                                  axAnchor: ledger.axAnchor,
                                                  fieldIdentity: ledger.fieldIdentity) {
            case .replaced:
                displayedSessionText = step.to
                hud.present(.notice("已復原"))
                emitFeedback(oldText: step.from)      // 復原後底線罩回舊版
            case .tailAdvanced:
                recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                                  utteranceText: commandSnapshot.text)
                ledger.restoreFailedUndo(step) // 帳本與 polished-only mirror 一起回滾成欄位實況
                keepRaw(commandSnapshot, notice: "未復原（新內容已接續）")
            case .fieldMismatch:
                recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                                  utteranceText: commandSnapshot.text)
                ledger.restoreFailedUndo(step)
                ledger.freeze()
                feedback?.sessionFrozen()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
        } catch InserterError.replaceFailedRestored {
            recordInsertEvent(kind: "insertFailed", classification: "replaceFailedRestored",
                              utteranceText: commandSnapshot.text)
            displayedSessionText = step.from       // command 已刪、復原前 session 已回復
            ledger.restoreFailedUndo(step)
            hud.present(.notice("復原失敗，原文已回復"))
        } catch InserterError.lostText(let original) {
            recordInsertEvent(kind: "insertFailed", classification: "lostText",
                              utteranceText: commandSnapshot.text)
            displayedSessionText = ""
            clipboardRescue?(original)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("復原失敗，原文已複製到剪貼簿"))
        } catch {
            recordInsertEvent(kind: "insertFailed", classification: "unknown",
                              utteranceText: commandSnapshot.text, detail: "\(error)")
            displayedSessionText = ""
            ledger.restoreFailedUndo(step)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("復原失敗"))
        }
    }

    /// 插入層事件補列（M7 §4）：kind 二分——insertFailed＝coordinator 拋錯（真 I/O 失敗）、
    /// insertSkipped＝守衛拒絕（原文正確保留，非失敗）。與正常 outcome 列共用 gate 與 session，
    /// 時序天然在 outcome 列之後（dispatch 先記、apply 後跑），回查時兩列相鄰。
    private func recordInsertEvent(kind: String, classification: String,
                                   utteranceText: String, detail: String? = nil) {
        guard settings.historyEnabled, let hid = historySessionID else { return }
        history?.recordExchange(.init(sessionID: hid, at: now(),
                                      utteranceRaw: utteranceText,
                                      outcomeKind: kind,
                                      outcomeText: detail.map { "\(classification)：\($0)" } ?? classification))
    }

    /// 回收「已不在尾端」的潤飾（M10-C）。連續講話時，前一句還在潤飾、下一句的辨識結果
    /// 就已落地，尾端因此前進——過去這裡直接放棄潤飾，螢幕上留原始轉錄。
    ///
    /// 這句話的絕對起點 ＝ session 錨點 + 目前已定稿文字的長度。成立的理由（spec §3.1.1）：
    /// 套用嚴格按句序串行，且每條終局路徑都讓帳本前進「螢幕上實際多出來的那段」，
    /// 故此刻 `ledger.sessionText` 恰好等於這句話之前的全部文字。**不可改用快照當下的
    /// sessionBefore**——前一句若在本句閉合之後才套用，那個值就少算了它的長度。
    ///
    /// 回傳是否已完成落地；false＝呼叫端照舊保留原文並說明原因。
    private func recoverStaleTail(_ text: String,
                                  snapshot: InsertionCoordinator.UtteranceSnapshot,
                                  previousMirror: String) -> Bool {
        guard let anchor = ledger.axAnchor else { return false }
        let location = anchor + ledger.sessionText.utf16.count
        guard coordinator.replaceStaleTail(snapshot, at: location, with: text,
                                           fieldIdentity: ledger.fieldIdentity) == .replaced else {
            return false
        }
        guard replaceDisplayedUtterance(snapshot, after: ledger.sessionText, with: text) else {
            // AX 已物理改成功，不能再讓 caller keepRaw；凍結並標記 mirror 不可用，後續 Esc 僅可
            // 走 identity-bound AX 驗證，無 AX 則 fail closed。
            invalidateDisplayedSessionMirror()
            hud.present(.notice("欄位鏡像失效，本段停止修正"))
            return true
        }
        ledger.appendPolished(text)
        // 文字有落地、且是潤飾後的版本，故不屬 insertFailed／insertSkipped 二分，另立一類。
        // detail 帶回收後的文字：歷史頁要看得出回收回來的是什麼內容。
        recordInsertEvent(kind: "insertRecovered", classification: "staleTail",
                          utteranceText: snapshot.text, detail: text)
        emitFeedback(oldText: previousMirror)
        return true
    }

    /// @testable-only seam：刻意製造 field mirror 與物理欄位不一致，驗證 splice mismatch
    /// 會 fail closed。internal 是 convention、非硬 access-control；production 不得呼叫。
    func setDisplayedSessionTextForTesting(_ text: String) {
        displayedSessionText = text
    }

    /// 插入層備援診斷（issue #1 被動蒐證）：主 inserter 失敗、備援成功。
    /// 不是失敗也不是跳過——文字有落地，故不進 insertFailed／insertSkipped 二分，另立一類。
    /// utteranceRaw 留空：這是插入機制的事件，不是某句話的 outcome。
    public func noteInserterFallback(_ kind: InsertionCoordinator.InserterFallback) {
        recordInsertEvent(kind: "insertFallback", classification: kind.rawValue, utteranceText: "")
    }

    /// 將實際欄位鏡像中「已落定 prefix 後的這句 raw」換成 outcome。比只改 suffix 深一層：
    /// 下一句已上屏時 stale-tail 會在中段改寫，後方文字必須原樣保留，Esc 才能算對全階段範圍。
    @discardableResult
    private func replaceDisplayedUtterance(_ snapshot: InsertionCoordinator.UtteranceSnapshot,
                                           after settledPrefix: String,
                                           with newText: String) -> Bool {
        let utf16 = displayedSessionText.utf16
        guard let lower = utf16.index(utf16.startIndex,
                                      offsetBy: settledPrefix.utf16.count,
                                      limitedBy: utf16.endIndex),
              let upper = utf16.index(lower,
                                      offsetBy: snapshot.text.utf16.count,
                                      limitedBy: utf16.endIndex),
              String(decoding: utf16[lower..<upper], as: UTF16.self) == snapshot.text,
              let stringLower = String.Index(lower, within: displayedSessionText),
              let stringUpper = String.Index(upper, within: displayedSessionText) else { return false }
        displayedSessionText.replaceSubrange(stringLower..<stringUpper, with: newText)
        return true
    }

    private func invalidateDisplayedSessionMirror() {
        guard !ledger.frozen else { return }
        ledger.freeze()
        feedback?.sessionFrozen()
    }

    /// 原文照留：帳本入帳（欄位鏡像）＋提示
    private func keepRaw(_ snapshot: InsertionCoordinator.UtteranceSnapshot, notice: String) {
        if !snapshot.text.isEmpty {
            ledger.commitRaw(ledger.sessionText + snapshot.text)
        }
        hud.present(.notice(notice))
        emitFeedback()
    }

    /// tail 的 .degraded 專用（規格 §1.2 A4）：raw 已上屏，只同步欄位鏡像，**不建立 undo 版本**。
    /// 與 keepRaw 的差別＝語意不同：keepRaw 用於「有效 outcome 但套用失敗」（我們動過、可退回），
    /// 本路徑用於「LLM 回應未取得寫入資格」（我們什麼都沒做、無版本可退）。
    private func keepRawWithoutVersion(_ snapshot: InsertionCoordinator.UtteranceSnapshot, notice: String) {
        if !snapshot.text.isEmpty {
            ledger.synchronizeObservedTail(ledger.sessionText + snapshot.text)
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
