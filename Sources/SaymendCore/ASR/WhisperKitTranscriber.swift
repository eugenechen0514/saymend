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
            // tokenizerFolder 不指定＝交 WhisperKit 依模型自行解析（讀本機 HF 快取，已快取即離線）。
            // download: false＝一律不連網下載模型（複用磁碟既有 CoreML 模型）。
            let config = WhisperKitConfig(modelFolder: modelFolder.path,
                                          verbose: false, prewarm: true, load: true, download: false)
            self.pipe = try await WhisperKit(config)
        } catch {
            throw WhisperLoadError(message: String(describing: error))
        }
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

        var decoding = DecodingOptions(language: language.isEmpty ? nil : language,
                                       usePrefillPrompt: true,
                                       promptTokens: promptTokens)
        if let v = options.logProbThreshold { decoding.logProbThreshold = v }
        if let v = options.compressionRatioThreshold { decoding.compressionRatioThreshold = v }

        source.relativeEnergyWindow = options.relativeEnergyWindow

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
                    unconfirmed: new.unconfirmedSegments.map(\.text).joined()))
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
                           options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [maxDuration, coordinator] in
                let source = StreamFedAudioSource(maxDuration: maxDuration)
                let audioDone = Sendable_Flag()

                // 餵音訊：與辨識並行，音訊耗盡即標記結束讓串流轉錄器收工
                let feeder = Task {
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
                    }
                    source.finish()      // 排出重取樣器殘留，否則尾端音訊進不了樣本陣列
                    audioDone.set()
                }
                defer { feeder.cancel() }

                do {
                    // 載入與辨識為單一原子呼叫：擲 WhisperLoadError＝載入失敗
                    let model = try await coordinator.model(for: modelPath)
                    try await model.streamTranscribe(
                        source: source, language: language, promptPhrases: promptPhrases,
                        options: options,
                        onProgress: { continuation.yield($0) },
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
