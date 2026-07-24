import Foundation

public enum DiscoveredModelKind: Equatable, Sendable {
    case whisperKitUsable
    case coreMLNonWhisper(reason: String)
    case mlxSafetensors
    case unknown
}

public struct DiscoveredModel: Equatable, Sendable, Identifiable {
    public var id: URL { path }
    public var displayName: String
    public var path: URL
    public var kind: DiscoveredModelKind
    public var sizeBytes: Int64
    public init(displayName: String, path: URL, kind: DiscoveredModelKind, sizeBytes: Int64) {
        self.displayName = displayName; self.path = path; self.kind = kind; self.sizeBytes = sizeBytes
    }
}

public struct WhisperKitModelScanner {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    public static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml")]
    }

    private static func entries(_ dir: URL, _ fm: FileManager) -> [String] {
        (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    }
    /// 讀 config.json 的 model_type + architectures，合成小寫字串供判斷（非字串比對整檔）。
    private static func configTags(_ dir: URL) -> String {
        guard let data = try? Data(contentsOf: dir.appending(path: "config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let mt = (obj["model_type"] as? String) ?? ""
        let arch = (obj["architectures"] as? [String])?.joined(separator: ",") ?? ""
        return (mt + "," + arch).lowercased()
    }
    static func hasModelMarker(_ dir: URL, _ fm: FileManager) -> Bool {
        entries(dir, fm).contains { $0.hasSuffix(".mlmodelc") || $0 == "model.safetensors" }
    }

    public static func classify(directory dir: URL, fileManager fm: FileManager) -> DiscoveredModelKind {
        let list = entries(dir, fm)
        func has(_ n: String) -> Bool { list.contains(n) }
        let trio = has("AudioEncoder.mlmodelc") && has("TextDecoder.mlmodelc") && has("MelSpectrogram.mlmodelc")
        let anyMLModelC = list.contains { $0.hasSuffix(".mlmodelc") }
        if trio {
            let tags = configTags(dir)
            if has("MultimodalLogits.mlmodelc") || tags.contains("parakeet") || tags.contains("ctc") {
                return .coreMLNonWhisper(reason: "非 whisper（Parakeet/CTC）")
            }
            let isWhisper = dir.lastPathComponent.lowercased().contains("openai_whisper") || tags.contains("whisper")
            return isWhisper ? .whisperKitUsable : .coreMLNonWhisper(reason: "無法確認為 whisper")
        }
        if has("model.safetensors") && !anyMLModelC { return .mlxSafetensors }
        return .unknown
    }

    public func scan(roots: [URL]) -> [DiscoveredModel] {
        var out: [DiscoveredModel] = []
        var seen = Set<URL>()
        func consider(_ dir: URL) {
            let std = dir.standardizedFileURL
            guard !seen.contains(std) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(std)
            out.append(DiscoveredModel(displayName: dir.lastPathComponent, path: std,
                                       kind: Self.classify(directory: dir, fileManager: fm),
                                       sizeBytes: Self.dirSize(dir, fm)))
        }
        for root in roots {
            if Self.hasModelMarker(root, fm) { consider(root); continue }   // root 即模型（含損毀）
            let children = (try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for c in children { consider(c) }
        }
        return out
    }

    private static func dirSize(_ url: URL, _ fm: FileManager) -> Int64 {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t: Int64 = 0
        for case let f as URL in en { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return t
    }
}
