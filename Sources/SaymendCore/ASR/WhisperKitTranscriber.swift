import Foundation
import OSLog
import WhisperKit

/// 每個模型一個 actor（spec §3.1）：`WhisperKit` **不是 Sendable**，故於此 actor 的 async init
/// 內自建、且 `tokenizer` 讀取與辨識都留在 actor 內——pipe 全程不出隔離域、絕不跨界回傳。
///
/// 串流轉錄器（issue #12）同樣**在此 actor 內建構並持有**：它的 init 需要 pipe 的六個
/// 子元件（encoder／decoder／tokenizer…），在外部組裝就會讓非 Sendable 的它們跨越隔離邊界。
/// 專案處於 Swift 5 語言模式，那樣只會是警告而非錯誤——**編得過不代表對**。
public actor WhisperKitModelActor {
    private let pipe: WhisperKit

    /// 收尾補解碼的結果（issue #22）與停止的補送（issue #79）。只記數字與結果分類，不記任何文字。
    /// **這幾行沒有測試覆蓋**：os_log 的輸出無法在單元測試裡攔截。
    private static let log = Logger(subsystem: "io.saymend.app", category: "ASR")

    public init(modelFolder: URL) async throws {
        do {
            self.pipe = try await WhisperKit(Self.modelConfig(modelFolder: modelFolder))
        } catch {
            throw WhisperLoadError(message: String(describing: error))
        }
    }

    /// 建構模型載入設定。抽成純函式是為了測得到 `prewarm` 與 `download`。
    ///
    /// **`prewarm: false` 是有意的，不是漏設。** 套件的 prewarm 會把每個模型載起來**再丟掉**
    /// （`WhisperKit.loadModels` 的 `model = prewarmMode ? nil : loadedModel`），接著 `load: true`
    /// 再完整載一次。它的用途是「先編譯、晚點才真的要用」；我們兩件事是背靠背做的，開著就是**每次
    /// 冷啟動做兩遍**。實機 2026-07-28 量到 large-v3-turbo 關掉 prewarm 仍要 631 秒
    /// （文字解碼器 104s ＋ 音訊編碼器 527s），開著等於再翻一倍。
    ///
    /// `download: false`＝一律不連網下載模型，複用磁碟既有的 CoreML 模型。
    /// `tokenizerFolder` 不指定＝交套件依模型自行解析（讀本機 HF 快取，已快取即離線）。
    ///
    /// `verbose: true` ＋ **`.debug`**：載入期間的分階段里程碑（`Loading audio encoder`、
    /// `Loaded text decoder in 104.21s`…）在套件裡是 `Logging.debug`，只有「開始載」與
    /// 「全部載完」兩則是 `.info`。`Logging.log` 的守衛是 `level <= messageLevel`，
    /// 所以設 `.info` 時 `.info(2) <= .debug(1)` 為 false——**分階段的訊息一則都收不到**。
    /// issue #17 要的階段進度靠的就是那些訊息（見 `WhisperLoadLogParser`）。
    ///
    /// **等級只在載入期間停在 `.debug`**：`WhisperKit.init` 一開始就用這裡的值呼叫
    /// `Logging.updateLogLevel`，載完由 `ModelLoadRun` 的收尾動作調回 `.info`
    /// （見 `WhisperKitTranscriber.init`）。不這麼做的話，辨識期 `TextDecoder` 的
    /// 逐 token 除錯訊息（`TextDecoder.swift:588/592/657`，都在 `:573` 那個 token 迴圈裡）
    /// 會每個 token 灌一則進我們的 callback。
    ///
    /// 附帶一提，那幾則訊息裡的 `tokenizer.decode(...)` 是**現在就在付的成本**——
    /// 字串插值在呼叫點就求值完畢，與 log 等級無關。改等級只影響 `log()` 內部的
    /// map/join 與 callback 呼叫。
    static func modelConfig(modelFolder: URL) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: modelFolder.path,
                         verbose: true, logLevel: .debug,
                         prewarm: false, load: true, download: false)
    }

    /// 建構解碼參數。抽成純函式**是為了測得到 `skipSpecialTokens`**。
    ///
    /// 那個旗標的套件預設是 `false`，而 false 會讓 `SegmentSeeker` 直接解碼原始 token 串
    /// （`Text/SegmentSeeker.swift:121`／`:165` 的 `options.skipSpecialTokens ? wordTokens : 原始`），
    /// 於是 `<|startoftranscript|><|zh|><|transcribe|><|0.00|>…<|3.80|><|endoftext|>` 會原封不動
    /// 出現在 `segment.text`，一路上屏寫進使用者的文件——實機 2026-07-28 真的發生了。
    /// 套件自己的 server 註解寫著「always skip special tokens for server responses」，
    /// 示範 App 也一律開；預設 false 是給要看原始 token 的除錯情境用的。
    static func decodingOptions(language: String,
                                promptTokens: [Int]?,
                                options: WhisperStreamingOptions) -> DecodingOptions {
        var decoding = DecodingOptions(language: language.isEmpty ? nil : language,
                                       usePrefillPrompt: true,
                                       skipSpecialTokens: true,
                                       promptTokens: promptTokens)
        if let v = options.logProbThreshold { decoding.logProbThreshold = v }
        if let v = options.compressionRatioThreshold { decoding.compressionRatioThreshold = v }
        return decoding
    }

    /// 片段的品質自評（issue #10）。抽成純函式是為了在不載真模型的前提下測得到欄位對應——
    /// `avgLogprob` 與 `compressionRatio` 名字相近、都是浮點數，接反了不會有任何編譯或執行期徵兆，
    /// 只會讓幾週後累積出來的樣本全部無效。
    static func quality(of segment: TranscriptionSegment) -> TranscriptSegmentQuality {
        TranscriptSegmentQuality(avgLogprob: segment.avgLogprob,
                                 compressionRatio: segment.compressionRatio)
    }

    /// 照抄套件 `AudioStreamTranscriber.shouldStopEarly`（private，叫不到）。
    ///
    /// 收尾補解碼（issue #22）要與串流中的每一趟用同一套提早中止條件：少了它，退化成複讀的
    /// 窗口會一路解到 token 上限才停，大模型放開熱鍵後要多等好幾秒，結果還是被門檻判失敗。
    /// 回傳 false＝中止這個窗口、nil＝繼續（套件 `TranscriptionCallback` 的語意）。
    static func shouldStopEarly(progress: TranscriptionProgress,
                                options: DecodingOptions,
                                compressionCheckWindow: Int) -> Bool? {
        let currentTokens = progress.tokens
        if currentTokens.count > compressionCheckWindow {
            let checkTokens: [Int] = currentTokens.suffix(compressionCheckWindow)
            let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
            if compressionRatio > options.compressionRatioThreshold ?? 0.0 {
                return false
            }
        }
        if let avgLogprob = progress.avgLogprob, let logProbThreshold = options.logProbThreshold {
            if avgLogprob < logProbThreshold {
                return false
            }
        }
        return nil
    }

    /// 套件狀態 → 我們的進度。抽成純函式是為了測得到欄位對應：定稿與暫時文字接反了不會有任何
    /// 編譯或執行期徵兆，只會讓暫時文字被當成定稿上屏。
    static func progress(from state: some StreamerStateReading) -> WhisperStreamProgress {
        WhisperStreamProgress(confirmed: state.confirmedSegments.map(\.text).joined(),
                              unconfirmed: state.unconfirmedSegments.map(\.text).joined(),
                              confirmedQuality: state.confirmedSegments.map(quality(of:)),
                              unconfirmedQuality: state.unconfirmedSegments.map(quality(of:)))
    }

    /// 套件狀態 → 收尾補解碼的記帳（issue #22）。**接錯就是重覆上屏或漏字**：定稿結束點若變成 0，
    /// 補解碼會從頭解，已上屏的定稿會被收尾補發再插一次；解到的樣本數若變成 0，每次收尾都白補一趟。
    static func tailLedger(from state: some StreamerStateReading,
                           progress: WhisperStreamProgress) -> StreamTailDrain.Ledger {
        .init(decodedSamples: state.lastBufferSize,
              confirmedEndSeconds: state.lastConfirmedSegmentEndSeconds,
              lastProgress: progress)
    }

    /// 補解碼用的解碼參數：串流每一趟用的那一組，加上解碼起點（與套件
    /// `AudioStreamTranscriber.transcribeAudioSamples` 的 `clipTimestamps` 相同做法）。
    /// 起點錯了同樣是重覆上屏（從 0 解）或漏字。
    static func drainDecodingOptions(_ decoding: DecodingOptions, clipStart: Float) -> DecodingOptions {
        var d = decoding
        d.clipTimestamps = [clipStart]
        return d
    }

    /// 串流辨識：音訊由 `source` 灌入（呼叫端負責餵），進度經回呼吐出。
    /// 本方法在串流結束（呼叫端停止或音訊耗盡）、且收尾補解碼（issue #22）做完之前不返回。
    ///
    /// - `onTailDrain`：停止串流轉錄器的那一刻判定**可能要補**時呼叫一次（見 `WhisperStreamEvent.drainingTail`）。
    ///   之後未必真的補：那一刻與套件真正停下之間，它可能又開了一趟、解到了結尾。但那段時間確實還在解碼，
    ///   顯示「辨識中…」不算錯。
    /// - `tailDrainAllowed`：音訊是否**正常**收完。音訊轉換失敗、超過長度上限時，呼叫端已經以錯誤
    ///   結束串流，補解碼的結果沒人收，只是白跑一趟（大模型十幾秒）。
    ///
    /// **測試覆蓋的誠實說明**：欄位對應與解碼參數抽成了純函式（`progress(from:)`、`tailLedger`、
    /// `drainDecodingOptions`），決策在 `StreamTailDrain`，停止監看的迴圈在 `StreamStopWatch`（issue #79），
    /// 都有測試。剩下的接線——狀態回呼把 `isRecording` 交給停止監看、停止與補解的時機、
    /// 取消與「我們要求停止」的判斷、結果交給 `onProgress`——要真的模型才跑得到，沒有單元測試，
    /// 由實機驗收擋。
    func streamTranscribe(source: StreamFedAudioSource,
                          language: String,
                          promptPhrases: [String],
                          options: WhisperStreamingOptions,
                          onProgress: @escaping @Sendable (WhisperStreamProgress) -> Void,
                          onTailDrain: @escaping @Sendable () -> Void,
                          shouldStop: @escaping @Sendable () -> Bool,
                          tailDrainAllowed: @escaping @Sendable () -> Bool) async throws {
        var promptTokens: [Int]?
        if !promptPhrases.isEmpty, let tok = pipe.tokenizer {
            // 詞彙表偏置（spec §7）：tokenize 後濾掉特殊 token（id ≥ specialTokenBegin），只留文字 token
            let ids = tok.encode(text: " " + promptPhrases.joined(separator: " "))
                .filter { $0 < tok.specialTokens.specialTokenBegin }
            promptTokens = ids.isEmpty ? nil : ids
        }
        guard let tokenizer = pipe.tokenizer else {
            throw WhisperLoadError(message: "tokenizer 未就緒")
        }

        let decoding = Self.decodingOptions(language: language, promptTokens: promptTokens,
                                            options: options)

        // 注意：`source.relativeEnergyWindow` **不在這裡設**——本方法要等模型載完才被呼叫，
        // 而餵音訊的 Task 早就開始 append 了。窗口在 `transcribe` 建構 source 時就給定。

        // 收尾補解碼要知道套件解到哪裡、從哪裡解起（issue #22）。套件的 state 是 private，
        // 只有狀態變更回呼看得到，所以在回呼裡記下來。
        let ledger = StreamTailLedgerBox()
        // 套件迴圈離開之後，回呼不再轉發。套件每個 token 都另開 `Task` 回它的 actor 更新 `currentText`，
        // 這些 Task 可能晚於迴圈離開才跑；跑的時候會帶著最後一趟的暫時文字觸發回呼。排在補解碼的結果
        // 後面的話，引擎記住的暫時文字會被蓋回最後一趟的，收尾補發轉正的就不是補解碼的結果。
        // 迴圈離開時段落已是最終狀態，之後的回呼不會帶來新文字，略過沒有損失。
        let streamerFinished = Sendable_Flag()
        // 停止監看要知道套件是否又開始錄了（issue #79，見 `StreamStopWatch`）
        let recording = StreamerRecordingBox()

        // 子元件全部取自 pipe，但只在此 actor 內流動、不回傳給呼叫端
        let streamer = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: source,
            decodingOptions: decoding,
            requiredSegmentsForConfirmation: options.requiredSegmentsForConfirmation,
            silenceThreshold: options.silenceThreshold,
            compressionCheckWindow: options.compressionCheckWindow,
            useVAD: options.useVAD,
            stateChangeCallback: { _, new in
                recording.record(new.isRecording)
                guard !streamerFinished.isSet else { return }
                let progress = Self.progress(from: new)
                ledger.record(Self.tailLedger(from: new, progress: progress))
                onProgress(progress)
            })

        // 停止那一刻與迴圈離開後各判一次要不要補（前者涵蓋後者，見 `StreamTailDrain.Ledger`）
        let planTail: @Sendable () -> StreamTailDrain.Tail? = {
            guard tailDrainAllowed() else { return nil }
            return StreamTailDrain.plan(ledger: ledger.current,
                                        totalSamples: source.audioSamples.count,
                                        relativeEnergy: source.relativeEnergy,
                                        useVAD: options.useVAD,
                                        silenceThreshold: options.silenceThreshold)
        }
        let announced = Sendable_Flag()
        let stopRequested = Sendable_Flag()

        // 停止監看：串流轉錄器的主迴圈在 stopStreamTranscription 之前不返回。
        // 停過之後仍要看著：停止落在套件開始錄之前會被它蓋掉（issue #79，見 `StreamStopWatch`）
        let stopWatcher = Task {
            await StreamStopWatch.run(
                shouldStop: shouldStop,
                streamerRecording: { recording.isRecording },
                beforeFirstStop: {
                    // 先報再停：正在跑的那一趟（大模型可達 10 秒）也算在使用者要等的時間裡
                    if planTail() != nil, announced.setOnce() { onTailDrain() }
                    stopRequested.set()
                },
                stop: { attempt in
                    if attempt > 1 {
                        Self.log.notice("停止落在串流轉錄器開始錄之前，補送停止（第 \(attempt, privacy: .public) 次）")
                    }
                    await streamer.stopStreamTranscription()
                })
        }
        defer { stopWatcher.cancel() }
        try await streamer.startStreamTranscription()
        streamerFinished.set()

        // 收尾補解碼（issue #22）。只在**我們要求停止**之後補：迴圈在那之前就自己離開＝套件吞掉了一次
        // 解碼錯誤（`realtimeLoop` 的 catch 只 log 就 break），模型剛壞過，不再補。
        // **分不出來的情況**：要求停止之後，正在跑的那一趟才擲錯——套件一樣吞掉，這裡照樣補。
        // 多半也會失敗（`.failed`），退回原本的行為，代價是多顯示一段「辨識中…」。
        guard stopRequested.isSet, !Task.isCancelled, let tail = planTail() else { return }
        // 依 `Ledger` 的單調性，停止監看此時必定已經報過，這行照理到不了。留著是防禦：
        // 萬一套件改了記帳語意，補解碼期間 HUD 至少還有「辨識中…」。測試驅動不到它。
        if announced.setOnce() { onTailDrain() }
        let snapshot = ledger.current
        let samples = Array(source.audioSamples)
        let window = options.compressionCheckWindow
        let started = ContinuousClock.now
        let outcome = await StreamTailDrain.run(tail, ledger: snapshot, decode: { clipStart in
            // 與串流中的每一趟相同：同一組解碼參數、從已定稿片段的結束點解到音訊結尾
            let drainDecoding = Self.drainDecodingOptions(decoding, clipStart: clipStart)
            let task = TranscribeTask(currentTimings: TranscriptionTimings(),
                                      progress: Progress(),
                                      audioProcessor: source,
                                      audioEncoder: pipe.audioEncoder,
                                      featureExtractor: pipe.featureExtractor,
                                      segmentSeeker: pipe.segmentSeeker,
                                      textDecoder: pipe.textDecoder,
                                      tokenizer: tokenizer)
            let result = try await task.run(audioArray: samples, decodeOptions: drainDecoding) { progress in
                Self.shouldStopEarly(progress: progress, options: drainDecoding, compressionCheckWindow: window)
            }
            return result.segments.map { .init(text: $0.text, quality: Self.quality(of: $0)) }
        }, emit: onProgress)
        let elapsed = started.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        Self.log.notice("""
            收尾補解碼：未解碼 \(tail.undecodedSeconds, format: .fixed(precision: 2), privacy: .public)s \
            窗口 \(tail.clipStartSeconds, format: .fixed(precision: 2), privacy: .public)s 起 \
            \(tail.windowSeconds, format: .fixed(precision: 2), privacy: .public)s \
            耗時 \(elapsedSeconds, format: .fixed(precision: 2), privacy: .public)s \
            結果 \(String(describing: outcome), privacy: .public)
            """)
    }
}

