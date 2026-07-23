import AVFoundation
import Foundation

/// Whisper 遠端引擎（spec §4）：批次辨識——累積整段音訊，audio 串流結束後單次
/// multipart POST 到 OpenAI `audio/transcriptions` 相容端點。
/// 無 .volatile 事件（批次語意）；失敗一律以 .failed 明示原因，不靜默結束。
public final class WhisperRemoteEngine: ASREngine, ContextBiasable, @unchecked Sendable {
    /// 錄音時長硬上限（spec §4.3）。16kHz mono PCM16 ≈ 32KB/s，10 分鐘 ≈ 19MB。
    public static let defaultMaxDuration: TimeInterval = 600
    private static let promptCharacterLimit = 500

    private let configProvider: () -> WhisperRemoteConfig?
    private let session: URLSession
    private let maxDuration: TimeInterval

    /// 詞彙表偏置（spec §4.4）：與 SpeechAnalyzerEngine 吃同一個來源，
    /// 拼成 OpenAI transcriptions 的 prompt 參數。標 @MainActor 的理由同該引擎。
    public var contextualStrings: (@MainActor () -> [String])?

    private let stateLock = NSLock()
    private var pumpTask: Task<Void, Never>?

    public init(configProvider: @escaping () -> WhisperRemoteConfig?,
                session: URLSession = .shared,
                maxDuration: TimeInterval = WhisperRemoteEngine.defaultMaxDuration) {
        self.configProvider = configProvider
        self.session = session
        self.maxDuration = maxDuration
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

    private func pump(audio: AsyncStream<AudioChunk>,
                      localeIdentifier: String,
                      continuation: AsyncStream<TranscriptEvent>.Continuation) async {
        let accumulator = WAVAccumulator()

        // 累積階段：逐 chunk 轉檔；達到時長上限當下立即失敗（不等使用者放開熱鍵，spec §4.3）
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

        // fail-closed：端點未設定不得發請求（spec §4.7）
        guard let config = configProvider() else {
            continuation.yield(.failed(reason: "Whisper 端點未設定"))
            continuation.finish()
            return
        }

        continuation.yield(.transcribing)          // 音訊收完、開始上傳

        let prompt = await biasPrompt()
        let boundary = "saymend-\(UUID().uuidString)"
        let body = Self.multipartBody(wav: accumulator.wavData(),
                                      model: config.model,
                                      language: Self.languageCode(from: localeIdentifier),
                                      prompt: prompt,
                                      boundary: boundary)

        var req = URLRequest(url: config.baseURL.appending(path: "audio/transcriptions"),
                             timeoutInterval: config.timeout)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        do {
            let (data, resp) = try await session.data(for: req)
            if Task.isCancelled { continuation.finish(); return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                continuation.yield(.failed(reason: degradedReason(for: LLMError.badStatus(code),
                                                                  timeout: config.timeout)))
                continuation.finish()
                return
            }
            guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                continuation.yield(.failed(reason: "回應格式不合法"))
                continuation.finish()
                return
            }
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // 語彙走 degradedReason（M7 唯一定義點），不另寫字面值
                continuation.yield(.failed(reason: degradedReason(for: LLMError.emptyResponse,
                                                                  timeout: config.timeout)))
                continuation.finish()
                return
            }
            continuation.yield(.finalized(text))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch let e as URLError where e.code == .cancelled {
            continuation.finish()
        } catch let e as URLError where e.code == .timedOut {
            // 逾時語彙與 M7 一致（degradedReason 是全專案唯一定義點）
            continuation.yield(.failed(reason: degradedReason(for: LLMError.timedOut,
                                                              timeout: config.timeout)))
            continuation.finish()
        } catch {
            continuation.yield(.failed(reason: degradedReason(for: error, timeout: config.timeout)))
            continuation.finish()
        }
    }

    private struct TranscriptionResponse: Decodable { let text: String }

    /// 詞彙表 → prompt 偏置字串。空詞彙表回 nil（不送空欄位）；超長截斷（偏置是加分項非必要條件）。
    private func biasPrompt() async -> String? {
        guard let provider = contextualStrings else { return nil }
        let phrases = await MainActor.run { provider() }
        guard !phrases.isEmpty else { return nil }
        let joined = phrases.joined(separator: "、")
        return joined.count <= Self.promptCharacterLimit
            ? joined
            : String(joined.prefix(Self.promptCharacterLimit))
    }

    /// "zh-TW" → "zh"（OpenAI transcriptions 的 language 參數要 ISO-639-1）
    static func languageCode(from localeIdentifier: String) -> String {
        String(localeIdentifier.split(separator: "-").first ?? "")
    }

    static func multipartBody(wav: Data, model: String, language: String,
                              prompt: String?, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("model", model)
        if !language.isEmpty { field("language", language) }
        if let prompt { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
