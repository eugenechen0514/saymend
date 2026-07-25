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
    /// CoreML bundle 內部的內容標記：`.mlmodelc` 為 coremldata.bin／model.mil，
    /// `.mlpackage` 為 Manifest.json／Data。只有目錄名存在不足以認定可用——
    /// 下載中斷會留下空的 bundle 目錄，載入時才炸（REV #6）。
    private static let bundleContentMarkers: Set<String> = ["coremldata.bin", "model.mil", "Manifest.json", "Data"]

    private static func isValidBundle(_ parent: URL, _ name: String, _ fm: FileManager) -> Bool {
        let inner = entries(parent.appending(path: name), fm)
        return inner.contains { bundleContentMarkers.contains($0) }
    }

    /// trio 元件：`.mlmodelc` 或 `.mlpackage` 皆可（REV #5），且該 bundle 須有內容（REV #6）
    private static func hasValidComponent(_ dir: URL, _ base: String, _ fm: FileManager) -> Bool {
        isValidBundle(dir, "\(base).mlmodelc", fm) || isValidBundle(dir, "\(base).mlpackage", fm)
    }

    static func hasValidTrio(_ dir: URL, _ fm: FileManager) -> Bool {
        hasValidComponent(dir, "AudioEncoder", fm)
            && hasValidComponent(dir, "TextDecoder", fm)
            && hasValidComponent(dir, "MelSpectrogram", fm)
    }

    /// root-marker 收斂（REV #7）：只有「完整有效 trio」或「明確 safetensors」才把該目錄
    /// 當成模型本身而不再往下掃；零星／不齊的 bundle 仍須列舉子目錄，否則父目錄裡有雜物
    /// （半個下載殘骸）就會讓底下的真模型全被漏掉。
    static func isModelDirectory(_ dir: URL, _ fm: FileManager) -> Bool {
        hasValidTrio(dir, fm) || entries(dir, fm).contains("model.safetensors")
    }

    public static func classify(directory dir: URL, fileManager fm: FileManager) -> DiscoveredModelKind {
        let list = entries(dir, fm)
        func has(_ n: String) -> Bool { list.contains(n) }
        let trio = hasValidTrio(dir, fm)
        let anyMLModelC = list.contains { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
        if trio {
            let tags = configTags(dir)
            if has("MultimodalLogits.mlmodelc") || has("MultimodalLogits.mlpackage")
                || tags.contains("parakeet") || tags.contains("ctc") {
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
            // symlink 一併解析後才當去重 key（REV #8）：同一實體目錄經 symlink 掃到不得重複列出
            let std = dir.resolvingSymlinksInPath().standardizedFileURL
            guard !seen.contains(std) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(std)
            out.append(DiscoveredModel(displayName: dir.lastPathComponent, path: std,
                                       kind: Self.classify(directory: dir, fileManager: fm),
                                       sizeBytes: Self.dirSize(dir, fm)))
        }
        for root in roots {
            if Self.isModelDirectory(root, fm) { consider(root); continue }   // root 本身即模型
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