/// 接線函式（`progress(from:)`、`tailLedger`）讀的套件狀態欄位。抽成協定只為了測得到：
/// `AudioStreamTranscriber.State` 的 init 是 internal，測試建不出來。
protocol StreamerStateReading {
    var lastBufferSize: Int { get }
    var lastConfirmedSegmentEndSeconds: Float { get }
    var confirmedSegments: [TranscriptionSegment] { get }
    var unconfirmedSegments: [TranscriptionSegment] { get }
}

extension AudioStreamTranscriber.State: StreamerStateReading {}

/// 收尾補解碼的記帳（issue #22）。寫入端是套件的狀態變更回呼（套件 actor 內），
/// 讀取端是停止監看的 Task 與 `streamTranscribe` 本身，故以鎖保護。
final class StreamTailLedgerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = StreamTailDrain.Ledger()

    var current: StreamTailDrain.Ledger {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func record(_ ledger: StreamTailDrain.Ledger) {
        lock.lock(); defer { lock.unlock() }
        value = ledger
    }
}

/// `WhisperTranscribing` 的真實實作（spec §3.1）：以模型路徑為 key，經
/// `ModelLoadCoordinator` 做 single-flight 載入＋有界快取，載入失敗擲 `WhisperLoadError`。
public final class WhisperKitTranscriber: WhisperTranscribing {
    private let coordinator: ModelLoadCoordinator<WhisperKitModelActor>
    private let maxDuration: TimeInterval
    private let tracker: ModelLoadProgressTracker
    private let history: ModelLoadHistory

