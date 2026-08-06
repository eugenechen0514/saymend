import AVFoundation
import Foundation

/// 模型載入失敗（spec §3.1）。與辨識期錯誤分型，讓引擎給對的失敗語彙。
public struct WhisperLoadError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// 本機辨識薄協定（spec §3.1）：把 WhisperKit 具體型別擋在外面，引擎單測不必載真 3GB 模型。
/// **「載入＋辨識」是單一原子呼叫**——引擎不分開呼叫 load/transcribe，消 TOCTOU。
public protocol WhisperTranscribing: Sendable {
    /// 背景預載指定模型（best-effort，錯誤吞掉）。
    func preload(modelPath: URL) async
    /// 指定模型目前的載入狀態（供 UI 顯示與引擎決定要不要先報「載入模型中…」）。
    func state(modelPath: URL) async -> ModelLoadState
    /// 卸載目前模型，釋放記憶體。
    func unload() async
    /// **串流**辨識（issue #12）：吃麥克風音訊片段流，吐出辨識進度序列。
    /// 音訊格式轉換與累積由實作負責（本專案交給 `StreamFedAudioSource`）。
    /// 載入失敗擲 `WhisperLoadError`；長度超限與音訊轉換失敗擲 `WhisperStreamError`。
    func transcribe(modelPath: URL,
                    audio: AsyncStream<AudioChunk>,
                    language: String,
                    promptPhrases: [String],
                    options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamEvent, Error>
}

/// WhisperKit 本機引擎（issue #12）：**串流**辨識——邊聽邊出文字，一個聽寫階段
/// 產生多個話語，與系統內建引擎行為一致。批次路徑已刪除（見 ADR 0001）。
///
/// 事件映射的核心紀律在 `pump`：**只在文字真的變化時發事件**。套件的狀態變更回呼
/// 每個音訊 buffer 都會觸發，照單全收會讓斷句器的靜音間隔永遠不到期、話語永不閉合。
/// 收尾另有一條同等重要的紀律：串流正常結束時**必須把殘留的未定稿文字轉正**（見 `flushTail`），
/// 否則短句聽寫會一個字都不出。
///
/// 失敗一律以 .failed 明示原因，不靜默結束。失敗語彙自成一組（本機無網路概念），
/// **不套** M7 的 `degradedReason`。
public final class WhisperKitEngine: ASREngine, ContextBiasable, @unchecked Sendable {

    private let transcriber: any WhisperTranscribing
    private let configProvider: () -> WhisperLocalConfig
    /// 串流參數每次呼叫讀取＝設定即時生效（比照 provider config 的慣例）
    private let optionsProvider: () -> WhisperStreamingOptions

    /// 詞彙表偏置（spec §7）：與其他引擎吃同一個來源，交由實作 tokenize 成 promptTokens。
    public var contextualStrings: (@MainActor () -> [String])?

    private let stateLock = NSLock()
    private var pumpTask: Task<Void, Never>?

    /// 聽寫進行中示警所需的最短音訊長度（issue #18）。
    /// 要避開「按了熱鍵先醞釀一下」的誤報——誤報比漏報更傷信任。
    static let listeningWarnAfter: Double = 3.0
    /// 收尾補發示警所需的最短音訊長度。比聽寫中低，因為 session 已結束且確知零產出、
    /// 沒有誤報空間；門檻低一些才涵蓋得到短嘗試。低於此值視為誤觸熱鍵，不唸使用者。
    static let endOfStreamWarnAfter: Double = 1.5

    public init(transcriber: any WhisperTranscribing,
                configProvider: @escaping () -> WhisperLocalConfig,
                optionsProvider: @escaping () -> WhisperStreamingOptions = { WhisperStreamingOptions() }) {
        self.transcriber = transcriber
        self.configProvider = configProvider
        self.optionsProvider = optionsProvider
    }

    /// 背景預載目前選定的模型（spec §6）。未選模型＝no-op，不視為錯誤。
    public func preload() async {
        guard let path = configProvider().selectedModelPath else { return }
        await transcriber.preload(modelPath: path)
    }

