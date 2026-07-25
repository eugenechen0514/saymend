import Testing
import Foundation
@testable import SaymendCore

private enum FX {
    static func dir(_ u: URL) throws { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    static func file(_ u: URL, _ s: String = "x") throws { try s.data(using: .utf8)!.write(to: u) }
    static func temp() throws -> URL { let b = FileManager.default.temporaryDirectory.appending(path: "wkscan-\(UUID().uuidString)"); try dir(b); return b }
    /// 有效的 CoreML bundle：目錄內含實際內容（空目錄＝下載中斷／損毀）
    static func bundle(_ parent: URL, _ name: String) throws {
        let b = parent.appending(path: name)
        try dir(b)
        try file(b.appending(path: name.hasSuffix(".mlpackage") ? "Manifest.json" : "coremldata.bin"))
    }
    static func whisperModel(_ parent: URL, _ name: String) throws -> URL {
        let m = parent.appending(path: name)
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try bundle(m, "\(c).mlmodelc") }
        try file(m.appending(path: "config.json"), #"{"model_type":"whisper"}"#); return m
    }
}

@Suite struct WhisperKitModelScannerTests {
    @Test func whisperModelUsable() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-large-v3_turbo")
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .whisperKitUsable)
    }
    @Test func parakeetIsNonWhisper() throws {
        let m = try FX.temp().appending(path: "nvidia_parakeet-v3")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram", "MultimodalLogits"] { try FX.bundle(m, "\(c).mlmodelc") }
        guard case .coreMLNonWhisper = WhisperKitModelScanner.classify(directory: m, fileManager: .default) else { Issue.record("預期 nonWhisper"); return }
    }
    @Test func configWithSpacedJSONParsedByParser() throws {
        // 空白變體：字串 contains 會漏，JSONSerialization 不會
        let m = try FX.temp().appending(path: "unnamed")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.bundle(m, "\(c).mlmodelc") }
        try FX.file(m.appending(path: "config.json"), #"{ "model_type" : "whisper" }"#)
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .whisperKitUsable)
    }
    @Test func trioWithoutWhisperProofIsNonWhisper() throws {
        let m = try FX.temp().appending(path: "mystery")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.bundle(m, "\(c).mlmodelc") }
        guard case .coreMLNonWhisper = WhisperKitModelScanner.classify(directory: m, fileManager: .default) else { Issue.record("無證據不得 usable"); return }
    }
    @Test func safetensorsIsMLX() throws {
        let m = try FX.temp().appending(path: "whisper-large-v3-turbo")
        try FX.dir(m)
        try FX.file(m.appending(path: "model.safetensors")); try FX.file(m.appending(path: "config.json"), #"{"model_type":"whisper"}"#)
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .mlxSafetensors)
    }

    // MARK: - .mlpackage（REV #5）

    @Test func mlpackageTrioIsUsable() throws {
        let m = try FX.temp().appending(path: "openai_whisper-base")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.bundle(m, "\(c).mlpackage") }
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .whisperKitUsable)
    }
    @Test func mlpackageRootIsScannedAsModel() throws {
        let m = try FX.temp().appending(path: "openai_whisper-base")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.bundle(m, "\(c).mlpackage") }
        let r = WhisperKitModelScanner().scan(roots: [m])
        #expect(r.count == 1); #expect(r.first?.kind == .whisperKitUsable)
    }

    // MARK: - 損毀 bundle（REV #6）

    @Test func emptyBundleIsNotUsable() throws {
        let m = try FX.temp().appending(path: "openai_whisper-tiny")
        for c in ["AudioEncoder", "TextDecoder"] { try FX.bundle(m, "\(c).mlmodelc") }
        try FX.dir(m.appending(path: "MelSpectrogram.mlmodelc"))      // 空目錄＝下載中斷／損毀
        try FX.file(m.appending(path: "config.json"), #"{"model_type":"whisper"}"#)
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .unknown)
    }

    // MARK: - root-marker 短路收斂（REV #7）

    @Test func scanIncompleteRootDescendsIntoChildren() throws {
        let root = try FX.temp()
        try FX.bundle(root, "AudioEncoder.mlmodelc")                  // 零星 bundle：不足以認定 root 是模型
        _ = try FX.whisperModel(root, "openai_whisper-tiny")          // 真模型在子目錄，不得被短路漏掉
        let r = WhisperKitModelScanner().scan(roots: [root])
        #expect(r.contains { $0.displayName == "openai_whisper-tiny" && $0.kind == .whisperKitUsable })
    }
    @Test func scanCompleteRootShortCircuits() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-tiny")
        let r = WhisperKitModelScanner().scan(roots: [m])
        #expect(r.count == 1)                                         // 完整 trio＝root 即模型，不再往下掃
        #expect(r.first?.kind == .whisperKitUsable)
    }

    // MARK: - symlink 去重（REV #8）

    @Test func scanDedupesSymlinkedRoot() throws {
        let base = try FX.temp()
        let real = try FX.whisperModel(base, "openai_whisper-small")
        let link = base.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let r = WhisperKitModelScanner().scan(roots: [real, link])
        #expect(r.count == 1)
    }

    // MARK: - tokenizer 快取判定（REV #2）
    //
    // 位置以 WhisperKit 1.0.0 實際搜尋順序為準（ModelUtilities.loadTokenizer:17-54）：
    // A. <hubDownloadBase>/models/openai/whisper-<variant>/tokenizer.json（預設 ~/Documents/huggingface）
    // B. <模型目錄>/tokenizer.json
    // C. <模型目錄>/models/openai/whisper-<variant>/tokenizer.json
    // Python 的 ~/.cache/huggingface/hub 佈局 Swift 端不讀，故不認。

    @Test func tokenizerCachedWhenBundledInModelFolder() throws {          // B
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-tiny")
        try FX.file(m.appending(path: "tokenizer.json"), "{}")
        #expect(WhisperKitModelScanner.tokenizerCached(directory: m,
                                                       hubDownloadBase: try FX.temp(),
                                                       fileManager: .default))
    }
    @Test func tokenizerCachedFromHubDownloadBase() throws {               // A（含 _turbo/_632MB 後綴映射）
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-large-v3_turbo_632MB")
        let hub = try FX.temp()
        let repo = hub.appending(path: "models/openai/whisper-large-v3")
        try FX.dir(repo); try FX.file(repo.appending(path: "tokenizer.json"), "{}")
        #expect(WhisperKitModelScanner.tokenizerCached(directory: m, hubDownloadBase: hub, fileManager: .default))
    }
    @Test func tokenizerCachedFromModelFolderHubLayout() throws {          // C
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-base.en")
        let repo = m.appending(path: "models/openai/whisper-base.en")
        try FX.dir(repo); try FX.file(repo.appending(path: "tokenizer.json"), "{}")
        #expect(WhisperKitModelScanner.tokenizerCached(directory: m, hubDownloadBase: try FX.temp(), fileManager: .default))
    }
    @Test func tokenizerNotCachedWhenAbsent() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-large-v3")
        #expect(!WhisperKitModelScanner.tokenizerCached(directory: m, hubDownloadBase: try FX.temp(), fileManager: .default))
    }
    @Test func datedVariantMapsToBaseTokenizerRepo() throws {              // large-v3-v20240930_turbo → large-v3
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-large-v3-v20240930_turbo_632MB")
        let hub = try FX.temp()
        let repo = hub.appending(path: "models/openai/whisper-large-v3")
        try FX.dir(repo); try FX.file(repo.appending(path: "tokenizer.json"), "{}")
        #expect(WhisperKitModelScanner.tokenizerCached(directory: m, hubDownloadBase: hub, fileManager: .default))
    }
    @Test func unmappableNameIsConservativelyUncached() throws {           // 對不到表＝保守標未快取
        let m = try FX.whisperModel(try FX.temp(), "some_custom_model")
        let hub = try FX.temp()
        let repo = hub.appending(path: "models/openai/whisper-large-v3")
        try FX.dir(repo); try FX.file(repo.appending(path: "tokenizer.json"), "{}")
        #expect(!WhisperKitModelScanner.tokenizerCached(directory: m, hubDownloadBase: hub, fileManager: .default))
    }
    @Test func scanReportsTokenizerCached() throws {
        let base = try FX.temp()
        let m = try FX.whisperModel(base, "openai_whisper-small")
        try FX.file(m.appending(path: "tokenizer.json"), "{}")
        let r = WhisperKitModelScanner(fileManager: .default, hubDownloadBase: try FX.temp()).scan(roots: [m])
        #expect(r.first?.tokenizerCached == true)
    }
    /// 使用者把模型 symlink 成自己的別名時，tokenizer 判定要看解析後的真實目錄名，
    /// 否則會對已快取的模型誤標「首次需連網」——正好違背誠實化的目的。
    @Test func tokenizerCachedThroughSymlinkAlias() throws {
        let base = try FX.temp()
        let real = try FX.whisperModel(base, "openai_whisper-large-v3")
        let hub = try FX.temp()
        let repo = hub.appending(path: "models/openai/whisper-large-v3")
        try FX.dir(repo); try FX.file(repo.appending(path: "tokenizer.json"), "{}")
        let alias = base.appending(path: "whisperLocal")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let r = WhisperKitModelScanner(fileManager: .default, hubDownloadBase: hub).scan(roots: [alias])
        #expect(r.count == 1)
        #expect(r.first?.displayName == "whisperLocal")     // 顯示使用者自己取的名字
        #expect(r.first?.tokenizerCached == true)           // 判定卻用解析後的真實名稱
    }

    @Test func scanReportsTokenizerMissing() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-small")
        let r = WhisperKitModelScanner(fileManager: .default, hubDownloadBase: try FX.temp()).scan(roots: [m])
        #expect(r.first?.tokenizerCached == false)
    }

    // MARK: - 大小只對模型候選計算（REV #4：非模型目錄遞迴 enumerate 會拖慢掃描）

    @Test func sizeSkippedForNonModelDirectory() throws {
        let root = try FX.temp()
        let junk = root.appending(path: "not-a-model")
        try FX.dir(junk)
        try FX.file(junk.appending(path: "big.bin"), String(repeating: "x", count: 4096))
        let r = WhisperKitModelScanner(fileManager: .default, hubDownloadBase: try FX.temp()).scan(roots: [root])
        let entry = r.first { $0.displayName == "not-a-model" }
        #expect(entry?.kind == .unknown)
        #expect(entry?.sizeBytes == 0)
    }
    @Test func sizeComputedForModelCandidate() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-tiny")
        let r = WhisperKitModelScanner(fileManager: .default, hubDownloadBase: try FX.temp()).scan(roots: [m])
        #expect((r.first?.sizeBytes ?? 0) > 0)
    }

    @Test func scanClassifiesModelRootItself() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-tiny")
        let r = WhisperKitModelScanner().scan(roots: [m])
        #expect(r.count == 1); #expect(r.first?.kind == .whisperKitUsable)
    }
    @Test func scanChildrenAndDedupe() throws {
        let root = try FX.temp(); _ = try FX.whisperModel(root, "openai_whisper-small")
        let r = WhisperKitModelScanner().scan(roots: [root, root])
        #expect(r.count == 1); #expect(r.first?.displayName == "openai_whisper-small")
    }
}