    /// 載入期以外的 log 等級。載入時降到 `.debug` 才收得到分階段里程碑（見 `modelConfig`）。
    private static let restingLogLevel: Logging.LogLevel = .info

    /// 安全網上限（秒）。串流不需要累積整段就能辨識，但套件的串流轉錄器要求樣本陣列
    /// 只增不減（見 `StreamFedAudioSource`），故音訊仍會線性成長，需要一個上限兜底。
    public init(maxDuration: TimeInterval = 30 * 60,
                history: ModelLoadHistory = ModelLoadHistory()) {
        self.maxDuration = maxDuration
        self.history = history

        // 轉發到我們自己的 subsystem（issue #17）。裝了 callback 之後套件就**不再**寫系統
        // logger（`Logging.log`：`if let callback { callback(m) } else { logger.log(...) }`），
        // 不轉發等於把開發者查錯用的資料弄不見。
        //
        // 現況本來就查不到：實測距上次載入不到 24 小時，
        // `log show --predicate 'category == "Argmax"' --last 24h --info --debug` 是 0 筆，
        // 而同一個 process 的其他 debug 紀錄有 3868 筆。轉到我們的 subsystem 至少能撈得到。
        let logger = Logger(subsystem: "io.saymend.app", category: "WhisperKit")
        let tracker = ModelLoadProgressTracker(forward: { message in
            logger.debug("\(message, privacy: .public)")
        })
        self.tracker = tracker
        tracker.installAsWhisperKitLogSink()

        coordinator = ModelLoadCoordinator<WhisperKitModelActor> { url in
            try await ModelLoadRun.perform(
                url: url, tracker: tracker, history: history,
                onFinish: { Logging.updateLogLevel(Self.restingLogLevel) },
                make: { try await WhisperKitModelActor(modelFolder: $0) })
        }
    }

