import Foundation

/// 偵測結果（spec §4.1）。設定 UI 據此顯示綠勾／紅字；provider 據此取得 cliPath。
public enum ClaudeCLIDetection: Equatable, Sendable {
    case found(path: String, version: String)
    case notFound
    case incompatible(path: String, reason: String)
}

/// CLI 偵測管線三關（spec §4.1）：可執行檢查 → 版本 capability probe → (path, mtime) 快取。
/// actor：快取是可變狀態、設定 UI 與 provider 都會呼叫。
public actor ClaudeCLIDetector {
    /// 最低支援版本（spec §4.1；hermetic flags 齊備的本機驗證版本。Task 1 spike 定案後如需調整改此處）
    public static let minimumVersion = (major: 2, minor: 1, patch: 216)

    /// 官方/常見安裝位置（spec §4.1 順序）；~/.local/bin 是官方 native installer 預設。
    public static let candidates = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.claude/local/claude",
        "~/.npm-global/bin/claude",
    ]

    private let isExecutableFile: @Sendable (String) -> Bool
    private let modificationDate: @Sendable (String) -> Date?
    private let versionProbe: @Sendable (String) async -> String?
    private var cache: [String: (mtime: Date?, result: ClaudeCLIDetection)] = [:]

    public init(isExecutableFile: @escaping @Sendable (String) -> Bool,
                modificationDate: @escaping @Sendable (String) -> Date?,
                versionProbe: @escaping @Sendable (String) async -> String?) {
        self.isExecutableFile = isExecutableFile
        self.modificationDate = modificationDate
        self.versionProbe = versionProbe
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// override 有值＝只考慮 override（壞掉直接紅、不靜默 fallback）；nil＝掃候選。
    public func detect(override: String?) async -> ClaudeCLIDetection {
        let paths = override.map { [Self.expand($0)] } ?? Self.candidates.map(Self.expand)
        for p in paths where isExecutableFile(p) {
            return await probeWithCache(p)
        }
        return .notFound
    }

    private func probeWithCache(_ path: String) async -> ClaudeCLIDetection {
        let mtime = modificationDate(path)
        if let hit = cache[path], hit.mtime == mtime { return hit.result }
        let result = await probe(path)
        cache[path] = (mtime, result)
        return result
    }

    private func probe(_ path: String) async -> ClaudeCLIDetection {
        guard let raw = await versionProbe(path) else {
            return .incompatible(path: path, reason: "無法取得版本（--version 失敗）")
        }
        guard let v = Self.parseVersion(raw) else {
            return .incompatible(path: path, reason: "版本無法解析：\(raw.prefix(40))")
        }
        let min = Self.minimumVersion
        guard (v.0, v.1, v.2) >= (min.major, min.minor, min.patch) else {
            return .incompatible(path: path,
                                 reason: "版本過舊 \(v.0).\(v.1).\(v.2)（需 ≥ \(min.major).\(min.minor).\(min.patch)）")
        }
        return .found(path: path, version: "\(v.0).\(v.1).\(v.2)")
    }

    /// 取輸出中第一個 x.y.z（本機實測輸出：`2.1.216 (Claude Code)`）
    public static func parseVersion(_ s: String) -> (Int, Int, Int)? {
        guard let m = s.firstMatch(of: #/(\d+)\.(\d+)\.(\d+)/#) else { return nil }
        return (Int(m.1)!, Int(m.2)!, Int(m.3)!)
    }

    /// live 工廠：真檔案系統＋LiveProcessRunner 跑 --version（2s 逾時、私有暫存 cwd）。
    public static func live() -> ClaudeCLIDetector {
        ClaudeCLIDetector(
            isExecutableFile: { path in
                let resolved = (path as NSString).resolvingSymlinksInPath
                var isDir: ObjCBool = false
                let fm = FileManager.default
                return fm.fileExists(atPath: resolved, isDirectory: &isDir)
                    && !isDir.boolValue && fm.isExecutableFile(atPath: resolved)
            },
            modificationDate: { path in
                let resolved = (path as NSString).resolvingSymlinksInPath
                return (try? FileManager.default.attributesOfItem(atPath: resolved))?[.modificationDate] as? Date
            },
            versionProbe: { path in
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("saymend-probe-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                return try? await LiveProcessRunner().run(executable: path, arguments: ["--version"],
                                                          stdin: "", workingDirectory: tmp, timeout: 2)
            })
    }
}
