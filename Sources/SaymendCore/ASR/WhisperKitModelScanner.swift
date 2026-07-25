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
    /// 本機是否已有此模型的 tokenizer（false＝首次使用會向 HF 取一次 tokenizer，非全程離線）
    public var tokenizerCached: Bool
    public init(displayName: String, path: URL, kind: DiscoveredModelKind, sizeBytes: Int64,
                tokenizerCached: Bool) {
        self.displayName = displayName; self.path = path; self.kind = kind; self.sizeBytes = sizeBytes
        self.tokenizerCached = tokenizerCached
    }
}

public struct WhisperKitModelScanner {
    private let fm: FileManager
    private let hubDownloadBase: URL
    public init(fileManager: FileManager = .default,
                hubDownloadBase: URL = WhisperKitModelScanner.defaultHubDownloadBase) {
        self.fm = fileManager
        self.hubDownloadBase = hubDownloadBase
    }

    public static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml")]
    }

    /// swift-transformers HubApi 的預設 downloadBase（HubApi.swift:105-110 逐字對照：
    /// documentDirectory ＋ "huggingface"）。tokenizer 快取即落在其 `models/<repo>` 之下。
    public static var defaultHubDownloadBase: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents"))
            .appending(path: "huggingface")
    }

    /// 模型目錄名 → WhisperKit 會去要的 tokenizer repo id。
    ///
    /// WhisperKit 由模型維度 detectVariant 出 11 個 ModelVariant 之一，再經
    /// `tokenizerNameForVariant`（ModelUtilities.swift:175-202）換成 `openai/whisper-*`；
    /// large-v3 的 turbo／日期版本全部歸到 `openai/whisper-large-v3`。此處由目錄名反推同一組
    /// 對照：去掉 `_NNNmb` 容量、`_turbo`、`-vYYYYMMDD` 日期後綴後查表，**對不到就回 nil**
    /// （保守標「首次需連網」，寧可少承諾也不給假的離線保證）。
    static func tokenizerRepoID(forModelDirectoryNamed name: String) -> String? {
        let known: Set<String> = ["tiny", "tiny.en", "base", "base.en", "small", "small.en",
                                  "medium", "medium.en", "large", "large-v2", "large-v3"]
        let lower = name.lowercased()
        let prefix = "openai_whisper-"
        guard lower.hasPrefix(prefix) else { return nil }
        var rest = String(lower.dropFirst(prefix.count))
        rest = rest.replacingOccurrences(of: "_[0-9]+mb$", with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: "_turbo$", with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: "-v[0-9]{8}$", with: "", options: .regularExpression)
        return known.contains(rest) ? "openai/whisper-\(rest)" : nil
    }

    /// 本機是否已有此模型的 tokenizer（REV #2）。位置與順序照 WhisperKit 1.0.0 實際會搜的三處：
    /// A `<hubDownloadBase>/models/<repo>`、B 模型目錄自帶、C `<模型目錄>/models/<repo>`
    /// （ModelUtilities.loadTokenizer:17-54 ＋ WhisperKit.swift:462-470）。
    /// Python huggingface_hub 的 `~/.cache/huggingface/hub` 佈局 Swift 端不讀，故不認。
    public static func tokenizerCached(directory dir: URL, hubDownloadBase: URL,
                                       fileManager fm: FileManager) -> Bool {
        func hasTokenizer(_ folder: URL) -> Bool {
            fm.fileExists(atPath: folder.appending(path: "tokenizer.json").path)
        }
        func repoFolder(under base: URL, _ repo: String) -> URL {
            var out = base.appending(path: "models")
            for component in repo.split(separator: "/") { out = out.appending(path: String(component)) }
            return out
        }
        if hasTokenizer(dir) { return true }                                     // B
        guard let repo = tokenizerRepoID(forModelDirectoryNamed: dir.lastPathComponent) else { return false }
        return hasTokenizer(repoFolder(under: hubDownloadBase, repo))            // A
            || hasTokenizer(repoFolder(under: dir, repo))                        // C
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
            let kind = Self.classify(directory: dir, fileManager: fm)
            out.append(DiscoveredModel(
                displayName: dir.lastPathComponent, path: std,
                kind: kind,
                // 只有模型候選才遞迴算大小（REV #4）：使用者指到的資料夾底下可能有海量無關檔案，
                // 對非候選遞迴 enumerate 會把掃描拖到數秒起跳。
                sizeBytes: kind == .unknown ? 0 : Self.dirSize(dir, fm),
                // 用解析後的 std 而非 dir：使用者把模型 symlink 成別名時，variant 要從真實
                // 目錄名反推，否則已快取的 tokenizer 會被誤標成「首次需連網」。
                // displayName 仍用 dir.lastPathComponent，讓使用者看到自己取的名字。
                tokenizerCached: Self.tokenizerCached(directory: std,
                                                      hubDownloadBase: hubDownloadBase,
                                                      fileManager: fm)))
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