    /// 目前這一趟載入的階段進度；沒有可用的進度資料時 nil（見 `ModelLoadProgressTracker.snapshot`）。
    public func loadProgress() async -> ModelLoadProgress? { tracker.snapshot() }

    /// 這顆模型上次載入花了多久；沒有紀錄時 nil。
    public func lastLoad(modelPath: URL) async -> CompletedLoad? { history.last(for: modelPath) }

    public func preload(modelPath: URL) async {
        await coordinator.preload(modelPath)
    }

    public func preloadSelection(modelPath: URL) async {
        await coordinator.preloadSelection(modelPath)
    }

    public func state(modelPath: URL) async -> ModelLoadState {
        await coordinator.state(for: modelPath)
    }

    public func unload() async {
        await coordinator.unload()
    }

    public func transcribe(modelPath: URL,
                           audio: AsyncStream<AudioChunk>,
                           language: String,
                           promptPhrases: [String],
                           options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [maxDuration, coordinator] in
                // 窗口與門檻在此給定而非等 streamTranscribe：模型載入可達數分鐘，那之前餵進來的
                // 音訊會先算完能量，晚到的設定救不回已經用舊值算掉的那幾十秒。
                let source = StreamFedAudioSource(maxDuration: maxDuration,
                                                  relativeEnergyWindow: options.relativeEnergyWindow,
                                                  silenceThreshold: options.silenceThreshold)
                let audioDone = Sendable_Flag()
                /// 音訊是**正常**收完的（issue #22）：只有這時才收尾補解碼。另外兩條讓 `audioDone`
                /// 成立的路（轉換失敗、超過上限）已經以錯誤結束串流，補了也沒人收。
                let audioFinishedNormally = Sendable_Flag()

                // 餵音訊：與辨識並行，音訊耗盡即標記結束讓串流轉錄器收工
                // **誠實說明覆蓋範圍**：下面這段餵音訊迴圈（含 0.5 秒降頻與收尾補一筆統計）
                // **沒有單元測試**——它要真的 `WhisperKitTranscriber`，而那需要載入真模型。
                // 引擎端消費 `audioStats` 的政策有完整測試（含 9 發變異），但「統計有沒有被發出來、
                // 頻率對不對」只有實機驗收擋得住。不得宣稱這段有測試覆蓋。
                let feeder = Task {
                    // 音訊統計降頻至每 0.5 秒一筆（issue #18）。逐 chunk 發是每 85ms 一次，
                    // 對「已經三秒沒人講話」這個判斷毫無增益，只是白白製造跨隔離域流量。
                    var lastStatsAt: TimeInterval = 0
                    for await chunk in audio {
                        if Task.isCancelled { break }
                        do { try source.append(chunk) } catch {
                            audioDone.set()
                            continuation.finish(throwing: WhisperStreamError.audioConversionFailed)
                            return
                        }
                        if source.isOverCapacity {
                            audioDone.set()
                            continuation.finish(throwing:
                                WhisperStreamError.overCapacity(minutes: Int(maxDuration / 60)))
                            return
                        }
                        let now = source.duration
                        if now - lastStatsAt >= 0.5 {
                            lastStatsAt = now
                            continuation.yield(.audioStats(voicedBuckets: source.voicedBuckets,
                                                           seconds: now))
                        }
                    }
                    source.finish()      // 排出重取樣器殘留，否則尾端音訊進不了樣本陣列
                    // 收尾必補一筆：引擎的「1.5 秒以上零語音就補示警」規則要拿最終數字判斷，
                    // 而短 session 可能一次降頻窗口都沒滿過，不補就完全沒有統計可依據。
                    continuation.yield(.audioStats(voicedBuckets: source.voicedBuckets,
                                                   seconds: source.duration))
                    // 先標正常收完、再標結束：停止監看看到結束時，補解碼的判定必須已經讀得到這一面。
                    // （Esc 不會取消這個 Task——它是 unstructured，只在 transcribe 收尾的 defer 被取消。
                    // 擋住取消後補解碼的是 `streamTranscribe` 迴圈離開後的 `Task.isCancelled`。）
                    audioFinishedNormally.set()
                    audioDone.set()
                }
                defer { feeder.cancel() }

                do {
                    // 載入與辨識為單一原子呼叫：擲 WhisperLoadError＝載入失敗
                    let model = try await coordinator.model(for: modelPath)
                    try await model.streamTranscribe(
                        source: source, language: language, promptPhrases: promptPhrases,
                        options: options,
                        onProgress: { continuation.yield(.progress($0)) },
                        onTailDrain: { continuation.yield(.drainingTail) },
                        shouldStop: { audioDone.isSet || Task.isCancelled },
                        tailDrainAllowed: { audioFinishedNormally.isSet })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 極小的跨隔離域旗標：音訊餵完之後通知串流轉錄器收工。
final class Sendable_Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    /// 設起來；原本沒設才回 true。「只做一次」的動作由回傳值決定，判斷與設定在同一把鎖內。
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
