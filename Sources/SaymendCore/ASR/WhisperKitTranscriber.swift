import Foundation
import WhisperKit

/// 每個模型一個 actor（spec §3.1）：`WhisperKit` **不是 Sendable**，故於此 actor 的 async init
/// 內自建、且 `tokenizer` 讀取與 `transcribe` 都留在 actor 內——pipe 全程不出隔離域、絕不跨界回傳。
/// 同一模型的辨識天然序列化在該 actor 上。
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

    public func transcribe(samples: [Float], language: String, promptPhrases: [String]) async throws -> String {
        var promptTokens: [Int]?
        if !promptPhrases.isEmpty, let tok = pipe.tokenizer {
            // 詞彙表偏置（spec §7）：tokenize 後濾掉特殊 token（id ≥ specialTokenBegin），只留文字 token
            let ids = tok.encode(text: " " + promptPhrases.joined(separator: " "))
                .filter { $0 < tok.specialTokens.specialTokenBegin }
            promptTokens = ids.isEmpty ? nil : ids
        }
        let opts = DecodingOptions(language: language.isEmpty ? nil : language,
                                   usePrefillPrompt: true,
                                   promptTokens: promptTokens)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
        return results.map(\.text).joined()
    }
}

/// `WhisperTranscribing` 的真實實作（spec §3.1）：以模型路徑為 key，經
/// `ModelLoadCoordinator` 做 single-flight 載入＋有界快取，載入失敗擲 `WhisperLoadError`。
public final class WhisperKitTranscriber: WhisperTranscribing {
    private let coordinator: ModelLoadCoordinator<WhisperKitModelActor>

    public init() {
        coordinator = ModelLoadCoordinator<WhisperKitModelActor> { url in
            try await WhisperKitModelActor(modelFolder: url)
        }
    }

    public func preload(modelPath: URL) async {
        await coordinator.preload(modelPath)
    }

    public func transcribe(modelPath: URL, samples: [Float], language: String,
                           promptPhrases: [String]) async throws -> String {
        // 載入與辨識為單一原子呼叫：擲 WhisperLoadError＝載入失敗，其他 error＝辨識失敗
        let model = try await coordinator.model(for: modelPath)
        return try await model.transcribe(samples: samples, language: language, promptPhrases: promptPhrases)
    }
}
