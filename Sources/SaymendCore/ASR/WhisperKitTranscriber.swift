import Foundation
import WhisperKit

/// 每個模型一個 actor（spec §3.1）：`WhisperKit` **不是 Sendable**，故於此 actor 的 async init
/// 內自建、且 `tokenizer` 讀取與辨識都留在 actor 內——pipe 全程不出隔離域、絕不跨界回傳。
///
/// 串流轉錄器（issue #12）同樣**在此 actor 內建構並持有**：它的 init 需要 pipe 的六個
/// 子元件（encoder／decoder／tokenizer…），在外部組裝就會讓非 Sendable 的它們跨越隔離邊界。
/// 專案處於 Swift 5 語言模式，那樣只會是警告而非錯誤——**編得過不代表對**。
public actor WhisperKitModelActor {
    private let pipe: WhisperKit

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
    /// `verbose: true` ＋ `.info`：只吐載入階段的里程碑（各子模型耗時、總耗時），不含逐 buffer
    /// 的除錯訊息。載入期間 CPU 幾乎為 0（工作在 CoreML／ANE 側），沒有這些訊息時
    /// 「還在載」與「已經死了」在外部完全無法區分——這正是本次查錯耗掉大半時間的原因。
    static func modelConfig(modelFolder: URL) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: modelFolder.path,
                         verbose: true, logLevel: .info,
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

    /// 串流辨識：音訊由 `source` 灌入（呼叫端負責餵），進度經回呼吐出。
    /// 本方法在串流結束（呼叫端停止或音訊耗盡）前不返回。
    func streamTranscribe(source: StreamFedAudioSource,
                          language: String,
                          promptPhrases: [String],
                          options: WhisperStreamingOptions,
                          onProgress: @escaping @Sendable (WhisperStreamProgress) -> Void,
                          shouldStop: @escaping @Sendable () -> Bool) async throws {
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
                onProgress(WhisperStreamProgress(
                    confirmed: new.confirmedSegments.map(\.text).joined(),
                    unconfirmed: new.unconfirmedSegments.map(\.text).joined(),
                    confirmedQuality: new.confirmedSegments.map(Self.quality(of:)),
                    unconfirmedQuality: new.unconfirmedSegments.map(Self.quality(of:))))
            })

        // 停止監看：串流轉錄器的主迴圈在 stopStreamTranscription 之前不返回
        let stopWatcher = Task {
            while !Task.isCancelled {
                if shouldStop() {
                    await streamer.stopStreamTranscription()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { stopWatcher.cancel() }
        try await streamer.startStreamTranscription()
    }
}

/// `WhisperTranscribing` 的真實實作（spec §3.1）：以模型路徑為 key，經
/// `ModelLoadCoordinator` 做 single-flight 載入＋有界快取，載入失敗擲 `WhisperLoadError`。
public final class WhisperKitTranscriber: WhisperTranscribing {
    private let coordinator: ModelLoadCoordinator<WhisperKitModelActor>
    private let maxDuration: TimeInterval

    /// 安全網上限（秒）。串流不需要累積整段就能辨識，但套件的串流轉錄器要求樣本陣列
    /// 只增不減（見 `StreamFedAudioSource`），故音訊仍會線性成長，需要一個上限兜底。
    public init(maxDuration: TimeInterval = 30 * 60) {
        self.maxDuration = maxDuration
        coordinator = ModelLoadCoordinator<WhisperKitModelActor> { url in
            try await WhisperKitModelActor(modelFolder: url)
        }
    }

    public func preload(modelPath: URL) async {
        await coordinator.preload(modelPath)
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
                        shouldStop: { audioDone.isSet || Task.isCancelled })
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
}
