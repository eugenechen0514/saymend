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
    /// 確保指定模型已載入後，對 16k mono Float 批次辨識。promptPhrases 由實作 tokenize。
    /// 載入失敗擲 `WhisperLoadError`；辨識失敗擲其他 error。
    func transcribe(modelPath: URL, samples: [Float], language: String,
                    promptPhrases: [String]) async throws -> String
}

/// WhisperKit 本機引擎（spec §3）：批次辨識——累積整段音訊，audio 串流結束後
/// 在本機單次辨識。結構比照 `WhisperRemoteEngine`，只把 HTTP 換成本機 WhisperKit。
///
/// 無 .volatile 事件（批次語意）；失敗一律以 .failed 明示原因，不靜默結束。
/// 失敗語彙自成一組（本機無網路概念），**不套** M7 的 `degradedReason`。
public final class WhisperKitEngine: ASREngine, ContextBiasable, @unchecked Sendable {
    /// 錄音時長硬上限，比照遠端引擎（spec §4.3）
    public static let defaultMaxDuration: TimeInterval = 600

    private let transcriber: any WhisperTranscribing
    private let configProvider: () -> WhisperLocalConfig
    private let maxDuration: TimeInterval

    /// 詞彙表偏置（spec §7）：與其他引擎吃同一個來源，交由實作 tokenize 成 promptTokens。
    public var contextualStrings: (@MainActor () -> [String])?

    private let stateLock = NSLock()
    private var pumpTask: Task<Void, Never>?

    public init(transcriber: any WhisperTranscribing,
                configProvider: @escaping () -> WhisperLocalConfig,
                maxDuration: TimeInterval = WhisperKitEngine.defaultMaxDuration) {
        self.transcriber = transcriber
        self.configProvider = configProvider
        self.maxDuration = maxDuration
    }

    /// 背景預載目前選定的模型（spec §6）。未選模型＝no-op，不視為錯誤。
    public func preload() async {
        guard let path = configProvider().selectedModelPath else { return }
        await transcriber.preload(modelPath: path)
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

    /// **取消限制（誠實記錄，spec §3.1）**：批次語意下 `cancel()` 在辨識/載入進行中
    /// 不保證瞬間中止該 async 工作；但每個 `await` 後一律檢查 `Task.isCancelled`、
    /// 取消時**不吐 `.finalized`**（fail-closed，無錯字上屏），串流於該工作返回後收尾。
    private func pump(audio: AsyncStream<AudioChunk>,
                      localeIdentifier: String,
                      continuation: AsyncStream<TranscriptEvent>.Continuation) async {
        let accumulator = WAVAccumulator()

        // 累積階段：逐 chunk 轉 16k/mono；達到時長上限當下立即失敗（比照遠端引擎）
        for await chunk in audio {
            if Task.isCancelled { continuation.finish(); return }
            do {
                try accumulator.append(chunk)
            } catch {
                continuation.yield(.failed(reason: "音訊轉換失敗"))
                continuation.finish()
                return
            }
            if accumulator.duration >= maxDuration {
                continuation.yield(.failed(reason: "錄音超過 10 分鐘上限"))
                continuation.finish()
                return
            }
        }
        if Task.isCancelled { continuation.finish(); return }

        // fail-closed：未選模型不得進辨識
        guard let modelPath = configProvider().selectedModelPath else {
            continuation.yield(.failed(reason: "未選擇本機模型"))
            continuation.finish()
            return
        }

        // 音訊收完、開始辨識；模型載入折進 .transcribing（不新增事件型別，HUD 零改動）
        continuation.yield(.transcribing)

        // 屬性讀取＋closure 呼叫都在 MainActor 上，理由同 WhisperRemoteEngine.biasPrompt() :148-155
        let phrases = await MainActor.run { [weak self] in self?.contextualStrings?() ?? [] }
        let samples = accumulator.floatSamples()
        let language = WhisperRemoteEngine.languageCode(from: localeIdentifier)

        do {
            let raw = try await transcriber.transcribe(modelPath: modelPath, samples: samples,
                                                       language: language, promptPhrases: phrases)
            if Task.isCancelled { continuation.finish(); return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continuation.yield(.failed(reason: "辨識結果為空"))
                continuation.finish()
                return
            }
            continuation.yield(.finalized(text))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch is WhisperLoadError {
            continuation.yield(.failed(reason: "模型載入失敗"))
            continuation.finish()
        } catch {
            continuation.yield(.failed(reason: "辨識失敗"))
            continuation.finish()
        }
    }
}
