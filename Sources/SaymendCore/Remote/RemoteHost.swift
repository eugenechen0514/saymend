import Foundation

/// 設定頁「遠端」的一台主機。**不存密碼、不存金鑰**：連線一律交給系統的 ssh，
/// 用使用者自己的 ~/.ssh/config、agent 與金鑰。
public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// ~/.ssh/config 的 Host 別名：連線參數全由 ssh 自己解析（含 Include、Match）
        case sshConfig
        /// 手動填的主機／port／使用者
        case manual
    }

    /// 短而唯一：也拿來當本機 socket 的檔名（`sun_path` 只有 104 bytes）
    public var id: String
    public var kind: Kind
    /// sshConfig：別名；manual：主機名稱或 IP
    public var host: String
    public var port: Int?
    public var user: String?
    /// app 啟動時自動連線
    public var autoConnect: Bool

    public init(id: String = RemoteHost.makeID(), kind: Kind, host: String, port: Int? = nil, user: String? = nil,
                autoConnect: Bool = false) {
        self.id = id
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.autoConnect = autoConnect
    }

    public static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// 清單、HUD、歷史都用這個名字。sshConfig 是別名；manual 是 `user@host:port`（沒填的部分省略）。
    public var displayName: String {
        switch kind {
        case .sshConfig:
            return host
        case .manual:
            var s = host
            if let user, !user.isEmpty { s = "\(user)@\(s)" }
            if let port { s += ":\(port)" }
            return s
        }
    }

    /// 組 ssh 的參數：共同選項＋呼叫端的選項＋目的地＋遠端指令。
    /// - `BatchMode=yes`：不會卡在密碼提示，驗證失敗直接結束。
    /// - `ControlMaster=no`：可以沿用使用者既有的連線共用（ControlMaster），但絕不自己變成 master——
    ///   設了 `ControlPersist` 時，背景 master 會一直開著我們的 stdout／stderr，也不受我們管理。
    /// - 目的地前面放 `--`：主機名稱不可能被當成 ssh 的選項。
    public func sshArguments(options: [String] = [], command: [String] = []) -> [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlMaster=no"] + options
        if kind == .manual {
            if let port { args += ["-p", String(port)] }
            if let user, !user.isEmpty { args += ["-l", user] }
        }
        return args + ["--", host] + command
    }

    /// 新增前的檢查；不接受就回傳原因。
    public static func validate(kind: Kind, host: String, port: Int?, user: String?) -> String? {
        guard !host.isEmpty else { return kind == .sshConfig ? "請選一台主機" : "請填主機名稱" }
        guard host.count <= 255 else { return "主機名稱太長" }
        guard !host.hasPrefix("-") else { return "主機名稱不能以 - 開頭" }
        guard host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                                               && !CharacterSet.controlCharacters.contains($0) }) else {
            return "主機名稱不能有空白"
        }
        if kind == .manual, host.contains("@") { return "使用者請填在「使用者」欄" }
        if let port, !(1...65535).contains(port) { return "port 必須介於 1 與 65535 之間" }
        if let user, !user.isEmpty {
            guard !user.hasPrefix("-"), !user.contains("@"),
                  user.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                                                   && !CharacterSet.controlCharacters.contains($0) }) else {
                return "使用者名稱不合法"
            }
        }
        return nil
    }
}

/// ~/.ssh/config 裡的一台主機，給「新增主機」的下拉選單用。
public struct SSHConfigEntry: Equatable, Identifiable, Sendable {
    public var alias: String
    /// `ssh -G <別名>` 解析出來的實際連線參數（取不到就是 nil）
    public var hostname: String?
    public var user: String?
    public var port: Int?

    public var id: String { alias }

    public init(alias: String, hostname: String? = nil, user: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
    }

    /// 副標：`user@hostname:port`
    public var subtitle: String? {
        guard let hostname else { return nil }
        var s = hostname
        if let user { s = "\(user)@\(s)" }
        if let port { s += ":\(port)" }
        return s
    }
}

