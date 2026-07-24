import Testing
import Foundation
@testable import SaymendCore

private enum FX {
    static func dir(_ u: URL) throws { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    static func file(_ u: URL, _ s: String = "x") throws { try s.data(using: .utf8)!.write(to: u) }
    static func temp() throws -> URL { let b = FileManager.default.temporaryDirectory.appending(path: "wkscan-\(UUID().uuidString)"); try dir(b); return b }
    static func whisperModel(_ parent: URL, _ name: String) throws -> URL {
        let m = parent.appending(path: name)
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try dir(m.appending(path: "\(c).mlmodelc")) }
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
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram", "MultimodalLogits"] { try FX.dir(m.appending(path: "\(c).mlmodelc")) }
        guard case .coreMLNonWhisper = WhisperKitModelScanner.classify(directory: m, fileManager: .default) else { Issue.record("預期 nonWhisper"); return }
    }
    @Test func configWithSpacedJSONParsedByParser() throws {
        // 空白變體：字串 contains 會漏，JSONSerialization 不會
        let m = try FX.temp().appending(path: "unnamed")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.dir(m.appending(path: "\(c).mlmodelc")) }
        try FX.file(m.appending(path: "config.json"), #"{ "model_type" : "whisper" }"#)
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .whisperKitUsable)
    }
    @Test func trioWithoutWhisperProofIsNonWhisper() throws {
        let m = try FX.temp().appending(path: "mystery")
        for c in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] { try FX.dir(m.appending(path: "\(c).mlmodelc")) }
        guard case .coreMLNonWhisper = WhisperKitModelScanner.classify(directory: m, fileManager: .default) else { Issue.record("無證據不得 usable"); return }
    }
    @Test func safetensorsIsMLX() throws {
        let m = try FX.temp().appending(path: "whisper-large-v3-turbo")
        try FX.dir(m)
        try FX.file(m.appending(path: "model.safetensors")); try FX.file(m.appending(path: "config.json"), #"{"model_type":"whisper"}"#)
        #expect(WhisperKitModelScanner.classify(directory: m, fileManager: .default) == .mlxSafetensors)
    }
    @Test func scanClassifiesModelRootItself() throws {
        let m = try FX.whisperModel(try FX.temp(), "openai_whisper-tiny")
        let r = WhisperKitModelScanner().scan(roots: [m])
        #expect(r.count == 1); #expect(r.first?.kind == .whisperKitUsable)
    }
    @Test func scanCorruptRootListedAsUnknownNotDescended() throws {
        let m = try FX.temp().appending(path: "broken")
        try FX.dir(m.appending(path: "AudioEncoder.mlmodelc"))   // 只有一件＝有 marker 但不齊
        let r = WhisperKitModelScanner().scan(roots: [m])
        #expect(r.count == 1); #expect(r.first?.kind == .unknown)
    }
    @Test func scanChildrenAndDedupe() throws {
        let root = try FX.temp(); _ = try FX.whisperModel(root, "openai_whisper-small")
        let r = WhisperKitModelScanner().scan(roots: [root, root])
        #expect(r.count == 1); #expect(r.first?.displayName == "openai_whisper-small")
    }
}
