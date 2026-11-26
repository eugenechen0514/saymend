import Foundation
import OSLog
import SaymendControl

/// CLI 來源的聽寫（`saymend dictate`）：麥克風 → 辨識引擎 → 本機確定性後處理（→ 選配潤飾）→ **只回給呼叫端**。
///
/// **與熱鍵聽寫（`DictationController`）完全分開的一條路**：不經 `InsertionCoordinator`、不上屏、
/// 不碰剪貼簿、沒有帳本／延續窗／口頭修正。熱鍵那一側的狀態機一行都不需要知道 CLI 聽寫的存在，
/// 只多了 `yieldForExternalCapture()`（開麥前確認它沒在用麥克風）與 `activity`（給 status／events）。
///
/// 麥克風與辨識引擎與熱鍵聽寫**共用同一組實例**（引擎同一時間只能跑一條串流——本機 WhisperKit 共用一份
/// CoreML 模型），所以兩者互斥：熱鍵聽寫進行中不能開始（busy）；CLI 聽寫進行中熱鍵與 Esc 由 App 層
/// 轉給本類（`hotkeyPressed`＝定稿、`cancel`＝丟棄），不會開始熱鍵聽寫。
///
/// **密碼欄位規則（規格 §5.3）不適用**：§5.3 的觸發條件是「聽寫的目標是聚焦中的密碼欄」——拒絕的理由是
/// 文字會打進那個欄位。CLI 聽寫沒有目標欄位，結果在構造上就到不了任何欄位（這條路上根本沒有 inserter），
/// 焦點在哪裡與使用者說的話要去哪裡無關。見 `docs/control-interface.md`。
@MainActor
public final class CLIDictationController {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case polishing
    }

    public struct Result: Equatable, Sendable {
        public let text: String
        public let raw: String
        public let durationMs: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case busy(String)
        case cancelled
        case noSpeech
        case emptyResult
        case modelNotReady(String)
        case timedOut
        case permissionDenied(String)
        case microphoneUnavailable(String)
        case asrFailed(String)

        public var code: ControlErrorCode {
            switch self {
            case .busy: return .busy
            case .cancelled: return .cancelled
            case .noSpeech: return .noSpeech
            case .emptyResult: return .emptyResult
            case .modelNotReady: return .modelNotReady
            case .timedOut: return .timeout
            case .permissionDenied: return .permissionDenied
            case .microphoneUnavailable: return .microphoneUnavailable
            case .asrFailed: return .asrFailed
            }
        }

        public var message: String {
            switch self {
            case .busy(let why): return why
            case .cancelled: return "已取消"
            case .noSpeech: return "沒有偵測到說話"
            case .emptyResult: return "辨識結果為空"
            case .modelNotReady(let why): return "模型未就緒：\(why)"
            case .timedOut: return "辨識逾時"
            case .permissionDenied(let why): return why
            case .microphoneUnavailable(let why): return why
            case .asrFailed(let why): return "辨識失敗：\(why)"
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case started
        /// 目前為止的全文（已定稿＋暫時文字），只在內容改變時送
        case partial(String)
        case finished(Result)
        case failed(Failure)
    }

    public enum MicrophoneAccess: Sendable {
        case granted
        case denied
        /// 還沒問過使用者。App 端的 closure 會順手發出授權請求；這一次照樣以權限不足結束，授權後再試。
        case undetermined
    }

    /// 錄音結束的原因（只進 log）
    enum EndReason: String {
        case stopped, silence, maxDuration, hotkey
    }

    private final class Session {
        let id: Int
        let options: DictateOptions
        let sink: (Event) -> Void
        let startedAt: TimeInterval
        var detector: EndpointDetector
        var finalized: [String] = []
        var volatile = ""
        var lastPartial = ""
        var recordingEndedAt: TimeInterval?
        var loadingModel = false
        /// 這一段收到的最大位準（只進 log：日後校準端點門檻用）
        var maxLevel: Float = 0
        var levelSamples = 0
        /// 歷史 session 的 id。**有東西要記才建立**（`ensureHistorySession`）：mod 的免手動迴圈會反覆開
        /// 「沒人說話就放棄」的聽寫，每次都開一筆空白 session 會把歷史分頁洗成一整片「（未定稿）」。
        var historyID: String?
        /// 開始當下歷史是否開著，以及那個時間（延遲建立的 session 仍以開始時間入帳）
        var historyStartedAt: Date?
        var readerTask: Task<Void, Never>?
        var teeTask: Task<Void, Never>?
        var polishTask: Task<Void, Never>?

        init(id: Int, options: DictateOptions, sink: @escaping (Event) -> Void, startedAt: TimeInterval,
             detector: EndpointDetector) {
            self.id = id
            self.options = options
            self.sink = sink
            self.startedAt = startedAt
            self.detector = detector
        }

        var rawText: String { finalized.joined() }

        func durationMs(now: TimeInterval) -> Int {
            Int((((recordingEndedAt ?? now) - startedAt) * 1000).rounded())
        }
    }

    /// 歷史 session 的 App 欄位：歷史分頁的「App」欄直接顯示它，使用者一眼看得出這筆是 CLI 發起的。
    public static let historyAppName = "CLI（saymend）"
    /// 歷史 session 的 targetKind（熱鍵聽寫是 `tail`／`selection`）
    public static let historyTargetKind = "cli"

    public private(set) var phase: Phase = .idle {
        didSet { if oldValue != phase { onPhaseChange?() } }
    }
    public var isActive: Bool { session != nil }
    public var onPhaseChange: (() -> Void)?

    private let audio: any AudioCaptureService
    private let asr: any ASREngine
    private let hud: any HUDPresenting
    private let settings: AppSettings
    private let history: (any HistoryRecording)?
    private let postProcess: () -> (String) -> String
    private let polish: ((String) async -> IntentOutcome)?
    private let microphoneAccess: () -> MicrophoneAccess
    private let hotkeyGate: () -> Bool
    private let drainTimeout: () -> TimeInterval
    private let detectorConfig: EndpointDetector.Config
    private let clock: () -> TimeInterval
    private let now: () -> Date

    private var session: Session?
    private var nextSessionID = 0
    private static let log = Logger(subsystem: "io.saymend.app", category: "cli")

    /// - Parameters:
    ///   - postProcess: 每次聽寫現取一次後處理器（設定、詞彙表即時生效）
    ///   - polish: `--polish` 時呼叫；nil＝不支援潤飾（照原文回）
    ///   - hotkeyGate: 熱鍵聽寫是否讓出麥克風（`DictationController.yieldForExternalCapture`）
    ///   - drainTimeout: 錄音結束後等辨識結果的上限（逾時＝exit 7）
    ///   - clock: 單調時鐘（秒）
    public init(audio: any AudioCaptureService,
                asr: any ASREngine,
                hud: any HUDPresenting,
                settings: AppSettings,
                history: (any HistoryRecording)? = nil,
                postProcess: @escaping () -> (String) -> String = { { $0 } },
                polish: ((String) async -> IntentOutcome)? = nil,
                microphoneAccess: @escaping () -> MicrophoneAccess = { .granted },
                hotkeyGate: @escaping () -> Bool = { true },
                drainTimeout: @escaping () -> TimeInterval = { 180 },
                detectorConfig: EndpointDetector.Config = EndpointDetector.Config(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                now: @escaping () -> Date = Date.init) {
        self.audio = audio
        self.asr = asr
        self.hud = hud
        self.settings = settings
        self.history = history
        self.postProcess = postProcess
        self.polish = polish
        self.microphoneAccess = microphoneAccess
        self.hotkeyGate = hotkeyGate
        self.drainTimeout = drainTimeout
        self.detectorConfig = detectorConfig
        self.clock = clock
        self.now = now
    }

    // MARK: - 對外操作

    /// 開始一段 CLI 聽寫。`sink` 依序收到 `started` →（`partial`…）→ `finished` 或 `failed`，終局恰一次。
    /// 開始不了（忙碌、權限、麥克風）時 `sink` 當場收到 `failed`，不會先收到 `started`。
    public func start(_ options: DictateOptions, sink: @escaping (Event) -> Void) {
        guard session == nil else {
            sink(.failed(.busy("已有一段 CLI 聽寫進行中")))
            return
        }
        guard hotkeyGate() else {
            sink(.failed(.busy("熱鍵聽寫進行中")))
            return
        }
        switch microphoneAccess() {
        case .granted:
            break
        case .denied:
            sink(.failed(.permissionDenied("麥克風權限被拒。請到「系統設定 › 隱私權與安全性 › 麥克風」允許 Saymend")))
            return
        case .undetermined:
            sink(.failed(.permissionDenied("尚未授權麥克風，已向使用者請求授權；允許後再試一次")))
            return
        }
        let mic: AsyncStream<AudioChunk>
        do {
            mic = try audio.start()
        } catch {
            hud.present(.notice("無法啟動麥克風"))
            sink(.failed(.microphoneUnavailable("無法啟動麥克風：\(error)")))
            return
        }
        nextSessionID &+= 1
        let sid = nextSessionID
        let startedAt = clock()
        let s = Session(id: sid, options: options, sink: sink, startedAt: startedAt,
                        detector: EndpointDetector(startedAt: startedAt, config: detectorConfig))
        session = s

        // 麥克風音訊分兩路：原樣交給辨識器，同時算位準餵端點判斷。只有一個消費者讀麥克風串流——
        // 麥克風停（audio.stop）→ 這裡的迴圈結束 → 辨識器的輸入結束 → 引擎排空剩下的定稿。
        let (asrAudio, asrInput) = AsyncStream.makeStream(of: AudioChunk.self)
        s.teeTask = Task.detached { [weak self] in
            for await chunk in mic {
                asrInput.yield(chunk)
                if let level = AudioLevelMeter.level(of: chunk.buffer) {
                    await self?.ingestLevel(level, session: sid)
                }
            }
            asrInput.finish()
        }
        let events = asr.start(audio: asrAudio, localeIdentifier: settings.asrLocaleIdentifier)
        phase = .recording
        presentRecordingHUD(s)
        if settings.historyEnabled, history != nil { s.historyStartedAt = now() }
        Self.log.notice("CLI 聽寫開始：maxSeconds=\(options.maxSeconds, privacy: .public) silenceMs=\(options.silenceMs, privacy: .public) noSpeechSeconds=\(options.noSpeechSeconds, privacy: .public) polish=\(options.polish, privacy: .public)")
        sink(.started)
        s.readerTask = Task { [weak self] in
            for await event in events {
                self?.receive(event, session: sid)
            }
            self?.streamEnded(session: sid)
        }
    }

    /// 結束錄音並定稿（`saymend stop`）。回傳 false＝沒有錄音中的 CLI 聽寫。
    @discardableResult
    public func stop() -> Bool {
        guard phase == .recording else { return false }
        endRecording(.stopped)
        return true
    }

    /// 丟棄目前的 CLI 聽寫（`saymend cancel`、Esc、CLI 斷線）。任何階段都可以取消。回傳 false＝沒有 CLI 聽寫。
    /// `source` 只進 log：事後要分得出是誰取消的（Esc、另一個行程、訊號、斷線）。
    @discardableResult
    public func cancel(source: String = "request") -> Bool {
        guard session != nil else { return false }
        Self.log.notice("CLI 聽寫取消（來源：\(source, privacy: .public)）")
        fail(.cancelled)
        return true
    }

    /// CLI 聽寫進行中按下熱鍵（App 層轉來）：錄音中＝定稿（同鎖定聽寫時點一下熱鍵結束）；
    /// 錄音已結束＝只提示，不開始熱鍵聽寫（辨識引擎還在處理這一段）。
    public func hotkeyPressed() {
        switch phase {
        case .recording:
            endRecording(.hotkey)
        case .transcribing, .polishing:
            hud.present(.notice("CLI 聽寫處理中，完成後再按"))
        case .idle:
            break
        }
    }

    /// 週期驅動（App 的 0.25 秒 tick）：音訊樣本停了也要能判斷逾時與 `--max-seconds`。
    public func tick() {
        let t = clock()
        switch phase {
        case .recording:
            evaluate(at: t)
        case .transcribing:
            if let s = session, let ended = s.recordingEndedAt, t - ended >= drainTimeout() {
                Self.log.error("CLI 聽寫等辨識結果逾時")
                fail(.timedOut)
            }
        case .polishing, .idle:
            break   // 潤飾的時限由 provider 自己管（逾時＝降級回原文，不會卡住）
        }
    }

    // MARK: - 內部（@testable 可直接驅動）

    /// 測試觀察用：吃進端點判斷的位準樣本數、目前這段是否已判定開口
    private(set) var levelSamplesIngested = 0
    var debugSpeechDetected: Bool { session?.detector.speechDetected ?? false }

    func ingestLevel(_ level: Float, session sid: Int) {
        guard let s = session, s.id == sid, phase == .recording else { return }
        levelSamplesIngested += 1
        s.maxLevel = max(s.maxLevel, level)
        s.levelSamples += 1
        let t = clock()
        s.detector.ingestLevel(level, at: t)
        evaluate(at: t)
    }

    func receive(_ event: TranscriptEvent, session sid: Int) {
        guard let s = session, s.id == sid else { return }
        switch event {
        case .volatile(let text):
            // 只有「變長」才算有人在講（理由見 EndpointDetector）
            let grew = !text.isEmpty && text.count > s.volatile.count
            s.volatile = text
            if grew, phase == .recording { s.detector.noteTranscriptActivity(at: clock()) }
            emitPartialIfChanged(s)
            if phase == .recording { presentRecordingHUD(s) }
        case .finalized(let text, _):
            if !text.isEmpty {
                s.finalized.append(text)
                if phase == .recording { s.detector.noteTranscriptActivity(at: clock()) }
            }
            s.volatile = ""
            emitPartialIfChanged(s)
            if phase == .recording { presentRecordingHUD(s) }
        case .captionHallucination(let text, _):
            // 與熱鍵聽寫同一個判定（issue #10）：不算進結果，但記一列，誤殺時查得到。
            recordExchange(s, raw: text, kind: "insertSkipped", text: "captionHallucination")
        case .loadingModel:
            s.loadingModel = true
            if phase == .recording { presentRecordingHUD(s) } else { hud.present(.loadingModel) }
        case .transcribing:
            s.loadingModel = false
            if phase == .recording { presentRecordingHUD(s) } else if phase == .transcribing { hud.present(.transcribing) }
        case .failed(let reason):
            // 等模型的時候失敗（載入失敗、等太久、沒選模型）＝模型未就緒（exit 7）；其餘是一般辨識失敗
            let modelProblem = s.loadingModel || reason == WhisperKitEngine.noModelSelectedReason
            fail(modelProblem ? .modelNotReady(reason) : .asrFailed(reason))
        case .noSpeechDetected:
            break   // 本類有自己的端點判斷（--no-speech-seconds），不靠引擎的示警
        }
    }

    func streamEnded(session sid: Int) {
        guard let s = session, s.id == sid else { return }
        switch phase {
        case .recording:
            // 錄音中串流自己結束（麥克風斷線、引擎提早收尾）：照正常定稿處理，麥克風一定要關
            audio.stop()
            s.recordingEndedAt = clock()
        case .transcribing:
            break
        case .polishing, .idle:
            return
        }
        let raw = s.rawText
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(s.detector.speechDetected ? .emptyResult : .noSpeech)
            return
        }
        let durationMs = s.durationMs(now: clock())
        let process = postProcess()
        let processed = process(raw)
        guard s.options.polish, let polish else {
            recordExchange(s, raw: raw, kind: "cliRaw", text: processed)
            succeed(s, Result(text: processed, raw: raw, durationMs: durationMs))
            return
        }
        phase = .polishing
        hud.present(.hidden)   // 麥克風已關；潤飾在背景跑，畫面不留東西
        s.polishTask = Task { [weak self] in
            let outcome = await polish(raw)
            self?.finishPolish(outcome, session: sid, raw: raw, fallback: processed, durationMs: durationMs, process: process)
        }
    }

    // MARK: - 私有

    private func finishPolish(_ outcome: IntentOutcome, session sid: Int, raw: String, fallback: String,
                              durationMs: Int, process: (String) -> String) {
        guard let s = session, s.id == sid, phase == .polishing else { return }
        let text: String
        switch outcome {
        case .newContent(let t), .editedSession(let t):
            text = process(t)
        case .undo, .degraded:
            text = fallback   // 降級＝本機後處理過的原文（使用者不能白說話）
        }
        recordExchange(s, raw: raw, kind: outcome.historyKind, text: outcome.historyText)
        succeed(s, Result(text: text, raw: raw, durationMs: durationMs))
    }

    private func evaluate(at t: TimeInterval) {
        guard let s = session, phase == .recording else { return }
        switch s.detector.decision(at: t, options: s.options) {
        case .keepListening:
            return
        case .endOfSpeech:
            endRecording(.silence)
        case .maxDuration:
            endRecording(.maxDuration)
        case .noSpeech:
            Self.log.notice("CLI 聽寫：\(s.options.noSpeechSeconds, privacy: .public) 秒內沒偵測到說話，放棄")
            fail(.noSpeech)
        }
    }

    private func endRecording(_ reason: EndReason) {
        guard let s = session, phase == .recording else { return }
        audio.stop()                       // 麥克風串流結束 → 辨識器排空 → streamEnded
        s.recordingEndedAt = clock()
        phase = .transcribing
        hud.present(s.loadingModel ? .loadingModel : .transcribing)
        Self.log.notice("CLI 聽寫錄音結束：\(reason.rawValue, privacy: .public)，\(s.durationMs(now: self.clock()), privacy: .public) ms")
    }

    private func presentRecordingHUD(_ s: Session) {
        hud.present(.cliListening(volatile: s.finalized.joined() + s.volatile, loadingModel: s.loadingModel))
    }

    private func emitPartialIfChanged(_ s: Session) {
        guard phase == .recording || phase == .transcribing else { return }
        let text = s.finalized.joined() + s.volatile
        guard text != s.lastPartial else { return }
        s.lastPartial = text
        s.sink(.partial(text))
    }

    private func succeed(_ s: Session, _ result: Result) {
        if let hid = ensureHistorySession(s) { history?.finishSession(id: hid, finalText: result.text) }
        Self.log.notice("CLI 聽寫完成：\(result.text.count, privacy: .public) 字，\(result.durationMs, privacy: .public) ms")
        teardown(hud: .hidden)
        s.sink(.finished(result))
    }

    /// 任何階段的失敗與取消都走這裡：麥克風一定關、辨識器一定停、終局恰一次。
    private func fail(_ failure: Failure) {
        guard let s = session else { return }
        switch phase {
        case .recording:
            audio.stop()
            asr.cancel()
        case .transcribing:
            asr.cancel()
        case .polishing, .idle:
            break
        }
        s.readerTask?.cancel()
        s.polishTask?.cancel()
        // 有聽到東西才記：取消時使用者可能想回頭查剛才說了什麼（歷史開著的話）
        let raw = s.rawText
        if !raw.isEmpty { recordExchange(s, raw: raw, kind: "outcomeDropped", text: "cli:\(failure.code.rawValue)") }
        if let hid = s.historyID { history?.finishSession(id: hid, finalText: nil) }
        Self.log.notice("CLI 聽寫結束（\(failure.code.rawValue, privacy: .public)）")
        let hudState: HUDState
        switch failure {
        case .cancelled, .noSpeech, .emptyResult, .busy:
            hudState = .hidden
        case .modelNotReady, .timedOut, .permissionDenied, .microphoneUnavailable, .asrFailed:
            hudState = .notice("CLI 聽寫失敗：\(failure.message)")
        }
        teardown(hud: hudState)
        s.sink(.failed(failure))
    }

    /// 先清狀態再通知呼叫端：sink 裡若立刻開始下一段（mod 的迴圈），看到的必須已經是 idle。
    private func teardown(hud state: HUDState) {
        if let s = session {
            // 只有數字：端點門檻是憑經驗訂的，實機的位準分布要靠這行回頭校準
            let d = s.detector
            Self.log.notice("CLI 端點摘要：開口=\(d.speechDetected, privacy: .public) 最大位準=\(s.maxLevel, format: .fixed(precision: 3), privacy: .public) 底線=\(d.noiseFloor ?? -1, format: .fixed(precision: 3), privacy: .public) 門檻=\(d.threshold, format: .fixed(precision: 3), privacy: .public) 位準樣本=\(s.levelSamples, privacy: .public)")
        }
        session = nil
        phase = .idle
        hud.present(state)
    }

    private func recordExchange(_ s: Session, raw: String, kind: String, text: String?) {
        guard let hid = ensureHistorySession(s) else { return }
        history?.recordExchange(.init(sessionID: hid, at: now(), utteranceRaw: raw,
                                      outcomeKind: kind, outcomeText: text))
    }

    /// 第一次有東西要記時才建立歷史 session。開始時歷史是關的、或寫入當下使用者關掉了歷史：都不記。
    private func ensureHistorySession(_ s: Session) -> String? {
        guard settings.historyEnabled, let history, let startedAt = s.historyStartedAt else { return nil }
        if let hid = s.historyID { return hid }
        let hid = UUID().uuidString
        s.historyID = hid
        history.beginSession(.init(id: hid, startedAt: startedAt, appBundleID: nil,
                                   appName: Self.historyAppName, targetKind: Self.historyTargetKind,
                                   finalText: nil))
        return hid
    }
}