    /// 目前選定模型的載入狀態；未選模型＝`.idle`。
    public func state() async -> ModelLoadState {
        guard let path = configProvider().selectedModelPath else { return .idle }
        return await transcriber.state(modelPath: path)
    }

    /// 卸載已載入的模型，釋放記憶體。
    public func unload() async {
        await transcriber.unload()
    }

    public func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.pump(audio: audio, localeIdentifier: localeIdentifier,
                                continuation: continuation)
            }
            stateLock.lock(); pumpTask = task; stateLock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() {
        stateLock.lock()
        let task = pumpTask
        pumpTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    /// **取消限制（誠實記錄，spec §3.1）**：`cancel()` 在辨識/載入進行中不保證瞬間中止
    /// 該 async 工作；但每個 `await` 後一律檢查 `Task.isCancelled`、取消時**不吐
    /// `.finalized` 也不吐 `.failed`**（fail-closed，無錯字上屏、取消不算失敗）。
    ///
    /// **關於下面幾個 `Task.isCancelled` 守衛的誠實說明**：實測把它們全部拿掉，
    /// 既有的取消測試仍然全綠——因為 `AsyncThrowingStream` 在消費端 Task 被取消時
    /// 迭代即結束（回 nil），迴圈正常退出、`catch` 區塊根本不會執行。也就是說保護
    /// 主要來自串流本身的取消語意，這些守衛是 defence-in-depth，**測試無法驅動它們**。
    /// 保留是因為成本為零、且不依賴標準庫的取消時序細節；但不得宣稱它們有測試覆蓋。
    private func pump(audio: AsyncStream<AudioChunk>,
                      localeIdentifier: String,
                      continuation: AsyncStream<TranscriptEvent>.Continuation) async {
        // fail-closed：未選模型不得進辨識
        guard let modelPath = configProvider().selectedModelPath else {
            continuation.yield(.failed(reason: "未選擇本機模型"))
            continuation.finish()
            return
        }

        // 模型尚未載入就先報「載入模型中…」再載：首次載入含 ANE 編譯，實測 large-v3-turbo
        // 可達數分鐘，全折進「辨識中…」會讓使用者以為當掉（實機回報）。
        if await transcriber.state(modelPath: modelPath) != .loaded {
            continuation.yield(.loadingModel)
            await transcriber.preload(modelPath: modelPath)
            if Task.isCancelled { continuation.finish(); return }
            // preload 是 best-effort（coordinator 內以 try? 吞掉錯誤），得回頭確認模型真的載起來了。
            // 少了這一關，載入失敗會被帶進 transcribe 觸發第二次載入＝再等一輪 ANE 編譯
            // （large 數分鐘），期間還誤顯「辨識中…」，最後才吐失敗。
            guard await transcriber.state(modelPath: modelPath) == .loaded else {
                continuation.yield(.failed(reason: "模型載入失敗"))
                continuation.finish()
                return
            }
        }

        // 模型就緒，開始辨識
        continuation.yield(.transcribing)

        // 屬性讀取＋closure 呼叫都在 MainActor 上，理由同 WhisperRemoteEngine.biasPrompt() :148-155
        let phrases = await MainActor.run { [weak self] in self?.contextualStrings?() ?? [] }
        let language = WhisperRemoteEngine.languageCode(from: localeIdentifier)
        if Task.isCancelled { continuation.finish(); return }

        let progress = transcriber.transcribe(modelPath: modelPath, audio: audio,
                                              language: language, promptPhrases: phrases,
                                              options: optionsProvider())
        do {
            var lastConfirmed = ""
            var lastUnconfirmed = ""
            // issue #18：整段零語音的示警狀態。邊緣觸發——一個 session 最多發一次。
            var warnedNoSpeech = false
            var lastStats: (voiced: Int, seconds: Double) = (0, 0)
            for try await element in progress {
                if Task.isCancelled { continuation.finish(); return }

                guard case .progress(let step) = element else {
                    if case .audioStats(let voiced, let seconds) = element {
                        lastStats = (voiced, seconds)
                        if !warnedNoSpeech, voiced == 0, seconds >= Self.listeningWarnAfter {
                            warnedNoSpeech = true
                            continuation.yield(.noSpeechDetected)
                        }
                    }
                    continue
                }

                // **只在文字真的變化時發事件。**
                // 套件的狀態變更回呼掛在 state 的 didSet 上，而 state 含每個音訊 buffer
                // 都會更新的能量資料——只要在錄音就持續觸發，與有沒有人講話無關。
                // 斷句器對任何辨識事件都會重置靜音計時，若照單全收，靜音間隔永遠不會到期、
                // 話語永不閉合，整個串流改造的意義會歸零（退回「一個聽寫階段一整句」）。
                if step.confirmed != lastConfirmed {
                    // 定稿只增不減：只吐新增的那一段，重覆的部分不得再上屏一次
                    let delta = Self.newlyConfirmed(previous: lastConfirmed, current: step.confirmed)
                    lastConfirmed = step.confirmed
                    let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { continuation.yield(.finalized(trimmed)) }
                }
                if step.unconfirmed != lastUnconfirmed {
                    lastUnconfirmed = step.unconfirmed
                    continuation.yield(.volatile(step.unconfirmed))
                }
            }
            if Task.isCancelled { continuation.finish(); return }
            flushTail(lastUnconfirmed, into: continuation)
            // 1.5–3.0 秒的零語音 session 在聽寫中不夠格示警，收尾才補——
            // 少了這一關，短嘗試會完全靜默，正是本票要消滅的失敗模式。
            if !warnedNoSpeech, lastStats.voiced == 0, lastStats.seconds >= Self.endOfStreamWarnAfter {
                continuation.yield(.noSpeechDetected)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            // 取消不是失敗：被 Esc 打斷後才擲出的 error 不得變成使用者看得到的失敗訊息
            if Task.isCancelled { continuation.finish(); return }
            continuation.yield(.failed(reason: Self.reason(for: error)))
            continuation.finish()
        }
    }

    /// **串流正常結束時把殘留的未定稿文字轉正。**
    ///
    /// 套件的 `stopStreamTranscription` 只是把主迴圈旗標關掉，不會把 `unconfirmedSegments`
    /// 搬進 `confirmedSegments`——它自己的示範 App 是把兩段併起來顯示，所以看不出問題。
    /// 我們只把定稿的增量送上屏、暫時文字僅供 HUD 顯示，殘留在此的尾端若不補發就永遠遺失。
    ///
    /// 這不是罕見的邊角：套件的定稿條件是 `segments.count > 定稿所需片段數`（預設 2），
    /// 而 Whisper 對五秒鐘的一句話通常只切出 1 段——條件永遠不成立，**短句聽寫會一個字
    /// 都不出**。定稿所需片段數愈大愈嚴重（設定頁上限 10）。
    ///
    /// 只在**正常結束**時補：取消與失敗都不補。中途壞掉時殘留的未定稿文字沒有可信度可言，
    /// 送上屏等於把半成品當結果寫進使用者的欄位。
    private func flushTail(_ tail: String, into continuation: AsyncStream<TranscriptEvent>.Continuation) {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { continuation.yield(.finalized(trimmed)) }
    }

    /// 定稿文字只增不減，故新增部分＝去掉共同前綴。萬一不是前綴關係（套件重寫了已定稿
    /// 的內容），保守地把整段當新增——寧可重覆也不要漏字。
    static func newlyConfirmed(previous: String, current: String) -> String {
        guard current.hasPrefix(previous) else { return current }
        return String(current.dropFirst(previous.count))
    }

    static func reason(for error: any Error) -> String {
        if error is WhisperLoadError { return "模型載入失敗" }
        switch error as? WhisperStreamError {
        case .overCapacity(let minutes): return "錄音超過 \(minutes) 分鐘上限"
        case .audioConversionFailed: return "音訊轉換失敗"
        case nil: return "辨識失敗"
        }
    }
}
