import Foundation
import OSLog

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

    /// issue #85：排空中按下熱鍵時先錄下來的音訊，等上一段的辨識跑完才交給辨識器。
    ///
    /// 排空中按下以前是「捨棄排空、立刻開新 session」（#83／#84），還沒送達的定稿就此消失——
    /// 批次引擎（Whisper 遠端）的排空就是在等整段話的上傳結果，會整段遺失。現在改成先錄、後接手：
    /// 舊串流照常跑完（定稿上屏、潤飾），之後的接手與「排空跑完才按」走同一條路（延續窗續聽或開新 session）。
    /// 辨識器同一時間只跑一條串流——本機 WhisperKit 的兩條串流會共用同一份 CoreML 模型，不能並行。
    private struct QueuedCapture {
        /// 排隊期間每次按下各錄一條；放開後、排空還沒結束又按，就再錄一條。接手時依序串成一條交給辨識器。
        var segments: [AsyncStream<AudioChunk>]
        /// 還在錄的話是哪種模式；nil＝已放開，最後一條已經收完
        var mode: ListeningMode?
    }

    /// 內部狀態機：finishing＝排空窗；queued＝排空窗中又按了熱鍵（issue #85）；lingering＝延續窗。
    /// 對外：finishing、lingering 等同 idle；queued 在錄音時等同 listening。
    private enum InternalPhase {
        case idle
        case listening(ListeningMode)
        case finishing
        case queued(QueuedCapture)
        case lingering(until: TimeInterval)
    }
    private var internalPhase: InternalPhase = .idle {
        didSet { onActivityChange?() }
    }

    /// 對外狀態（本機控制介面 `saymend status`／`events` 用）。錄音優先於其他狀態：
    /// 錄音中即使上一句的潤飾還在途也報 recording——mod 要的是「麥克風開著」這件事。
    public var activity: DictationActivity {
        switch internalPhase {
        case .listening: return .recording
        case .queued(let q): return q.mode != nil ? .recording : .transcribing
        case .finishing: return .transcribing
        case .idle, .lingering: return pendingIntents > 0 ? .polishing : .idle
        }
    }

    /// `activity` 可能變了（相位或在途潤飾數改變）。同一個 MainActor turn 內可能連續觸發多次，
    /// 由接收端合併（`ControlService` 排到下一個 turn 才計算、且只在值真的變了才送出）。
    public var onActivityChange: (() -> Void)?

    /// CLI 來源的聽寫要開麥之前呼叫（本機控制介面）。回傳 false＝熱鍵聽寫正在用麥克風或辨識器
    /// （錄音、排空、排隊），或上一段的潤飾還在途——此時不得開始 CLI 聽寫。
    ///
    /// 延續窗中且沒有在途潤飾：**視同使用者活動，立即封存**（同 `userActivityDetected` 在延續窗的語意）。
    /// 延續窗是「接著說話修正剛才那段」，CLI 聽寫的文字不會進那個欄位，不是延續；不封存的話，
    /// 延續窗到期時的 `archiveSession` 會發 `.hidden`，把 CLI 錄音中的 HUD 一起收掉（錄音就變成看不見）。
    public func yieldForExternalCapture() -> Bool {
        guard pendingIntents == 0 else { return false }
        switch internalPhase {
        case .idle:
            return true
        case .lingering:
            archiveSession()
            return true
        case .listening, .finishing, .queued:
            return false
        }
    }

    public var phase: Phase {
        switch internalPhase {
        case .idle, .finishing, .lingering: return .idle
        case .listening(let mode): return .listening(mode)
        case .queued(let q): return q.mode.map { .listening($0) } ?? .idle
        }
    }

    /// 麥克風是否正在為使用者錄音（`.listening`，或 issue #85 排隊中且還沒放開）。焦點監看只在這段期間有意義。
    private var isRecording: Bool {
        if case .listening = internalPhase { return true }
        return isRecordingQueued
    }

    /// issue #85：排隊中且還沒放開——錄的是新的一段，辨識器上跑的卻還是上一段的串流
    private var isRecordingQueued: Bool {
        if case .queued(let q) = internalPhase { return q.mode != nil }
        return false
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
    /// 鐵律最後手段：原文救不回時交給剪貼簿（app 端接 NSPasteboard）。回報是否覆寫了上一輪的救援（issue #71）。
    private let clipboardRescue: ((String, Int) -> ClipboardRescueOutcome)?
    /// 聚焦欄位快照：密碼欄位拒絕聽寫、session 起點取 AX 錨位（規格 §4.6／§5.3）
    private let fieldReader: (any FieldContextProviding)?
    /// 視覺回饋層（規格 §3.5）：Core 只發語意事件，App 端 FeedbackCoordinator 決定畫不畫、畫哪裡
    private let feedback: (any SessionFeedbackPresenting)?
    /// 聽寫歷史（規格 §4.9）：nil＝不記錄。寫入失敗不得影響聽寫主流程。
    private let history: (any HistoryRecording)?
    /// OCR 螢幕語境（規格 §4.7）：非同步截圖辨識，App 端注入；nil＝停用。
    /// 何時呼叫由 `settings.ocrContextMode` 決定（見 `OCRContextMode.shouldCapture`）。
    private let contextOCR: (() async -> String?)?
    /// 時間來源（歷史記錄時戳）；測試可注入固定時鐘。
    private let now: () -> Date
    /// 錄音期間的焦點變更監看（issue #70）：nil＝不監看，只剩事件驅動的兩道閘門（暫時文字、定稿）。
    private let focusWatcher: (any FocusChangeWatching)?

    /// session 帳本（測試經 @testable 檢視）
    private(set) var ledger = SessionLedger()

    private var pressedAt: TimeInterval?
    private var readerTask: Task<Void, Never>?
    /// 60 秒靜音逾時結束：排空後直接封存，不進延續窗（規格 §3.4 逾時＝凍結觸發器）
    private var archiveAfterDrain = false
    /// issue #18：本 session 是否收過「沒偵測到語音」示警。收尾時據此決定要不要發 notice。
    private var sawNoSpeechWarning = false
    /// issue #18：本 session 是否辨識出過任何文字。示警的解除訊號。
    private var sawTextThisSession = false
    /// issue #10：本 session 是否略過過字幕罐頭語。收尾時據此提示。
    private var sawCaptionHallucination = false

    /// 略過字幕罐頭語的提示（issue #10）。不提「原文在歷史裡」：歷史可以關掉，關了那句話就不成立。
    public static let captionHallucinationNotice =
        "略過了疑似字幕幻覺的辨識結果（沒人說話時 Whisper 常見）"

    /// 收尾時的提示文案。兩條出路都給：物理上的（靠近麥克風）與設定上的（調低門檻）。
    /// 只寫「沒偵測到語音」而不給方向的話，使用者只會重試一次同樣的動作然後放棄。
    public static let noSpeechNotice =
        "沒偵測到語音。麥克風可能太遠，或到「設定 › 進階：串流參數」調低靜音門檻"
    /// 遞增 session 序號：readerTask 事件過濾，避免跨 session 污染
    private(set) var sessionID = 0
    /// 在途（已派發、尚未 dispatch 完成）的意圖任務數：undo 按鈕的在途防護（測試經 @testable 檢視）
    private(set) var pendingIntents = 0 {
        didSet { onActivityChange?() }
    }

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
    /// issue #71：最近一次救援用的 round，與「哪一輪覆寫過上一輪的救援」。兩者相等＝剛救的這一輪就是取代了別人的那一輪，
    /// 它**接在同一條累積鏈上**的後續救援提示也帶上 `replacedEarlierRescueSuffix`（後一則若在 2 秒保護期內取代前一則，
    /// 只在第一則說的話會被蓋掉）。鏈斷了（使用者複製過別的東西，`.landed`）就不再帶——那時被蓋掉的是使用者的內容，不是救援。
    /// 刻意不隨 archive 清除：`abandonSelectionReplacement` 是「救援→封存→提示」。
    private var lastRescueRound: Int?
    private var rescueDisplacingRound: Int?
    /// 最近一次救援沒寫進剪貼簿（issue #71）：提示不能說「已入剪貼簿」，改指向選單的「最近救援」
    private var lastRescueNotWritten = false
    /// 熱鍵按下當下的前後文窗口（LLM 語境；tail 與 selection 模式皆用）
    private var capturedContextBefore: String?
    private var capturedContextAfter: String?
    /// 進行中 session 的歷史 id（nil＝未記錄，如歷史關閉或密碼欄位）
    private var historySessionID: String?
    /// 最近一次封存的 session 的歷史 id（issue #20）：封存後辨識器才送來的定稿，相位守衛會丟掉它，
    /// 但要記一列在**剛封存的那個** session 底下，否則事後完全查不到。
    /// 每次封存都無條件覆寫（含 nil）：沒有 id 的 session 封存後，遲到的定稿不得掛到更早的 session 上。
    /// 只供 `.idle` 的相位守衛使用——LLM outcome 用的是話語閉合當下捕捉的 id（`processUtterance`）。
    private var archivedHistorySessionID: String?
    /// 熱鍵按下當下的前景 App 名稱（第 7 層動態上下文，規格 §4.7）
    private var capturedFrontAppName: String?
    /// 熱鍵按下當下的前景 App bundleID（issue #37 診斷：判讀「同 App 換欄位」還是「跨 App」）
    private var capturedFrontAppBundleID: String?
    /// 進行中這句話是否有 raw 片段被寫入前的焦點閘門攔掉（issue #37）。
    /// 流法比照 `wasBuffered`：在 `processUtterance(raw:)` 捕捉當下值後立即重設，再傳進 `dispatch`。
    private var skippedRaw = false
    /// OCR 備援落地的螢幕參考文字（趕上哪句算哪句——M4 設計裁決 5）
    private var capturedOCRText: String?
    /// internal 供測試 await（OCR 非同步落地，趕上哪句算哪句——M4 設計裁決 5）
    private(set) var ocrTask: Task<Void, Never>?
    /// issue #65：本段（自上次 `startListening` 起）的暫時文字已遮罩。fail closed，同時是 AX 成本的熔斷：
    /// 一旦遮罩，本段之後的暫時文字一律顯示 `""`、不再查閘門。只在 `startListening` 重置——
    /// 它是進入 `.listening` 的唯一入口（新段、延續窗續聽都走它），多一個重置點只會是殺不到的 mutation。
    private var volatileMasked = false
    /// 暫時文字的呈現決定（issue #65）：照常顯示（可能是遮罩後的 `""`），或立即硬停。
    private enum VolatilePreview: Equatable {
        case show(String)
        case abortSecure
    }
    /// issue #65 Step 0 量測（裁定 Q7）：本段暫時文字的頻率與閘門耗時。型別上只有數字與旗標。
    /// 在 `endListening`／`archiveSession` 以 debug log 輸出後歸零（@testable 可讀）。
    private(set) var volatileGateStats = VolatileGateStats()
    /// 最近一次輸出到 log 的那份量測（測試觀察用：os.Logger 本身沒有可觀察的 seam）
    private(set) var lastFlushedVolatileGateStats: VolatileGateStats?
    /// issue #70：本段錄音的焦點監看 handle。只在錄音期間（`.listening`，或 issue #85 排隊中還沒放開）非 nil——
    /// 每條結束錄音的路徑（`endListening`、`endQueuedCapture`、`archiveSession`、`asrStreamEnded`）都會呼叫
    /// `stopFocusWatch()`，那是唯一的歸還點。
    private var focusWatch: (any FocusWatch)?
    /// 監看世代：每次開始、停止都遞增。callback 帶著開始當下的世代，對不上就是舊 watch 的遲到通知——
    /// controller 自己認得，不依賴 App 端「observer 移除後就不會再送」。
    private var focusWatchEpoch = 0
    private static let hudLog = Logger(subsystem: "io.saymend.app", category: "hud")
    private static let sessionLog = Logger(subsystem: "io.saymend.app", category: "session")

    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                coordinator: InsertionCoordinator,
                intent: any IntentServing,
                hud: any HUDPresenting,
                settings: AppSettings,
                segmenter: UtteranceSegmenter = UtteranceSegmenter(),
                clipboardRescue: ((String, Int) -> ClipboardRescueOutcome)? = nil,
                fieldReader: (any FieldContextProviding)? = nil,
                feedback: (any SessionFeedbackPresenting)? = nil,
                history: (any HistoryRecording)? = nil,
                contextOCR: (() async -> String?)? = nil,
                focusWatcher: (any FocusChangeWatching)? = nil,
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
        self.focusWatcher = focusWatcher
        self.now = now
    }

    // MARK: - 熱鍵事件

    public func hotkeyPressed(at t: TimeInterval) {
        switch internalPhase {
        case .idle, .lingering:
            // lingering：延續窗內按下＝同 session 續聽（帳本延續，規格 §3.4）。
            pressedAt = t
            startListening(mode: .hold, at: t)
        case .finishing:
            // 上一段排空中按下＝先錄、等排空跑完再接手（issue #85，見 `QueuedCapture`）
            pressedAt = t
            queueCapture()
        case .queued(let q):
            pressedAt = t
            // 還在錄：同 `.listening`。已放開、排空仍沒結束又按：再錄一條，接手時接在後面
            if q.mode == nil { queueCapture() }
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
        case .queued(var q):
            // 與 `.listening` 同一套 tap／長按規則，只是放開時辨識還沒開始，只收音
            switch q.mode {
            case .hold?:
                if isTap {
                    q.mode = .locked
                    internalPhase = .queued(q)
                    presentListening(mode: .locked, volatile: "")
                } else {
                    endQueuedCapture(q)
                }
            case .locked?:
                if isTap { endQueuedCapture(q) }
            case nil:
                break
            }
        case .idle, .finishing, .lingering:
            break
        }
        pressedAt = nil
    }

    /// Esc 因缺 verified AX 而 fail closed 時的提示（issue #21 裁定 3：只提示，不進剪貼簿——按 Esc 就是要丟掉它）
    static let retractionUnverifiedNotice = "無法確認文字位置，本段未退回，請手動刪除"

    /// 寫入前的焦點閘門攔下一句 raw 時的提示（issue #37）。
    /// **刻意不歸入 `insertSkipNotice` 那個「未潤飾（…）」家族**：那家族說的是「字在螢幕上、只是潤飾沒套用」，
    /// 這裡說的是「字根本沒上屏」——對使用者的下一步動作完全不同（前者可以不理，後者要去貼上）。
    /// 以救援提示呈現（`hud.presentRescueNotice`，issue #61）：session 照常繼續，下一個暫時文字往往
    /// 數百毫秒內就到，沒有最短顯示保證的話使用者根本讀不到。
    static let fieldChangedNotice = "欄位已切換，內容已入剪貼簿"

    /// issue #71：這一輪的救援覆寫掉了上一輪還留在剪貼簿裡的救援時，接在救援提示後面。
    /// 只說「移到選單」，不說「你還沒貼上」——Cmd+V 不推進 changeCount，我們不知道使用者貼過沒有。
    /// 找回途徑是選單列的「最近救援」（App 端只放在記憶體、最多 5 筆）。
    /// 刻意短（15 字）：救援提示只停 2.5 秒（至少 2 秒），接在 9～20 字的提示後面，長了讀不完；
    /// 要讓人記住的只有選單的名字。
    static let replacedEarlierRescueSuffix = "（上一段已移到選單「最近救援」）"
    /// issue #71：救援寫不進剪貼簿時，把提示裡的「已入剪貼簿」換成這句（每則救援提示都以「已入剪貼簿」收尾）。
    /// 這是 #41 起就存在的不實提示：寫入失敗時剪貼簿已放回原本的內容，使用者照提示貼上會拿到別的東西。
    static let rescueNotWrittenPhrase = "未能寫入剪貼簿（可從選單「最近救援」找回）"

    public func escapePressed() {
        if isLingering {
            archiveSession()                // 延續窗中按 Esc＝提前定稿（吞掉 Esc 由熱鍵層處理）
            return
        }
        switch internalPhase {
        case .finishing, .queued:
            // 排空窗中按 Esc＝中止排空並定稿——否則 Esc 被熱鍵層吞掉又無作用，整顆蒸發。
            // 排隊中（issue #85）同樣中止排空；排隊的錄音由 archiveSession 停掉並丟棄（還沒辨識，沒有字要退）。
            asr.cancel()
            archiveSession()
            return
        case .listening:
            break
        case .idle, .lingering:
            return
        }
        segmenter.hardReset()
        asr.cancel()
        audio.stop()
        // 退字的結果通知（若有）要留到 archiveSession 之後才發：archive 會發 .hidden，先發會被蓋掉
        // （同 abortForSecureField／handleASRFailure 的順序）。診斷事件則相反，必須在 archive
        // 清掉 historySessionID 之前記。
        var retractionNotice: String?
        if case .selectionPending = sessionTarget {
            coordinator.clearCurrentUtterance()        // 緩衝：螢幕沒字，不得退格（須在 archiveSession 重置 sessionTarget 前判斷）
        } else {
            // 退回終點由設定決定（issue #46）：「一併退掉已潤飾」＝session 起始原文；關閉＝帳本的已潤飾鏡像（只退 raw）。
            let target = ledger.escapeRetractionTarget(includingPolishedText: settings.escapeRetractsPolishedText)
            let retracting = coordinator.displayedText
            if ledger.frozen && !settings.escapeRetractsFrozenSession {
                // 凍結守衛（issue #38 ①）：其他每條落地路徑都有，只有 Esc 漏了。凍結的成因正是使用者剛手動
                // 編輯過欄位，我們不再知道欄位長什麼樣。整段文字原封保留，Esc 的另一半語意「結束聽寫」照常執行。
                // 凍結後是否仍退由 escapeRetractsFrozenSession 決定（#46），預設不退。
                // 只在 Esc 本來會退掉東西（鏡像 ≠ 目標）時才提示、記事件：全都已潤飾又只退 raw，本來就沒事可做。
                if retracting != target {
                    // utteranceText 在這裡例外地是**整段鏡像**而非單句：Esc 要退的本來就是整段，凍結擋下的也是整段
                    recordInsertEvent(kind: "insertSkipped", classification: "frozen", utteranceText: retracting)
                    retractionNotice = "已凍結，未退回文字"
                }
                coordinator.clearCurrentUtterance()
            } else {
                // 整段退回（issue #21／#44）：以欄位鏡像為 expected、verified AX 範圍替換成 target——
                // 含已潤飾、已修正、潤飾在途的 raw 與進行中的 utterance，不再只退當前話語。
                // 缺 anchor／identity／AX、identity 不符或內容不符：一個字都不動，只提示（裁定 3：不碰剪貼簿）。
                // 凍結且設定開啟時也走這裡，同一套規則：使用者凍結後手打在 session 範圍之後的字在範圍外、自然保留；
                // 手打進範圍內＝內容不符 → fail closed。設定不是 verified AX 的例外。
                switch coordinator.retractSession(to: target) {
                case .replaced:
                    // 欄位已退回 target：帳本鏡像跟上，否則 archiveSession 會把使用者剛丟掉的文字
                    // 當成這次聽寫的 finalText 寫進 History。不建版本——session 馬上封存，沒有東西可復原。
                    ledger.synchronizeObservedTail(target)
                case .unverified:
                    recordInsertEvent(kind: "insertSkipped", classification: "unverified", utteranceText: retracting)
                    retractionNotice = Self.retractionUnverifiedNotice
                case .fieldMismatch, .tailAdvanced:
                    recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch", utteranceText: retracting)
                    retractionNotice = Self.retractionUnverifiedNotice
                }
            }
        }
        // Esc 不進延續窗（設計裁決 3）＝提前封存。統一走 archiveSession 清乾淨 session 級狀態
        // （sessionTarget／sessionLanguageOverride，設計裁決 4「archive 時自動清除」）——
        // internalPhase 已設 idle，之後遲到的 stream-end 會被 asrStreamEnded 的相位守衛冪等忽略。
        archiveSession()
        if let notice = retractionNotice {
            hud.present(.notice(notice))
        }
    }

    /// 使用者手動活動（打字／滑鼠點擊／切 App；app 端由 HotkeyMonitor 與 NSWorkspace 餵入）。
    /// 聽寫中＝凍結（文字定稿、不再改寫，錄音照常）；延續窗中＝立即封存（設計裁決 2）。
    public func userActivityDetected(at t: TimeInterval) {
        switch internalPhase {
        case .listening, .finishing, .queued:
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
        case .listening, .finishing, .queued, .lingering:
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
            // issue #70：確認監看仍掛在目前焦點所屬的行程上（跨行程、卻沒有 App 啟用的焦點移動，
            // 例如 System Settings 的 remote view、系統授權框）。可能當場回報密碼欄而硬停——
            // 硬停後 phase 已是 idle，不得再處理斷句器動作（`.sessionTimedOut` 會把 idle 推進 finishing）。
            focusWatch?.resync()
            guard case .listening = internalPhase else { return }
            process(actions: segmenter.onTick(at: t))
        case .queued:
            // issue #85：排隊中還在錄的話，監看同樣要跟著焦點所屬的行程（放開後已停，resync 是 no-op）。
            // 斷句器不動：它此刻屬於還在排空的舊串流，排空窗本來就不 tick。
            focusWatch?.resync()
        case .lingering(let until):
            if t >= until { archiveSession() }
        case .idle, .finishing:
            break
        }
    }

    public func handleTranscript(_ event: TranscriptEvent, at t: TimeInterval) {
        switch internalPhase {
        case .idle, .lingering:
            recordFinalizedDroppedByPhase(event)   // 照舊丟掉，但不再零紀錄（issue #20）
            return
        case .listening, .finishing, .queued:
            break   // finishing（排空窗）的尾端 finalized 仍須處理，不能丟；queued 時排空中的仍是同一條串流（issue #85）
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
        // **字幕罐頭語不是定稿文字**（issue #10）：引擎用它取代了那一筆定稿。
        // - 不進斷句器：不送潤飾，也不重置靜音計時——背景影片一直在播時，它不得讓話語晚閉合、
        //   讓 60 秒靜音逾時一直延後。
        // - 不解除「沒偵測到語音」示警：它不是使用者開口的證據。
        // - 文字照記（歷史與辨識品質診斷）：誤殺時使用者要查得到那句話去了哪裡，
        //   被抓到的幻覺的分數也正是日後訂門檻要的樣本。不先問密碼欄閘門：會走到這裡的文字整句都是
        //   罐頭語的形狀（製作名單的名字最多 12 個字），不會是使用者在密碼欄說的話；
        //   而且焦點一進密碼欄，焦點監看（#70）早就硬停了整個 session。
        if case .captionHallucination(let text, let quality) = event {
            sawCaptionHallucination = true
            recordInsertEvent(kind: "insertSkipped", classification: "captionHallucination",
                              utteranceText: text)
            recordASRDiagnostic(text: text, quality: quality)
            return
        }
        releaseNoSpeechWarningIfTextArrived(event)
        segmenter.onTranscript(event, at: t)
        switch event {
        case .volatile(let text):
            // `.finishing`（排空窗）本來就不呈現暫時文字，所以也不查閘門（白付 AX IPC）。
            if case .listening(let mode) = internalPhase {
                volatileGateStats.recordEvent(at: t)
                // issue #65：轉錄文字進 HUD 只有這一條路，密碼欄守衛必須跑在 present **之前**，
                // 且查詢與 present 之間沒有 `await`（同一個 MainActor turn）。
                switch volatilePreview(text) {
                case .show(let shown):
                    if volatileMasked { volatileGateStats.noteMasked() }
                    presentListening(mode: mode, volatile: shown)
                case .abortSecure:
                    volatileGateStats.noteAborted()        // 必須在 abort 之前：archiveSession 會輸出並歸零
                    // `segmenter.hardReset()` 讓焦點在密碼欄期間說的話不閉合、不送 LLM、不落地（V12）
                    abortForSecureField()
                }
            }
        case .finalized(let text, let quality):
            // M2 遺留債：聽寫中焦點切進密碼欄位（Tab、程式切換焦點——滑鼠/鍵盤活動已由凍結涵蓋，
            // 但焦點可以不經這兩者移動）。規格 §5.3：密碼欄位一個字都不能進。硬停整個 session。
            // 暫時文字那條路（上面的 `.volatile` 分支，issue #65）另有自己的閘門，查到 `.secure` 同樣硬停；
            // 它的遮罩**不得**讓這裡的閘門被省略——遮罩只管畫面，內容層的 fail closed 仍由這一道負責。
            //
            // issue #37：這裡原本每句都做一次完整 snapshot，只為讀一個 isSecure bool
            // （4–5 次 AX IPC，且在有選取＋白名單 App 時會對目前焦點發合成 Cmd+C），現在是輕量閘門。
            // **這一道只留密碼守衛**：`.different` 的攔阻已經下沉到 `InsertionCoordinator` 的寫入路徑
            // （閘門查詢與物理寫入之間的窗口最短），這裡再記一次會讓每次跳過產生兩列 history。
            // 附帶好處：`.selectionPending` 的緩衝句走 accumulateFinalized、本來就不上屏，
            // 不再因為「焦點已換」而被記成假的跳過。
            // 閘門用的 token 由實作自行歸還／根本不登記（issue #43 的 lease 不變式因此中性）。
            switch fieldReader?.fieldGate(sessionIdentity: ledger.fieldIdentity) {
            case .secure:
                abortForSecureField()
                return
            case .secureUnknown:
                // AX 連續兩次問不出 subrole：依 #59 fail closed，行為與 `.secure` 逐字相同（§5.3 一個字都不能進）。
                // 但要留下證據說明這是「不知道」——否則真的密碼欄與 AX 沒回應在事後資料裡長得一樣，
                // 0.2s timeout 誤殺了多少就量不出來。
                // **必須先記再 abort**：`abortForSecureField()` 會 `archiveSession()`，
                // 而 archive 把 `historySessionID` 清成 nil，`recordInsertEvent` 沒有 hid 會整筆靜默丟掉。
                //
                // **`utteranceRaw` 必須留空**（issue #10 的不變式，本分支同樣適用）：`.secureUnknown`
                // 的定義就是「不知道這是不是密碼欄」——慢 App 的 AXSecureTextField 連兩次回 cannotComplete
                // 正是 0.2s timeout 下最可能發生的情境。把定稿文字原樣寫進 `history_exchange` 等於
                // 在有可能是密碼欄的地方留下一份明文密碼，而 `historyEnabled` 預設為 true，
                // 這會是預設開啟的行為，不是 opt-in 診斷。§5.3「一個字都不能進」換個容器同樣是違反。
                // 誤殺率要的是分子／分母與「哪些 App 常逾時」，句子內容對這個目的沒有任何貢獻——
                // 付出隱私成本卻換不到資訊價值。故只留 metadata。
                //
                // detail 標成 `sessionApp:`：這是 **session 起始**的前景 App，不保證就是逾時的那個
                // （聽寫途中跨 App 換焦點時兩者會不同）。`.secureUnknown` 這個 case 本身不帶 bundleID，
                // 要拿到「此刻」的前景 App 得另外發一次查詢，不在本次範圍。標籤讓後續判讀看得見這層落差，
                // 不會把 session 起始 App 誤當成「這個 App 很慢」的證據。
                recordInsertEvent(kind: "insertSkipped", classification: "secureUnknown",
                                  utteranceText: "",
                                  detail: "sessionApp:\(capturedFrontAppBundleID ?? "?")")
                abortForSecureField()
                return
            case .different, .same, .unknown, .none:
                // `.different` 不在這裡攔——真正的攔阻在寫入前的那一道閘門（`InsertionCoordinator`）。
                // 這裡若也記一筆診斷，每次跳過就會產生兩列 history（本處一列＋寫入前那道一列），
                // 而那正是誤判率分母要避免的重複計數。附帶好處：`.selectionPending` 的緩衝句
                // 走 accumulateFinalized、本來就不上屏，也不再被記成假的跳過。
                break
            }
            // **必須在所有密碼欄守衛之後**（issue #10）：診斷列會把定稿文字原樣落進
            // `asr_diagnostic.finalizedText`——SQLite 的明文欄，唯二的閘是 `settings.historyEnabled`
            // （預設 true）與 `quality != nil`（WhisperKit 每筆定稿都給非 nil），所以 WhisperKit
            // 使用者在預設設定下每一句都會落地。寫在守衛之前等於在密碼欄位裡留下一份使用者說的話。
            //
            // 本分支把「守衛」的範圍擴大了：除了上面那道 `:341` 的閘門查詢，還多了一道**寫入前閘門**
            // （`coordinator.insertFinalized` 回 `.secureField`），專門攔「`:341` 答完之後、物理寫入
            // 之前」焦點才切進密碼欄的窄窗口。診斷若仍留在這裡，就會跑在那道新守衛**之前**——
            // 在已判定是密碼欄的情況下照樣留下一份明文，§5.3「一個字都不能進」換個容器同樣是違反
            // （硬停擋住了雲端 LLM 與 `history_exchange`，卻擋不到這張表）。
            //
            // 故改成**插入結局已知之後**才寫，各終點各記一次，唯獨 `.secureField` 那條不記。
            // 各終點各寫一次而不是用 `defer` 統一補：這樣的預設是 fail closed——日後新增的終點
            // 若忘了呼叫，只損失診斷樣本；`defer` 的預設則是「一律寫」，新增一條密碼欄終點就會多洩一份明文。
            if case .selectionPending = sessionTarget {
                coordinator.accumulateFinalized(text)      // 緩衝：不上屏（M3 設計裁決 1）
                // 緩衝句這條路徑上，`:341` 的閘門此刻已答過「不是密碼欄」，沒有更晚的偵測點可等。
                recordASRDiagnostic(text: text, quality: quality)
            } else {
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
                    rescueToClipboard(text)
                    recordASRDiagnostic(text: text, quality: quality)
                    presentRescueNotice("已凍結，內容已入剪貼簿")
                    return
                }
                do {
                    switch try coordinator.insertFinalized(text) {
                    case .inserted:
                        emitFeedback()                         // 底線延伸至新上屏文字
                        recordASRDiagnostic(text: text, quality: quality)
                    case .fieldChanged(let currentAppBundleID):
                        // 寫入前的閘門 fail closed（issue #37 裁定 Q1）：一個字都沒進任何欄位。
                        // 只跳過這一句，**不 freeze、不 archive**（裁定 Q2）——焦點跳回原欄位之後
                        // 下一句要能照常上屏。內容不得遺失，故進剪貼簿並當場告知使用者。
                        recordInsertEvent(kind: "insertSkipped", classification: "fieldChanged",
                                          utteranceText: text,
                                          detail: fieldChangeDetail(current: currentAppBundleID))
                        rescueToClipboard(text)
                        recordASRDiagnostic(text: text, quality: quality)
                        presentRescueNotice(Self.fieldChangedNotice)
                        skippedRaw = true
                        return
                    case .secureField(let subroleUnknown):
                        // 焦點已切進密碼欄，或 AX 問不出 subrole 而 fail closed（規格 §5.3／issue #59）：
                        // **硬停整個 session**，與上面那道 `:341` 的守衛逐字相同。
                        //
                        // 不能比照 `.fieldChanged` 只跳過這一句：片段在 `segmenter.onTranscript`
                        // 就已經進了斷句器 buffer（那一行跑在閘門查詢**之前**），session 若繼續跑，
                        // 話語閉合時 `processUtterance` 會把**含被擋片段**的整句 raw 送
                        // `intentService.process`（雲端 provider）；而 `dispatch` 頂端那道無條件的
                        // `recordExchange` 又跑在 `skippedRaw` 早退**之前**，LLM 潤飾全文
                        // （含被擋片段）會明文落進 `history_exchange.outcomeText`，`historyEnabled`
                        // 預設 true。失敗情境：對欄位 A 說「我的密碼是」→ 焦點被搬到密碼欄 P →
                        // 說「1234」→ 整句上雲端 → 明文永久寫進本機 SQLite。
                        // `abortForSecureField()` 的 `segmenter.hardReset()` 讓那句 raw 根本不會閉合。
                        //
                        // **`utteranceText` 一律留空**（issue #10／#58 的不變式）：`.secureField` 的定義
                        // 涵蓋「有可能就是密碼欄」，把定稿文字原樣寫進 `history_exchange` 等於在可能是
                        // 密碼欄的地方留下一份明文。誤判率要的是分子／分母與「哪些 App 常逾時」，
                        // 句子內容對這個目的沒有任何貢獻。
                        //
                        // 分類分成兩條：`secureField`（AX 明確說是密碼欄，不帶 detail——沒有 bundleID，
                        // 也不該有）與 `secureUnknown`（問不出來）。後者的 detail 格式**與 :341 那條逐字相同**，
                        // 兩條路徑的誤殺樣本才合得起來算。焦點監看（issue #70）的兩條另帶 ` via:focusChange`／
                        // ` via:watchStart` 後綴：聚合時要用**前綴**比對，不能用完全相等。`sessionApp:` 標的是 session 起始的前景 App，
                        // 不保證就是逾時的那個。
                        //
                        // **順序不可對調**：`abortForSecureField()` 會 `archiveSession()`，而 archive
                        // 把 `historySessionID` 清成 nil，`recordInsertEvent` 沒有 hid 就整筆靜默丟掉。
                        if subroleUnknown {
                            recordInsertEvent(kind: "insertSkipped", classification: "secureUnknown",
                                              utteranceText: "",
                                              detail: "sessionApp:\(capturedFrontAppBundleID ?? "?")")
                        } else {
                            recordInsertEvent(kind: "insertSkipped", classification: "secureField",
                                              utteranceText: "")
                        }
                        // **不 `rescueToClipboard`**：剪貼簿是另一個持久容器（clipboard manager 會留存），
                        // 而這段 raw 同樣可能含焦點已在密碼欄期間說出的字；`:341` 那道守衛今天也不救。
                        // **不 `recordASRDiagnostic`**：同一個理由換一張表——`asr_diagnostic.finalizedText`
                        // 是明文欄，這裡已判定是密碼欄，一個字都不留。這也是診斷從閘門之前搬到各終點的原因。
                        // **不另發 notice**：`abortForSecureField()` 自己會發「密碼欄位不聽寫」。
                        // **不設 `skippedRaw`**：`hardReset` 之後這句根本不會閉合、不會 dispatch。
                        abortForSecureField()
                        return
                    }
                } catch {
                    // 內容已產生卻落不了地：比照緩衝句插入失敗（:727）救進剪貼簿，別讓使用者白說話。
                    // 這先前是全檔唯一漏掉 clipboardRescue 的同型路徑（另見 :352／:698／:724／:733／:745／:856／:893）。
                    // 剪貼簿內容與欄位狀態一致：insertFinalized 是 try insertWithFallback(text) 成功才更新
                    // currentUtteranceText／displayedText／insertCounter（InsertionCoordinator.swift:104-110），
                    // 而 TextInserter 的原子契約（issue #38）保證拋錯＝一個字都沒進欄位——這一段完整落在剪貼簿。
                    // 同 session 內多個 .finalized 連續插入失敗時**不會互相覆寫**：走 rescueToClipboard
                    // 的預設 round（ledger.generation），ClipboardChannel 把同一輪的救援串接成一份
                    // （issue #42 取捨 4 的修訂）。此處仍沒有 dispatch 的 lastRescueGeneration（:694-697）
                    // 那種「只救一份」的節流——那是刻意的：每一段都是使用者真的說過的話，都該留下。
                    // 提示以救援提示呈現（issue #61）：hold 模式下 `asrStreamEnded` 緊接著會 present `.lingering`、
                    // session 已不 active 時 `archiveSession` 會 present `.hidden`——沒有仲裁的話這行提示當場就被蓋掉。
                    // App 端包的 `HUDArbiter` 保證它至少停留 `HUDArbiter.minimumHold`，期間的狀態延後重播。
                    // 記一列 `insertFailed`（issue #20）：提示與剪貼簿都是會消失的容器，使用者一旦沒看到，
                    // 事後在歷史裡就完全查不到這段話去了哪裡。#20 那次遺失正是零紀錄的。
                    // 與緩衝句插入失敗那條（`insertDetached` 的 catch）一致：兩條都記，分類分別標 `raw`／`buffered`。
                    // 文字照記：閘門已答過不是密碼欄（`.secureField` 走上面的分支、不會擲錯），且它同時正要進剪貼簿。
                    recordInsertEvent(kind: "insertFailed", classification: "raw",
                                      utteranceText: text, detail: "\(error)")
                    rescueToClipboard(text)
                    recordASRDiagnostic(text: text, quality: quality)
                    presentRescueNotice("插入失敗，內容已入剪貼簿")
                }
            }
        case .transcribing:
            // 批次引擎等待結果中；不動 ledger、不動欄位。
            // issue #85：排隊中還在錄的話，這是**上一段**串流的狀態——畫面屬於使用者正在說的這段，不得蓋掉它。
            if !isRecordingQueued { hud.present(.transcribing) }
        case .loadingModel:
            // 本機模型載入中（首次較久）；同樣不動 ledger、不動欄位。排隊中錄音時同上。
            if !isRecordingQueued { hud.present(.loadingModel) }
        case .failed(let reason):
            handleASRFailure(reason: reason, at: t)
        case .noSpeechDetected, .captionHallucination:
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

    /// 相位守衛丟掉的定稿（issue #20）：丟照丟，但留一列 `finalizedDropped`，分類是當下的相位。
    ///
    /// - `.idle`：session 已封存（Esc、密碼欄硬停、ASR 失敗…），辨識器在那之後才送來的定稿。
    ///   掛在**剛封存的那個** session 底下（`archivedHistorySessionID`）。
    /// - `.lingering`：串流已結束才又收到定稿——readerTask 的順序保證這不該發生，正因如此更要有警報。
    ///   session 還沒封存，掛在目前的 session 底下。
    ///
    /// **只記字數，`utteranceText` 一律留空**（issue #10 的不變式）：走到 `.idle` 的封存原因包含
    /// 密碼欄硬停，那之後送來的定稿可能正是焦點在密碼欄期間說的話。這裡刻意不追蹤封存原因去放行
    /// 「安全的」那幾種——日後新增的封存路徑若忘了標，預設就會洩漏；只留 metadata 則永遠 fail closed。
    /// 要回答的問題是「有沒有發生、發生在哪個 session、多長」，字數已經足夠。
    ///
    /// 只有「有內容的定稿」才算使用者的話被丟掉；暫時文字、空定稿、示警都不是。
    private func recordFinalizedDroppedByPhase(_ event: TranscriptEvent) {
        guard case .finalized(let text, _) = event, !text.isEmpty else { return }
        let phase: String
        let droppedFrom: String?
        switch internalPhase {
        case .idle:
            phase = "idle"
            droppedFrom = archivedHistorySessionID
        case .lingering:
            phase = "lingering"
            droppedFrom = historySessionID
        case .listening, .finishing, .queued:
            return                              // 這幾個相位不會丟，呼叫端也不會在這時呼叫
        }
        recordHistoryEvent(sessionID: droppedFrom, kind: "finalizedDropped", classification: phase,
                           utteranceText: "", detail: "chars:\(text.count)")
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

    /// 暫時文字上 HUD 前的密碼欄閘門（issue #65）。判定表見計畫 §4.1：
    /// - 空字串、本段已遮罩：顯示 `""`，不查
    /// - `fieldReader == nil`、`.same`、`.different`、起點就沒有 identity 的 `.unknown`（#21）：照常顯示
    /// - session 有 identity 卻讀不到焦點的 `.unknown`、`.secureUnknown`：遮罩並熔斷
    /// - `.secure`：硬停（與定稿路徑的 `.secure` 一致，不記 insertEvent）
    ///
    /// **只呼叫 `fieldGate`（實作只用 `registry.matches`），絕不呼叫 `snapshot()`**：snapshot 會登記
    /// identity 持有者，這裡不歸還就破壞 #43 的 lease 不變式。
    /// **不寫任何持久容器**（#10）：不呼叫 `recordInsertEvent`／`recordASRDiagnostic`——暫時文字可能
    /// 正是焦點在密碼欄期間說出的字，「不知道是不是密碼欄」的分支同樣一個字都不留。
    private func volatilePreview(_ text: String) -> VolatilePreview {
        guard !text.isEmpty, !volatileMasked else { return .show("") }
        let started = ContinuousClock.now
        let gate = fieldReader?.fieldGate(sessionIdentity: ledger.fieldIdentity)
        if gate != nil { volatileGateStats.recordGateCall(ContinuousClock.now - started) }
        switch gate {
        case .secure?:
            return .abortSecure
        case .secureUnknown?:
            volatileMasked = true
            return .show("")
        case .unknown? where ledger.fieldIdentity != nil:
            // session 起點有 AX 焦點，現在卻問不出來（含逾時）＝不知道焦點在哪：fail closed。
            volatileMasked = true
            return .show("")
        case .unknown?, .same?, .different?, .none:
            return .show(text)
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
        // issue #85：排隊中結束的是**上一段**的串流。先把排隊的錄音取出來、相位退回排空窗，
        // 下面照一般的排空結束收尾舊 session（archiveSession 看到的是 `.finishing`，不會停掉排隊的錄音），
        // 收完才接手。
        var queued: QueuedCapture?
        switch internalPhase {
        case .idle, .lingering:
            return
        case .listening, .finishing:
            break
        case .queued(let q):
            queued = q
            internalPhase = .finishing
        }
        // issue #70：錄音中 ASR 串流自己結束（沒先送 `.failed`，例如麥克風斷線）會從 `.listening` 直接進延續窗，
        // 不經 `endListening`。不再收音，監看到此為止；finishing 進來時早已停過，這裡是 no-op。
        // 排隊中還在錄的話這裡會停掉它的監看——接手的 `startListening` 在同一個 MainActor turn 內重新掛上並補查一次。
        stopFocusWatch()
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
        //
        // issue #10：只略過了字幕罐頭語、沒有任何真的文字，同樣沒有東西可修正——比照上面取代延續窗。
        // 有真的文字時照常進延續窗，提示疊在上面（notice 過期後畫面回到「可修正」）：
        // 略過的那句若其實是使用者說的，不提示就會無聲消失。
        var notice: String?
        if !sawTextThisSession, sawNoSpeechWarning || sawCaptionHallucination {
            archiveAfterDrain = false
            archiveSession()
        } else if archiveAfterDrain || ledger.frozen || !ledger.isActive {
            archiveAfterDrain = false
            archiveSession()
        } else {
            internalPhase = .lingering(until: t + Self.lingerWindow)
            if queued == nil { hud.present(.lingering) }   // 馬上就要接手，不閃一下「可修正」
        }
        // 兩者都有時講罐頭語：示警之後辨識器解出了東西，代表後來確實有聲音進來，
        // 「麥克風可能太遠」反而會讓使用者往錯的方向調。
        if sawCaptionHallucination {
            notice = Self.captionHallucinationNotice
        } else if sawNoSpeechWarning, !sawTextThisSession {
            notice = Self.noSpeechNotice
        }
        if let queued {
            resumeQueued(queued, at: t, oldSessionNotice: notice)
        } else if let notice {
            hud.present(.notice(notice))
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

    /// 進入 `.listening` 的唯一入口。`recorded`＝issue #85 排隊時已錄好的音訊（由 `resumeQueued` 傳入）：
    /// 不再開麥克風，直接交給辨識器；其餘與當下按下熱鍵完全相同（密碼欄拒絕、續聽或開新 session、監看與補查）。
    /// 進來時的相位只會是 idle 或 lingering——排空窗中按下走 `queueCapture`，不經這裡。
    private func startListening(mode: ListeningMode, at t: TimeInterval, recorded: QueuedCapture? = nil) {
        // 密碼欄位拒絕（規格 §5.3）：不錄音、不送 LLM、不開 session
        let field = fieldReader?.snapshot() ?? FieldContext()
        if field.isSecure {
            // 延續窗中改在密碼欄按下：封存前一 session（含清除 session 級語系覆蓋，設計裁決 4）。
            // hud.present 須在 archiveSession（會發 .hidden）之後，否則 notice 被蓋掉。
            // issue #85：排隊的錄音接手時焦點已在密碼欄——錄好的音訊一個字都不辨識，還在錄的話停掉。
            releaseFieldLease(field.fieldIdentity)   // 不開 session：token 不採用
            if recorded?.mode != nil { audio.stop() }
            archiveSession()
            hud.present(.notice("密碼欄位不聽寫"))
            return
        }
        do {
            readerTask?.cancel()
            let resuming = isLingering && ledger.isActive   // 延續窗內＝同 session 續聽
            if resuming {
                // 同 session 不重新 begin，ledger 沿用起始 identity；這次 snapshot 的 token 不採用、當場歸還（issue #43）
                releaseFieldLease(field.fieldIdentity)
            }
            coordinator.reset()
            segmenter.sessionStarted(at: t)
            archiveAfterDrain = false
            sawNoSpeechWarning = false
            sawTextThisSession = false
            sawCaptionHallucination = false
            // issue #65：遮罩是「本段」的。走到這裡代表上面的密碼欄拒絕沒觸發——人還在密碼欄時不會重置。
            volatileMasked = false
            capturedContextBefore = field.contextBefore
            capturedContextAfter = field.contextAfter
            if !resuming {
                if field.hasSelection, let range = field.selectedRange, let original = field.selectedText {
                    // 選取即目標：anchor＝選取起點，帳本以原選取文字為種子（undo 可回到它）
                    sessionTarget = .selectionPending(range: range, original: original)
                    ledger.begin(axAnchor: range.location, fieldIdentity: field.fieldIdentity, initialText: original)
                    coordinator.beginSession(anchor: range.location, identity: field.fieldIdentity, initialText: original)
                } else {
                    sessionTarget = .tail
                    // axAnchor 為 UTF-16 單位、fieldIdentity 為 reader 登記的 element token（issue #43）——兩者僅 AX 路徑使用。
                    // ledger 與 coordinator 從同一次 snapshot 取值：ledger 記 session 事實，coordinator 拿它做物理寫入（issue #44）
                    ledger.begin(axAnchor: field.caretLocation, fieldIdentity: field.fieldIdentity)
                    coordinator.beginSession(anchor: field.caretLocation, identity: field.fieldIdentity)
                }
                capturedFrontAppName = field.frontAppName
                capturedFrontAppBundleID = field.frontAppBundleID
                if settings.historyEnabled, let history {
                    let hid = UUID().uuidString
                    historySessionID = hid
                    let kind = { if case .selectionPending = sessionTarget { return "selection" }; return "tail" }()
                    history.beginSession(.init(id: hid, startedAt: now(),
                                               appBundleID: field.frontAppBundleID,
                                               appName: field.frontAppName,
                                               targetKind: kind, finalText: nil))
                }
                // OCR 螢幕語境（規格 §4.7）：由設定的模式決定是否截圖——`.fallback` 僅在 AX 讀不到
                // 前後文時動用、`.always` 一律附加；非同步，結果趕上哪句算哪句。
                capturedOCRText = nil
                ocrTask?.cancel()
                ocrTask = nil
                if settings.ocrContextMode.shouldCapture(contextBefore: field.contextBefore,
                                                         contextAfter: field.contextAfter,
                                                         isSecure: field.isSecure),
                   let contextOCR {
                    ocrTask = Task { [weak self] in
                        let text = await contextOCR()
                        await MainActor.run { self?.capturedOCRText = text }
                    }
                }
            }
            sessionID &+= 1
            let sid = sessionID
            let audioStream = try recorded.map { Self.concatenate($0.segments) } ?? audio.start()
            let events = asr.start(audio: audioStream, localeIdentifier: settings.asrLocaleIdentifier)
            internalPhase = .listening(mode)
            // issue #70：錄音從這裡開始，焦點監看也從這裡開始。
            startFocusWatch()
            // 上面的 snapshot 到 observer 掛上之間（含 `audio.start()`，藍牙麥克風可達數百毫秒）焦點若移進密碼欄，
            // 那則 AX 通知發出時 observer 還不存在，**根本不會送過來**。掛上之後補查一次「此刻」焦點，
            // 之後的任何移動就都有通知可收。硬停時 readerTask 還沒建立，辨識串流直接隨 `asr.cancel()` 丟掉。
            if abortIfFocusMovedBeforeWatching() { return }
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
        stopFocusWatch()             // issue #70：不再收音，監看到此為止（排空中的定稿全是錄音期間說的）
        flushVolatileGateStats()     // 排空窗不呈現暫時文字，本段量測到此為止
        hud.present(.hidden)
    }

    // MARK: - issue #85：排空中按下＝先錄、等排空跑完再接手

    /// 排空窗中（或排隊中已放開又）按下熱鍵：開麥克風錄進新的一條，辨識等排空結束才接手（`resumeQueued`）。
    ///
    /// 密碼欄比照 `startListening`：按下當下焦點在密碼欄（含問不出來的 `.secureUnknown`，#59 fail closed）就不錄，
    /// 並照舊封存舊 session——之後才送達的舊定稿在 idle 被相位守衛丟掉、只留字數（#20／#10）。
    /// 用輕量閘門而不 snapshot：接手時 `startListening` 會再 snapshot 一次，那時的游標才是續聽或新 session 的
    /// 正確起點（舊串流剩下的定稿還會把游標往後推），這裡先 snapshot 只會多付一次 AX IPC。
    /// 錄音開始後的焦點移動由監看負責，與 `.listening` 相同。
    private func queueCapture() {
        switch fieldReader?.fieldGate(sessionIdentity: ledger.fieldIdentity) {
        case .secure?, .secureUnknown?:
            archiveSession()
            hud.present(.notice("密碼欄位不聽寫"))
            return
        case .same?, .different?, .unknown?, nil:
            break
        }
        var queued = QueuedCapture(segments: [], mode: nil)
        if case .queued(let q) = internalPhase { queued = q }
        do {
            queued.segments.append(try audio.start())
        } catch {
            // 麥克風開不起來：排空照常跑完（舊 session 的字不受影響），只是這次按下沒有錄到東西
            hud.present(.notice("無法啟動麥克風"))
            return
        }
        queued.mode = .hold
        internalPhase = .queued(queued)
        startFocusWatch()
        if abortIfFocusMovedBeforeWatching() { return }
        presentListening(mode: .hold, volatile: "")
    }

    /// 排隊中放開熱鍵（issue #85）：這一條錄完了，比照 `endListening` 停麥克風與監看；辨識照舊等排空結束才接手。
    /// 畫面顯示「辨識中…」：使用者已經說完，在等的就是辨識（先是上一段的排空，接著才是這一段）。
    private func endQueuedCapture(_ q: QueuedCapture) {
        var q = q
        audio.stop()
        stopFocusWatch()
        q.mode = nil
        internalPhase = .queued(q)
        hud.present(.transcribing)
    }

    /// 上一段的串流結束（或失敗），接手排隊的錄音（issue #85）。呼叫端已把舊 session 收尾成延續窗（同 session 續聽）
    /// 或 idle（舊 session 已封存，開新 session）——與「排空跑完才按下」走同一條 `startListening`，
    /// 密碼欄拒絕、續聽／開新 session、監看與補查全部一樣。
    ///
    /// `oldSessionNotice`：舊 session 收尾時要告訴使用者的事（辨識失敗、沒偵測到語音）。接手會立刻把畫面換成錄音中，
    /// 一般 notice 會被蓋掉，所以走救援提示的通道（`HUDArbiter` 保證至少停留 2 秒，期間的狀態延後重播），
    /// 而且必須在接手**之前**送出，接手發的狀態才會被延後。
    private func resumeQueued(_ q: QueuedCapture, at t: TimeInterval, oldSessionNotice: String?) {
        if let oldSessionNotice { hud.presentRescueNotice(oldSessionNotice) }
        let resuming = isLingering && ledger.isActive      // 只供 log：與 startListening 的判斷同一式
        startListening(mode: q.mode ?? .hold, at: t, recorded: q)
        let started: Bool
        if case .listening = internalPhase { started = true } else { started = false }
        // 已經放開：錄音早就收完，直接進排空（與放開熱鍵同一個 `endListening`）
        if started, q.mode == nil { endListening(at: t) }
        // 只記數字與分類（#10）。真實使用中多常排隊、等多久，日後回頭看靠的就是這一行。
        // **這行沒有測試覆蓋**：os_log 的輸出無法在單元測試裡攔截。
        Self.sessionLog.notice("""
            排空中按下的錄音已接手：\(q.segments.count, privacy: .public) 條，\
            \(started ? (resuming ? "同 session 續聽" : "開新 session") : "未接手（已封存）", privacy: .public)，\
            \(q.mode == nil ? "已放開" : "仍在錄", privacy: .public)
            """)
    }

    /// 依序串接排隊期間錄的每一條音訊（issue #85）。只有一條時原樣交出，不多一層轉送。
    /// 消費端取消（Esc、硬停）時轉送的 Task 跟著取消。
    nonisolated static func concatenate(_ streams: [AsyncStream<AudioChunk>]) -> AsyncStream<AudioChunk> {
        if streams.count == 1 { return streams[0] }
        return AsyncStream { continuation in
            let task = Task {
                for stream in streams {
                    for await chunk in stream { continuation.yield(chunk) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// issue #65 量測輸出（裁定 Q7）：**只有數字與旗標**，以 debug 等級輸出（Release 預設不落地）。
    /// 事件數為 0 不輸出。輸出後歸零，下一段從頭算。
    /// 判讀：多段 log 彙整出「事件/秒 p95 × 閘門耗時 p95」，超過 20ms/s 再開節流 follow-up。
    private func flushVolatileGateStats() {
        let s = volatileGateStats
        volatileGateStats = VolatileGateStats()
        guard s.events > 0 else { return }
        lastFlushedVolatileGateStats = s
        let span = (s.lastAt ?? 0) - (s.firstAt ?? 0)
        Self.hudLog.debug("""
            volatile gate: events=\(s.events, privacy: .public) gateCalls=\(s.gateCalls, privacy: .public) \
            maxPerSecond=\(s.maxPerSecond, privacy: .public) \
            maxGateMs=\(s.maxGateSeconds * 1000, format: .fixed(precision: 3), privacy: .public) \
            spanSeconds=\(span, format: .fixed(precision: 2), privacy: .public) \
            masked=\(s.masked, privacy: .public) aborted=\(s.aborted, privacy: .public)
            """)
    }

    private func endSession(at t: TimeInterval) {
        archiveAfterDrain = true     // 60 秒靜音逾時走這裡
        endListening(at: t)
    }

    /// issue #70：開始本段錄音的焦點監看。只從開始錄音的兩個點呼叫：`startListening` 進入 `.listening`、
    /// `queueCapture` 進入排隊錄音（issue #85）。
    /// 理論上進來時不會有殘留的 watch（每條離開錄音的路徑都會停）；萬一有，先停掉舊的再開，
    /// 寧可多停一次也不讓兩個 observer 並存。
    private func startFocusWatch() {
        stopFocusWatch()
        guard let focusWatcher else { return }
        let epoch = focusWatchEpoch
        focusWatch = focusWatcher.startWatching { [weak self] security in
            self?.focusChanged(to: security, epoch: epoch)
        }
    }

    /// issue #70：補 snapshot 到 observer 掛上之間的空窗（見 `startListening`）。回傳 true＝已硬停。
    /// 沒有監看者時不查：那時沒有空窗可補，也不多付一次 AX IPC（行為與 #70 之前逐位元相同）。
    /// `.secureUnknown` 比照監看回呼：硬停＋只留 metadata，來源標 `via:watchStart`。
    private func abortIfFocusMovedBeforeWatching() -> Bool {
        guard focusWatch != nil else { return false }
        switch fieldReader?.fieldGate(sessionIdentity: ledger.fieldIdentity) {
        case .secure?:
            abortForSecureField()
            return true
        case .secureUnknown?:
            recordInsertEvent(kind: "insertSkipped", classification: "secureUnknown",
                              utteranceText: "",
                              detail: "sessionApp:\(capturedFrontAppBundleID ?? "?") via:watchStart")
            abortForSecureField()
            return true
        case .same?, .different?, .unknown?, nil:
            return false
        }
    }

    /// issue #70：停止監看並作廢它之後送來的任何通知。冪等：沒有 watch 時只遞增世代，不呼叫任何人——
    /// 每個 handle 恰 `stop()` 一次（比照 #43 lease），由 `focusWatch = nil` 保證。
    private func stopFocusWatch() {
        focusWatchEpoch &+= 1
        guard let watch = focusWatch else { return }
        focusWatch = nil                // 先清再 stop：stop 若同步回呼（或從 callback 內被呼叫），不會再停一次
        watch.stop()
    }

    /// issue #70：焦點移動的那一刻，AX 推來**新焦點元素本身**的判定。
    ///
    /// 事件驅動的兩道閘門（暫時文字、定稿）只在事件抵達時查「此刻」的焦點；焦點在兩個事件之間進出密碼欄 P，
    /// 它們就只看得到一般欄位。這裡是唯一看得到那次移動的點，所以一律在這裡就決定，不留給事後：
    /// - `.secure`：硬停，與兩道既有閘門的 `.secure` 同一個 `abortForSecureField()`、同樣不記 insertEvent。
    ///   `segmenter.hardReset()`＋`asr.cancel()`＋`audio.stop()`：P 期間的聲音還在辨識器裡的直接丟掉，
    ///   之後的不再收。AX 通知**通常**在焦點移動後數毫秒內送達，遠早於辨識器吐出那段話（≥ 數百毫秒）。
    ///   例外是主執行緒被卡住（同步 AX IPC 逾時等）：放開熱鍵的事件可能先於「進入 P」的通知被處理，
    ///   那則通知會被當成舊 watch 的遲到通知丟掉——已知邊界，寫在 PR。
    /// - `.secureUnknown`：依 #59 fail closed，同樣硬停。**不比照暫時文字閘門只遮罩**——那條路的內容層保護交給
    ///   事後的定稿閘門，而 #70 的前提正是事後看不到這次移動。只留 metadata（#10），來源標 `via:focusChange`。
    /// - `.notSecure`：不攔。換到別的一般欄位由寫入前那道閘門處理（`.different`），這裡不重複記。
    ///
    /// 世代對不上（舊 watch 的遲到通知）或已不在錄音中：一律忽略。
    private func focusChanged(to security: FocusedFieldSecurity, epoch: Int) {
        guard epoch == focusWatchEpoch, isRecording else { return }
        switch security {
        case .notSecure:
            return
        case .secure:
            abortForSecureField()
        case .secureUnknown:
            // **必須先記再 abort**：archive 會把 `historySessionID` 清成 nil，沒有 hid 的列會整筆靜默丟掉。
            recordInsertEvent(kind: "insertSkipped", classification: "secureUnknown",
                              utteranceText: "",
                              detail: "sessionApp:\(capturedFrontAppBundleID ?? "?") via:focusChange")
            abortForSecureField()
        }
    }

    /// 歸還一個 snapshot 發出的 identity token（issue #43）。nil＝reader 沒給（無 AX），沒東西可還——
    /// 不呼叫 reader，讓「每個非 nil token 恰歸還一次」這條不變式在測試裡乾淨可驗。
    private func releaseFieldLease(_ identity: FieldIdentity?) {
        guard let identity else { return }
        fieldReader?.releaseFieldIdentity(identity)
    }

    private func archiveSession() {
        // issue #85：排隊中封存（Esc、密碼欄硬停、在密碼欄又按下）＝排隊的錄音一併丟棄，還在錄的話停掉麥克風
        // （`audio.stop()` 冪等，硬停路徑先停過一次也無妨）。要保住它的路徑（舊串流結束或失敗）
        // 會先把它取出來、相位退回 `.finishing` 才呼叫這裡。
        if case .queued(let q) = internalPhase, q.mode != nil { audio.stop() }
        archivedHistorySessionID = historySessionID   // 無條件覆寫（含 nil），理由見宣告處（issue #20）
        // 定稿入史（規格 §4.9）：ledger.archive() 會清空 sessionText，故先抓最終全文。
        if let hid = historySessionID {
            let final = ledger.sessionText
            history?.finishSession(id: hid, finalText: final.isEmpty ? nil : final)
            historySessionID = nil
        }
        ocrTask?.cancel()
        ocrTask = nil
        capturedOCRText = nil
        flushVolatileGateStats()            // issue #65 量測：Esc／暫時文字硬停／定稿硬停等直達封存的路徑
        stopFocusWatch()                    // issue #70：直達封存的路徑（Esc、硬停、ASR 失敗）不經 endListening
        // 歸還 begin 時登記的 element token（issue #43）：必須在 ledger.archive() 清掉它之前。
        // registry 有引用計數，FeedbackCoordinator 若也 pin 了同一 element，這裡只減 ledger 那一份。
        releaseFieldLease(ledger.fieldIdentity)
        ledger.archive()
        coordinator.endSession()            // 鏡像／anchor／identity 隨 session 清空（issue #44）
        feedback?.sessionEnded()            // 封存：overlay 立即隱藏
        internalPhase = .idle
        hud.present(.hidden)
        sessionTarget = .tail               // 封存即重置目標模式
        // issue #37：閘門跳過旗標必須隨 session 結束一起歸零。
        // 它平常在 processUtterance(raw:) 捕捉後立即重設，但 Esc 聽寫中（:201）／
        // abortForSecureField／handleASRFailure 三條路徑都會 segmenter.hardReset()，把待閉合的
        // raw 直接丟掉——那句話永遠走不到 processUtterance，旗標就一路留 true 洩漏到下一個
        // session，害新 session 的第一句（焦點完全正常、字也確實上屏）在 dispatch 被誤判早退：
        // 潤飾被無聲丟棄（無 notice、無剪貼簿救援），還多記一列假的 outcomeDropped 污染遙測。
        // 三條路徑最終都會走到這裡，補這一個點就夠；正常結束路徑是先捕捉再 archive，不會誤殺。
        skippedRaw = false
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
    ///
    /// issue #85：排隊中失敗的是**上一段**——排隊的錄音還沒交給辨識器，不是失敗的那一段。
    /// 錄音不停、先取出來，舊 session 照常封存，再接手成新 session；失敗提示交給 `resumeQueued` 走救援提示通道，
    /// 否則接手的錄音畫面會立刻蓋掉它（批次引擎的上傳失敗＝整段話沒了，這則提示是使用者唯一的線索）。
    private func handleASRFailure(reason: String, at t: TimeInterval) {
        segmenter.hardReset()
        asr.cancel()
        let notice = "辨識失敗（\(reason)）"
        if case .queued(let q) = internalPhase {
            internalPhase = .finishing
            archiveSession()
            resumeQueued(q, at: t, oldSessionNotice: notice)
            return
        }
        audio.stop()
        archiveSession()
        hud.present(.notice(notice))
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
        // 這句話有沒有片段被寫入前的閘門攔掉（issue #37）：捕捉當下值後立即重設，下一句從乾淨狀態算起
        let utteranceSkippedRaw = skippedRaw
        skippedRaw = false
        // 這句話屬於哪個歷史 session（issue #11）：**話語閉合當下**就決定，與 `generation` 同一個捕捉點。
        // outcome 回來時 session 可能已封存（`historySessionID` 已清空）、甚至已開了下一個 session
        // （`historySessionID` 是別人的）——用回來當下的值，前者零紀錄、後者記錯 session。
        // nil＝閉合當下就沒在記錄（歷史關閉），之後也不補記、更不借用別的 session 的 id。
        let utteranceHistoryID = historySessionID
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
                              generation: generation, historyID: utteranceHistoryID,
                              wasBuffered: wasBuffered, skippedRaw: utteranceSkippedRaw)
            }
        }
    }

    private func dispatch(_ outcome: IntentOutcome,
                          snapshot: InsertionCoordinator.UtteranceSnapshot,
                          sessionBefore: String,
                          generation: Int,
                          historyID: String?,
                          wasBuffered: Bool,
                          skippedRaw: Bool) {
        pendingIntents = max(0, pendingIntents - 1)
        let utteranceRaw = snapshot.text.isEmpty ? sessionBefore : snapshot.text
        // 歷史記錄（規格 §4.9）：丟棄的 outcome 也入史——回查除錯正是要看見被丟棄的（守衛之前記）。
        // 掛在話語閉合當下的 session（`historyID`，issue #11），不是回來當下的 `historySessionID`。
        if settings.historyEnabled, let hid = historyID {
            history?.recordExchange(.init(sessionID: hid, at: now(),
                                          utteranceRaw: utteranceRaw,
                                          outcomeKind: outcome.historyKind, outcomeText: outcome.historyText))
        }
        // issue #37 裁定 Q4：這句話有片段被寫入前的閘門攔掉（根本沒上屏），LLM 的 outcome 一律安靜丟棄。
        //
        // **「部分片段被跳過」也走這裡，而且正是它逼出這條規則**：`snapshot.text` 只含實際落地的片段，
        // 但送 LLM 的 raw（來自 segmenter）含**全部**片段。照常潤飾的話，`replaceTail` 會拿一句
        // 含「被跳過那段」的潤飾文字，去替換較短的鏡像尾端——等於把我們剛剛拒絕寫入的內容
        // 從潤飾路徑偷渡回欄位，與 Q1 的 fail closed 直接矛盾。代價是部分落地的那句失去潤飾（維持 raw）。
        //
        // 只記診斷、**不發第二則提示、不再進剪貼簿**：使用者在跳過的當下已經被告知內容在剪貼簿了。
        if skippedRaw {
            // 掛在話語閉合當下的 session（`historyID`），所以**不需要**世代守衛：時序
            // 「session A 部分跳過、LLM 卡住 → Esc 封存 A → 開 session B 並說完一句（B 有自己的 hid）
            // → A 的舊 outcome 才回來」下，這筆診斷照樣落在 A 底下，不會變成 B 的。
            // （以前用的是**呼叫當下**的 `historySessionID`，只能靠世代守衛乾脆不記——A 的跳過因此零紀錄，issue #11。）
            recordHistoryEvent(sessionID: historyID, kind: "outcomeDropped", classification: "skippedRaw",
                               utteranceText: utteranceRaw)
            // **部分片段被跳過時，落地的那段仍須入帳**。`snapshotAndBeginNext()` 已經把它從
            // `coordinator.currentUtteranceText` 移進 snapshot，早退若直接 return，那段字就只存在於
            // 欄位與 `coordinator.displayedText`（鏡像），`ledger.sessionText` 從頭到尾沒認過它。兩個後果：
            // ① `archiveSession()` 拿 `ledger.sessionText` 當 History 的 finalText，會少掉這一段；
            // ② 更嚴重：下一句若是 `.editedSession`，會拿偏小的 `ledger.sessionText` 當改寫基準，
            //    而 AX 驗證用的是正確的 `displayedText`、照樣通過——整段被以錯誤基準算出來的文字覆寫。
            //
            // 形態比照 `keepRawWithoutVersion`（:1093）：只同步觀測到的尾端、**不推版本**——
            // 這句沒有潤飾成果可記（outcome 剛被丟棄），也就沒有東西可以復原。
            //
            // 世代守衛不可省：`SessionLedger.synchronizeObservedTail` 無條件覆寫 `sessionText`，
            // 而本早退**位在下面那道 `guard ledger.isActive, ledger.generation == generation` 之前**
            // （`keepRawWithoutVersion` 沒有這個問題，它一律在世代守衛之後才被呼叫）。少了世代條件，
            // 「session A 部分跳過 → 使用者按 Esc／封存 → 開了 session B → A 的舊 outcome 這時才回來」
            // 會把 A 的片段寫進 B 的帳本。
            //
            // 早退本身**不移到世代守衛之後**：那會讓「緩衝句＋被跳過」的組合走進 stale-generation 分支
            // 而多做一次剪貼簿救援（使用者在跳過的當下已經救過一次了）。
            if !snapshot.text.isEmpty, ledger.isActive, ledger.generation == generation {
                ledger.synchronizeObservedTail(ledger.sessionText + snapshot.text)
            }
            return
        }
        // 世代檢查：archive→begin 之後，舊 session 在途的 outcome 一律丟棄——
        // 不能用 sessionID（延續窗 resume 也跳號，會誤殺同 session 的合法在途潤飾）。
        // 但緩衝句（選取模式）的 outcome 不能無聲蒸發：它的原文從未上屏，丟棄＝使用者白說話。
        // 典型時序：說完指令→放開→進延續窗→點別處（延續窗活動＝立即封存）→LLM 此刻才回來。
        // 規格 §3.6「放棄替換，結果進 HUD 供複製」：救進剪貼簿＋提示（實機回報的驗收缺口）。
        //
        // 歷史（issue #11）：上面那列 outcome 只說「LLM 回了什麼」，看起來跟有落地的一模一樣。
        // 緊接著補一列說明它的下場，分類 `sessionEnded`（session 已封存，或已被下一個 session 取代）：
        // 救進剪貼簿的記 `insertSkipped`（內容沒丟，是沒寫進欄位——與其他救援出口同一個 kind），
        // 其餘記 `outcomeDropped`。HUD 照舊不發：封存是使用者自己的動作（點別處、Esc），不是錯誤。
        guard ledger.isActive, ledger.generation == generation else {
            if wasBuffered, lastRescueGeneration != generation {
                switch outcome {
                case .newContent(let text), .editedSession(let text):
                    lastRescueGeneration = generation
                    // round 用捕捉到的 `generation`，**不是** `ledger.generation`：這條分支的前提就是
                    // 世代已過期，救的是**舊 session** 的內容，而使用者此刻可能已經開了新 session
                    // （`ledger.generation` 已跳號）。用當下的世代會讓這段舊內容被當成新 session 的
                    // 同一輪而串在它的救援後面——round token 要防的正是這件事。
                    recordHistoryEvent(sessionID: historyID, kind: "insertSkipped", classification: "sessionEnded",
                                       utteranceText: utteranceRaw)
                    rescueToClipboard(text, round: generation)
                    presentRescueNotice("選取已變動，結果已入剪貼簿")
                    return
                case .undo, .degraded:
                    break                              // 無內容可救，安靜丟棄即可
                }
            }
            recordHistoryEvent(sessionID: historyID, kind: "outcomeDropped", classification: "sessionEnded",
                               utteranceText: utteranceRaw)
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
                    rescueToClipboard(text)
                    presentRescueNotice("已凍結，內容已入剪貼簿")
                    return
                }
                do {
                    switch try coordinator.insertDetached(text) {
                    case .inserted:
                        ledger.appendPolished(text)
                        emitFeedback()                     // 緩衝後續句落地：底線延伸至新內容
                    case .fieldChanged(let currentAppBundleID):
                        // 焦點已換（issue #37）：比照本處既有的失敗路徑——救進剪貼簿並提示。
                        // 這裡處理的已經是 LLM outcome 本身，沒有「之後還要丟棄 outcome」的問題，
                        // 故不設 skippedRaw。
                        recordInsertEvent(kind: "insertSkipped", classification: "fieldChanged",
                                          utteranceText: text,
                                          detail: fieldChangeDetail(current: currentAppBundleID))
                        rescueToClipboard(text)
                        presentRescueNotice(Self.fieldChangedNotice)
                    case .secureField(let subroleUnknown):
                        // 焦點已切進密碼欄，或 AX 問不出 subrole 而 fail closed（規格 §5.3／issue #59）：
                        // 與 finalized 那條逐字相同——記診斷後**硬停整個 session**。
                        // 分類與 `fieldChanged` 分開：密碼欄位攔阻不得混進那組誤判率分母。
                        // `utteranceText` 一律留空（可能是密碼欄，不得在 `history_exchange` 留下明文）。
                        //
                        // **預設不救剪貼簿**：這句的內容雖然是使用者對欄位 A 說的、且已經過 LLM，
                        // 但它的 raw 走的是同一個 segmenter，同樣可能含焦點已在密碼欄期間說出的片段——
                        // 證明不出「不可能含密碼」，就照裁定的預設不救。損失與「下一句撞到 `:341`」相同。
                        //
                        // **順序不可對調**：archive 會把 `historySessionID` 清成 nil，診斷排在後面會整筆丟掉。
                        if subroleUnknown {
                            recordInsertEvent(kind: "insertSkipped", classification: "secureUnknown",
                                              utteranceText: "",
                                              detail: "sessionApp:\(capturedFrontAppBundleID ?? "?")")
                        } else {
                            recordInsertEvent(kind: "insertSkipped", classification: "secureField",
                                              utteranceText: "")
                        }
                        abortForSecureField()
                    }
                } catch {
                    // 與 raw 定稿插入失敗那條一致（issue #20）：記一列 `insertFailed`，分類標 `buffered`。
                    recordInsertEvent(kind: "insertFailed", classification: "buffered",
                                      utteranceText: text, detail: "\(error)")
                    rescueToClipboard(text)
                    presentRescueNotice("插入失敗，內容已入剪貼簿")
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
                rescueToClipboard(snapshot.text)
                presentRescueNotice("未處理（\(reason)），轉錄已入剪貼簿")
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
        // 替換前的欄位鏡像（raw 已上屏）。必須含 currentUtteranceText——回收路徑走到這裡時，
        // 下一句的原文已經落在螢幕上；漏掉它會讓 diff 把使用者還沒被碰的那句也框成「剛改動」。
        // 一般路徑的 currentUtteranceText 是空的，加了不影響。
        let old = ledger.sessionText + snapshot.text + coordinator.currentUtteranceText
        switch coordinator.replaceTail(snapshot, with: text) {
        case .replaced:
            ledger.appendPolished(text)            // 只有這一句取得 polished 身分（#46）
            emitFeedback(oldText: old)             // 潤飾異動高亮
        case .tailAdvanced:
            if recoverStaleTail(text, snapshot: snapshot, previousMirror: old) { return }   // 就地回收（M10-C）
            recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                              utteranceText: snapshot.text)
            keepRaw(snapshot, notice: insertSkipNotice(.tailAdvanced))
        case .unverified:
            // 無 anchor／identity／AX 能力（issue #44）：什麼都沒動，raw 留在欄位上、帳本照鏡像入帳。不凍結——
            // 這是沒給 AX 權限的 App 的常態，凍結會連後續的純追加上屏都停掉（PR #36 被否決的原因）。
            recordInsertEvent(kind: "insertSkipped", classification: "unverified", utteranceText: snapshot.text)
            keepRaw(snapshot, notice: insertSkipNotice(.unverified))
        case .fieldMismatch:
            // 欄位內容或聚焦元素已不是我們寫的那個：raw 仍在鏡像裡、同步帳本後凍結——之後的改寫沒有可信的位置
            recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch", utteranceText: snapshot.text)
            ledger.synchronizeObservedTail(ledger.sessionText + snapshot.text)
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("欄位已被外部改動，本段停止修正"))
        }
    }

    private func applyCorrection(_ corrected: String, commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else {
            recordInsertEvent(kind: "insertSkipped", classification: "frozen",
                              utteranceText: commandSnapshot.text)
            hud.present(.notice("已凍結，未修正")); return
        }
        let old = ledger.sessionText + commandSnapshot.text   // 修正前全文＋指令話語（皆已上屏）
        switch coordinator.replaceSession(commandSnapshot: commandSnapshot, with: corrected) {
        case .replaced:
            ledger.commit(corrected)
            hud.present(.notice("已修正"))
            emitFeedback(oldText: old)             // 修正異動高亮
        case .tailAdvanced:
            recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                              utteranceText: commandSnapshot.text)
            keepRaw(commandSnapshot, notice: "未修正（新內容已接續）")   // 指令話語留在欄位，視為內容鏡像
        case .unverified:
            // 無 anchor／identity／AX 能力（issue #44）：舊契約在此退回 keystroke 盲退格，現在什麼都不動、只提示
            recordInsertEvent(kind: "insertSkipped", classification: "unverified",
                              utteranceText: commandSnapshot.text)
            keepRaw(commandSnapshot, notice: "未修正（無法確認文字位置）")
        case .fieldMismatch:
            recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                              utteranceText: commandSnapshot.text)
            // 一個字都沒動（issue #38／#44 的原子契約）＝指令話語仍完整留在畫面上。帳本若不鏡像它，
            // 它就成了追蹤不到的孤兒：archiveSession 的 finalText 與底線範圍都會少這一段（issue #40）。
            // 不建版本——我們什麼都沒改寫，沒有東西可復原。與 applyNewContent 及 performUndo
            // 無步驟版的 fieldMismatch 出口一致。
            if !commandSnapshot.text.isEmpty {
                ledger.synchronizeObservedTail(ledger.sessionText + commandSnapshot.text)
            }
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("欄位已被外部改動，本段停止修正"))
        }
    }

    private func dispatchSelection(_ outcome: IntentOutcome, range: FieldContext.SelectedRange,
                                   original: String, commandRaw: String) {
        switch outcome {
        case .newContent(let text), .editedSession(let text):
            applySelectionReplacement(text, range: range, original: original)
        case .undo:
            hud.present(.notice("沒有可復原的內容"))
        case .degraded(let reason):
            // M3 設計裁決 4：LLM 失敗不動選取（寧可不動不可亂改），轉錄入剪貼簿
            rescueToClipboard(commandRaw)
            presentRescueNotice("未替換（\(reason)），轉錄已入剪貼簿")
        }
    }

    /// 一次性替換選取範圍。三種結局（M3 設計裁決 3，#21 裁定 2 改第三種）：
    /// replaced＝轉常規 session；selectionChanged＝放棄、結果入剪貼簿、封存；
    /// unsupported＝無法用 AX 確認選取，同樣不動欄位、結果入剪貼簿、封存（#45）。
    private func applySelectionReplacement(_ text: String, range: FieldContext.SelectedRange, original: String) {
        guard !ledger.frozen else {                 // 聽寫中手動活動已凍結：選取完整性不明，放棄
            abandonSelectionReplacement(text, classification: "frozen", notice: "選取已變動，結果已入剪貼簿")
            return
        }
        switch coordinator.replaceSelection(location: range.location, expected: original, with: text) {
        case .replaced:
            ledger.commit(text)
            sessionTarget = .tail
            hud.present(.notice("已替換選取"))
            emitFeedback(oldText: original)           // 選取替換全 span 高亮
        case .selectionChanged:
            abandonSelectionReplacement(text, classification: "selectionChanged", notice: "選取已變動，結果已入剪貼簿")
        case .unsupported:
            // #21 裁定 2／#45：這是 destructive 清單裡唯一無法用驗證救的刪字路徑——它的觸發條件正是
            // 「熱鍵按下時讀得到選取，替換當下卻讀不到」＝焦點已跑。舊版改用 OS「打字覆蓋選取」盲寫再凍結，
            // 等於相信一個已經對不上的焦點，可能把字打進錯的欄位、蓋掉錯的選取。
            // 與其他所有刪字操作同一條規則：缺 verified AX 就不動欄位、只提示；內容進剪貼簿
            // （#42 起救援不會被 paste 的延遲還原洗掉）。代價：無 AX 範圍能力的 App 不支援選取即目標。
            abandonSelectionReplacement(text, classification: "unsupported", notice: "無法替換選取，內容已入剪貼簿")
        }
    }

    /// 剪貼簿救援的唯一出口（issue #42）：帶 round token 給 App 端的 ClipboardChannel，
    /// 它只把**同一輪**的救援串接起來，跨輪一律覆寫。round 用 `ledger.generation`——
    /// 一次聽寫 session 就是一輪，同一段話拆成多句救援才會連成一份可貼上的文字。
    /// 只有救「舊 session 的內容」時才明確傳 round（見 `dispatch` 的世代過期分支）。
    ///
    /// **配對的提示一律走 `presentRescueNotice(_:)`**（issue #61／#71，內部走 `hud.presentRescueNotice`）：內容沒上屏、唯一副本在剪貼簿，
    /// 使用者必須讀到才知道要去貼上。包在外面的 `HUDArbiter` 保證它至少停留 2 秒。
    /// 判準可機械驗證：同一個分支剛呼叫過本函式的那則 notice，才是救援提示。
    /// 刻意不把提示併進本函式（`rescueToClipboard(_:notice:)`）：`abandonSelectionReplacement` 要求
    /// 「先 archive、後提示」，合併會改動那個順序，arbiter 沒接上時反而退化成被 `.hidden` 蓋掉。
    private func rescueToClipboard(_ text: String, round: Int? = nil) {
        let round = round ?? ledger.generation
        lastRescueRound = round
        let outcome = clipboardRescue?(text, round)
        lastRescueNotWritten = outcome == .notWritten
        switch outcome {
        case .replacedEarlierRescue?:
            rescueDisplacingRound = round
        case .landed?:
            // 鏈斷了、重新開始：這一輪先前那次取代已經提示過，現在被蓋掉的是使用者自己的內容（既有行為，不提示）
            if rescueDisplacingRound == round { rescueDisplacingRound = nil }
        case .appended?, .notWritten?, nil:
            break                       // 同一條鏈延續（寫入失敗時剪貼簿也還是那條鏈）；沒接剪貼簿則無從判斷
        }
    }

    /// 救援提示的唯一出口（issue #61／#71）：一律走 `hud.presentRescueNotice`（2 秒最短顯示），
    /// 剛救的那一輪若覆寫了上一輪仍在剪貼簿裡的救援，接上 `replacedEarlierRescueSuffix`——
    /// 否則上一段的遺失沒有任何痕跡，畫面上只看得到這一段的提示。
    private func presentRescueNotice(_ message: String) {
        if lastRescueNotWritten {
            let phrase = "已入剪貼簿"
            hud.presentRescueNotice(message.contains(phrase)
                ? message.replacingOccurrences(of: phrase, with: Self.rescueNotWrittenPhrase)
                : message + "，" + Self.rescueNotWrittenPhrase)
            return
        }
        let displaced = lastRescueRound != nil && lastRescueRound == rescueDisplacingRound
        hud.presentRescueNotice(displaced ? message + Self.replacedEarlierRescueSuffix : message)
    }

    /// 放棄替換選取：不動欄位、結果進剪貼簿、封存、提示。三種成因（凍結／選取已變／無法用 AX 確認）同一套收尾，
    /// 只差診斷分類與文案。`lastRescueGeneration`：同世代之後回來的緩衝句 outcome 不得再救一次——
    /// #42 累積修訂後第二次救援是**接在後面**而不是蓋掉，少了這道守衛會把同一份內容重複串進剪貼簿。
    /// notice 必須在 archiveSession（會發 .hidden）之後，否則被蓋掉。
    private func abandonSelectionReplacement(_ text: String, classification: String, notice: String) {
        recordInsertEvent(kind: "insertSkipped", classification: classification, utteranceText: text)
        lastRescueGeneration = ledger.generation
        rescueToClipboard(text)
        archiveSession()
        presentRescueNotice(notice)
    }

    /// 復原上一步（口頭 undo 與 Task 9 的 HUD 按鈕共用）。
    private func performUndo(commandSnapshot: InsertionCoordinator.UtteranceSnapshot) {
        guard !ledger.frozen else {
            recordInsertEvent(kind: "insertSkipped", classification: "frozen",
                              utteranceText: commandSnapshot.text)
            hud.present(.notice("已凍結，無法復原")); return
        }
        guard let step = ledger.undo() else {
            // 沒步驟可回：把指令話語從欄位退掉（它不是內容）。
            switch coordinator.replaceTail(commandSnapshot, with: "") {
            case .replaced:
                // 指令話語已從欄位物理刪除，底線必須跟著縮回（issue #54）——它上屏時
                // emitFeedback() 已把底線延伸到它，這裡不重算就會罩著不存在的文字。
                emitFeedback()
                hud.present(.notice("沒有可復原的步驟"))
            case .unverified, .tailAdvanced:
                // 退不掉（無 verified AX／尾端已前進）就留著，並讓帳本鏡像它——不建版本，我們什麼都沒改寫
                if !commandSnapshot.text.isEmpty {
                    ledger.synchronizeObservedTail(ledger.sessionText + commandSnapshot.text)
                }
                hud.present(.notice("沒有可復原的步驟"))
            case .fieldMismatch:
                // 欄位或聚焦元素已不是我們寫的那個：與其他每個 fieldMismatch 出口一致——鏡像、凍結、提示
                recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                                  utteranceText: commandSnapshot.text)
                if !commandSnapshot.text.isEmpty {
                    ledger.synchronizeObservedTail(ledger.sessionText + commandSnapshot.text)
                }
                ledger.freeze()
                feedback?.sessionFrozen()
                hud.present(.notice("欄位已被外部改動，本段停止修正"))
            }
            return
        }
        switch coordinator.replaceSession(commandSnapshot: commandSnapshot, with: step.to) {
        case .replaced:
            hud.present(.notice("已復原"))
            emitFeedback(oldText: step.from)      // 復原後底線罩回舊版
        case .tailAdvanced:
            recordInsertEvent(kind: "insertSkipped", classification: "counterMismatch",
                              utteranceText: commandSnapshot.text)
            ledger.restoreFailedUndo(step)   // 帳本（含已潤飾鏡像）回滾成欄位實況
            keepRaw(commandSnapshot, notice: "未復原（新內容已接續）")
        case .unverified:
            recordInsertEvent(kind: "insertSkipped", classification: "unverified",
                              utteranceText: commandSnapshot.text)
            ledger.restoreFailedUndo(step)   // 帳本（含已潤飾鏡像）回滾成欄位實況（欄位一個字都沒動）
            keepRaw(commandSnapshot, notice: "未復原（無法確認文字位置）")
        case .fieldMismatch:
            recordInsertEvent(kind: "insertSkipped", classification: "fieldMismatch",
                              utteranceText: commandSnapshot.text)
            ledger.restoreFailedUndo(step)
            // 回捲後的鏡像＝復原前的全文，但欄位上還多了沒被退掉的指令話語——同樣要併回，
            // 否則它成為孤兒（issue #40）。restoreFailedUndo 之後才做：順序反了會被它蓋掉。
            if !commandSnapshot.text.isEmpty {
                ledger.synchronizeObservedTail(ledger.sessionText + commandSnapshot.text)
            }
            ledger.freeze()
            feedback?.sessionFrozen()
            hud.present(.notice("欄位已被外部改動，本段停止修正"))
        }
    }

    /// 焦點已換的診斷 detail（issue #37）。格式：
    /// - 同 App 內換欄位（Tab／maxlength 自動跳格／頁面 JS 搬焦點）：`sameApp:<bundleID>`
    /// - 跨 App（焦點被別的 App 搶走）：`crossApp:<session 起始 bundleID>→<現在的 bundleID>`
    /// 讀不到的 bundleID 一律寫 `?`——分不出同 App 或跨 App 時保守歸入 crossApp，
    /// 免得把「其實已經換 App」的樣本混進 sameApp 那組、低估風險。
    private func fieldChangeDetail(current: String?) -> String {
        if let session = capturedFrontAppBundleID, let current, session == current {
            return "sameApp:\(session)"
        }
        return "crossApp:\(capturedFrontAppBundleID ?? "?")→\(current ?? "?")"
    }

    /// 插入層事件補列（M7 §4）：kind 三分——insertFailed＝coordinator 拋錯（真 I/O 失敗；classification
    /// `raw`／`buffered` 標出是定稿上屏還是緩衝句落地，detail 帶錯誤，issue #20）、
    /// insertSkipped＝守衛拒絕（原文正確保留，非失敗；classification `fieldChanged` 即 issue #37
    /// 寫入前閘門攔下這一句、`secureUnknown` 即 AX 連兩次問不出 subrole 而 fail closed、
    /// `frozen` 即使用者已動手、`sessionEnded` 即緩衝句的 outcome 在 session 結束後才回來而改救剪貼簿）、
    /// outcomeDropped＝這句的 LLM 結果被丟棄（classification `skippedRaw`：raw 有片段沒上屏，潤飾套下去
    /// 會把被拒的內容偷渡回欄位；`sessionEnded`：outcome 回來時 session 已封存或已被取代，issue #11）。
    /// 另有 `finalizedDropped`（issue #20）不經本函式：相位守衛丟掉的定稿，見 `recordFinalizedDroppedByPhase`。
    ///
    /// 本函式掛在**呼叫當下**的 `historySessionID`。在途 outcome 的下場（`dispatch` 的世代守衛之前）
    /// 不能用它——那時 session 可能已封存或已換人，改用 `recordHistoryEvent` 帶話語閉合當下的 id。
    ///
    /// 與正常 outcome 列共用 gate 與 session。**時序不是單一規則**，回查歷史排序時要分四種：
    /// - 在 `handleTranscript` 記的（`frozen`、`fieldChanged`、`insertFailed/raw`）：早於該句的 outcome 列——
    ///   守衛跑在上屏當下，該句稍後才產生自己的 outcome 列。
    /// - 在 dispatch／apply 記的（`tailAdvanced`／`unverified`／`fieldMismatch`／`outcomeDropped`／
    ///   `sessionEnded`／`insertFailed/buffered`）：在該句的 outcome 列**之後**（dispatch 先記、apply 後跑），兩列相鄰。
    /// - `finalizedDropped`：那段定稿根本沒進斷句器，**永遠不會有** outcome 列。
    /// - `secureUnknown`（`:341` 那道守衛與寫入前的閘門**都會**記）與 `secureField`（**只有**
    ///   寫入前的閘門會記——`:341` 的 `.secure` case 直接 `abortForSecureField()` 就 return，
    ///   不留 `insertSkipped` 列）：兩者都**沒有** outcome 列可相鄰，session 當場 abort。
    ///   統計「AX 明說是密碼欄」的次數時要記得這個不對稱：`secureField` 的分母只涵蓋
    ///   「聽寫途中切進去」，不含「session 開始時就在密碼欄」（後者連列都沒有，issue #58 的 follow-up）。
    ///
    /// `utteranceText` 帶的是使用者說的話，會原樣落進 `history_exchange.utteranceRaw`。
    /// 可能是密碼欄位的路徑一律傳 `""`，改把判讀用的 metadata 放進 `detail`（issue #10 的不變式）。
    private func recordInsertEvent(kind: String, classification: String,
                                   utteranceText: String, detail: String? = nil) {
        recordHistoryEvent(sessionID: historySessionID, kind: kind, classification: classification,
                           utteranceText: utteranceText, detail: detail)
    }

    /// 診斷列的唯一出口：明確指定掛在哪個 session。nil＝那個 session 沒在記錄，**不記**——
    /// 不退回目前的 `historySessionID`，否則舊 session 的內容會被記成新 session 的（issue #11）。
    /// `settings.historyEnabled` 仍以寫入當下為準：使用者中途關閉歷史之後，一列都不補。
    private func recordHistoryEvent(sessionID: String?, kind: String, classification: String,
                                    utteranceText: String, detail: String? = nil) {
        guard settings.historyEnabled, let hid = sessionID else { return }
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
        guard coordinator.replaceStaleTail(snapshot, at: location, with: text) == .replaced else {
            return false
        }
        ledger.appendPolished(text)
        // 文字有落地、且是潤飾後的版本，故不屬 insertFailed／insertSkipped 二分，另立一類。
        // detail 帶回收後的文字：歷史頁要看得出回收回來的是什麼內容。
        recordInsertEvent(kind: "insertRecovered", classification: "staleTail",
                          utteranceText: snapshot.text, detail: text)
        emitFeedback(oldText: previousMirror)
        return true
    }

    /// 插入層備援診斷（issue #1 被動蒐證）：主 inserter 失敗、備援成功。
    /// 不是失敗也不是跳過——文字有落地，故不進 insertFailed／insertSkipped 二分，另立一類。
    /// utteranceRaw 留空：這是插入機制的事件，不是某句話的 outcome。
    public func noteInserterFallback(_ kind: InsertionCoordinator.InserterFallback) {
        recordInsertEvent(kind: "insertFallback", classification: kind.rawValue, utteranceText: "")
    }

    /// 原文照留：帳本入帳（欄位鏡像，建版本但不算已潤飾——#46 只退 raw 時它會被退掉）＋提示
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