/// 讀 ~/.ssh/config 的 Host 別名。萬用字元（`*`、`?`）與否定（`!`）的 Host 不列；`Include` 會展開
/// （相對路徑以 ~/.ssh 為準、可含萬用字元）。實際連線參數交給 `ssh -G` 解析，才會正確處理 Include 與 Match。
public enum SSHConfigReader {
    /// 讀檔用的介面：路徑 → 內容；檔案不存在回 nil。`glob` 展開 Include 的萬用字元。
    public struct FileSystem: Sendable {
        public var read: @Sendable (String) -> String?
        public var glob: @Sendable (String) -> [String]

        public init(read: @escaping @Sendable (String) -> String?, glob: @escaping @Sendable (String) -> [String]) {
            self.read = read
            self.glob = glob
        }

        public static let local = FileSystem(
            read: { try? String(contentsOfFile: $0, encoding: .utf8) },
            glob: { pattern in
                var g = glob_t()
                defer { globfree(&g) }
                guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
                return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }.sorted()
            })
    }

    /// 依出現順序列出別名（去重）。
    public static func aliases(sshDirectory: String, fileSystem: FileSystem = .local) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var visited = Set<String>()
        collect(path: (sshDirectory as NSString).appendingPathComponent("config"), sshDirectory: sshDirectory,
                fileSystem: fileSystem, depth: 0, visited: &visited) { alias in
            if seen.insert(alias).inserted { result.append(alias) }
        }
        return result
    }

    private static func collect(path: String, sshDirectory: String, fileSystem: FileSystem, depth: Int,
                                visited: inout Set<String>, emit: (String) -> Void) {
        // ssh 自己的 Include 深度上限是 16
        guard depth <= 16, visited.insert(path).inserted, let text = fileSystem.read(path) else { return }
        for rawLine in text.components(separatedBy: .newlines) {
            let tokens = tokenize(rawLine)
            guard let keyword = tokens.first?.lowercased() else { continue }
            let args = tokens.dropFirst()
            switch keyword {
            case "host":
                for pattern in args where isPlainAlias(pattern) { emit(pattern) }
            case "include":
                for item in args {
                    var expanded = (item as NSString).expandingTildeInPath
                    if !expanded.hasPrefix("/") { expanded = (sshDirectory as NSString).appendingPathComponent(expanded) }
                    let paths = expanded.contains(where: { "*?[".contains($0) }) ? fileSystem.glob(expanded) : [expanded]
                    for p in paths {
                        collect(path: p, sshDirectory: sshDirectory, fileSystem: fileSystem, depth: depth + 1,
                                visited: &visited, emit: emit)
                    }
                }
            default:
                continue
            }
        }
    }

    /// 只有具體的名字才算別名：萬用字元與否定樣式不列。
    static func isPlainAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) }) && !pattern.hasPrefix("-")
    }

    /// 一行 → 關鍵字與參數。`#` 開頭是註解；關鍵字與參數可用空白或 `=` 分隔；參數可用雙引號包住。
    static func tokenize(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return [] }
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in trimmed {
            if ch == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if !inQuotes && (ch == " " || ch == "\t"
                                    // `Host=foo`、`Host = foo`：關鍵字後的第一個 `=` 是分隔符號
                                    || (ch == "=" && (tokens.isEmpty || (tokens.count == 1 && !hasToken)))) {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else if !inQuotes && ch == "#" && !hasToken {
                break                                   // 參數之間的行內註解
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// 解析 `ssh -G <別名>` 的輸出（每行 `關鍵字 值`，關鍵字小寫）。
    public static func parseResolved(alias: String, output: String) -> SSHConfigEntry {
        var entry = SSHConfigEntry(alias: alias)
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": entry.hostname = parts[1]
            case "user": entry.user = parts[1]
            case "port": entry.port = Int(parts[1])
            default: continue
            }
        }
        return entry
    }
}
