import Foundation

/// 遠端 client 的安裝／移除（docs/remote.md）。位置與行為是 saymend-voice mod 依賴的介面，不能變：
/// `~/.saymend-remote/bin/saymend`、`~/.saymend-remote/bin/say` 兩個 symlink 指向同一支 Python 檔，
/// 遠端的 `~/.saymend-remote/bridge.sock` 由 `ssh -R` 接回 Mac。
public enum RemoteClientInstall {
    public static let remoteDirectory = ".saymend-remote"
    public static let socketName = "bridge.sock"
    public static let clientFileName = "saymend_remote.py"

    /// 遠端的安裝步驟（與參考實作相同）。整段包在 `sh -c '…'` 裡，所以內容不能出現單引號。
    /// client 的內容從 stdin 送進去。
    public static let installScript =
        #"set -e; d="$HOME/.saymend-remote"; mkdir -p "$d/bin"; chmod 700 "$d"; "#
        + #"cat > "$d/saymend_remote.py.new"; mv "$d/saymend_remote.py.new" "$d/saymend_remote.py"; "#
        + #"chmod 700 "$d/saymend_remote.py"; "#
        + #"ln -sf ../saymend_remote.py "$d/bin/saymend"; ln -sf ../saymend_remote.py "$d/bin/say"; "#
        // 上次留下的 socket 檔要先清掉，否則 sshd 沒辦法在同一個路徑重新建立
        + #"if [ -S "$d/bridge.sock" ]; then rm -f "$d/bridge.sock"; fi; "#
        + #"if command -v python3 >/dev/null 2>&1; then echo "SAYMEND_REMOTE_HOME=$HOME"; "#
        + #"else echo "SAYMEND_REMOTE_NOPYTHON"; fi"#

    public static let uninstallScript =
        #"d="$HOME/.saymend-remote"; "#
        + #"rm -f "$d/bin/saymend" "$d/bin/say" "$d/saymend_remote.py" "$d/saymend_remote.py.new" "$d/bridge.sock"; "#
        + #"rmdir "$d/bin" "$d" 2>/dev/null; "#
        + #"if [ -e "$d" ]; then echo "SAYMEND_REMOTE_LEFT=$d"; else echo "SAYMEND_REMOTE_REMOVED"; fi"#

    /// 給 ssh 的遠端指令（一個字串，遠端的 shell 會解析它）
    public static var installCommand: String { "sh -c '\(installScript)'" }
    public static var uninstallCommand: String { "sh -c '\(uninstallScript)'" }

    public static func clientPath(home: String) -> String { "\(home)/\(remoteDirectory)/bin/saymend" }
    public static func speakerPath(home: String) -> String { "\(home)/\(remoteDirectory)/bin/say" }
    public static func remoteSocketPath(home: String) -> String { "\(home)/\(remoteDirectory)/\(socketName)" }

    /// 連上後要貼到遠端 Claude Code 執行的兩行
    public static func setupLines(home: String) -> [String] {
        ["/saymend bin \(clientPath(home: home))", "/saymend speaker \(speakerPath(home: home))"]
    }

    /// 遠端家目錄要能放進 `ssh -R 遠端路徑:本機路徑`：絕對路徑、不含冒號與換行。
    public static func isUsableHome(_ home: String) -> Bool {
        home.hasPrefix("/") && !home.contains(":") && !home.contains(where: { $0.isNewline })
    }

    /// 包成單引號字串（遠端 shell 用）
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public enum InstallOutcome: Equatable, Sendable {
        case installed(home: String)
        case failed(SSHFailure)
    }

    public static func parseInstall(_ result: SSHRunner.Result) -> InstallOutcome {
        if result.stdout.contains("SAYMEND_REMOTE_NOPYTHON") {
            return .failed(SSHFailure(message: "遠端沒有 python3，client 無法執行（需要 Python 3.8 以上）", isFatal: true))
        }
        for line in result.stdout.components(separatedBy: .newlines) where line.hasPrefix("SAYMEND_REMOTE_HOME=") {
            let home = String(line.dropFirst("SAYMEND_REMOTE_HOME=".count)).trimmingCharacters(in: .whitespaces)
            guard isUsableHome(home) else {
                return .failed(SSHFailure(message: "遠端家目錄 \(home) 無法用於轉發（需要是不含冒號的絕對路徑）", isFatal: true))
            }
            return .installed(home: home)
        }
        return .failed(SSHFailure.classify(result, action: "安裝 client"))
    }

    public enum UninstallOutcome: Equatable, Sendable {
        case removed
        /// client 移除了，但資料夾裡還有使用者自己的檔案，資料夾保留
        case leftOtherFiles
        case failed(SSHFailure)

        public var message: String {
            switch self {
            case .removed: return "已移除遠端的 ~/\(RemoteClientInstall.remoteDirectory)"
            case .leftOtherFiles: return "已移除 client；~/\(RemoteClientInstall.remoteDirectory) 裡還有其他檔案，資料夾沒有刪"
            case .failed(let f): return "移除失敗：\(f.message)"
            }
        }
    }

    public static func parseUninstall(_ result: SSHRunner.Result) -> UninstallOutcome {
        if result.stdout.contains("SAYMEND_REMOTE_REMOVED") { return .removed }
        if result.stdout.contains("SAYMEND_REMOTE_LEFT=") { return .leftOtherFiles }
        return .failed(SSHFailure.classify(result, action: "移除 client"))
    }
}

/// ssh 失敗的說明。`isFatal`＝重試也沒用（驗證失敗、主機金鑰沒確認、遠端缺 python3），不再自動重連——
/// 一直用錯的金鑰重試，還可能觸發遠端的 fail2ban。
public struct SSHFailure: Equatable, Sendable {
    public var message: String
    public var isFatal: Bool

    public init(message: String, isFatal: Bool) {
        self.message = message
        self.isFatal = isFatal
    }

    public static func classify(_ result: SSHRunner.Result, action: String) -> SSHFailure {
        if result.timedOut { return SSHFailure(message: "\(action)逾時", isFatal: false) }
        return classify(exitCode: result.exitCode, stderrLine: result.lastErrorLine, action: action)
    }

    public static func classify(exitCode: Int32, stderrLine: String?, action: String) -> SSHFailure {
        let line = stderrLine ?? ""
        if line.contains("Permission denied") || line.contains("Too many authentication failures") {
            return SSHFailure(message: "SSH 驗證失敗（\(line)）。Saymend 不會詢問密碼：請設定金鑰或 ssh-agent，"
                              + "讓終端機的 ssh 不必輸入密碼就能登入", isFatal: true)
        }
        if line.contains("Host key verification failed") {
            return SSHFailure(message: "主機金鑰尚未確認：請先在終端機用 ssh 連一次並接受主機金鑰", isFatal: true)
        }
        if line.contains("remote port forwarding failed") || line.contains("forwarding failed") {
            return SSHFailure(message: "SSH 轉發沒有建立（\(line)）：請確認遠端的 sshd 允許轉發"
                              + "（AllowStreamLocalForwarding）", isFatal: false)
        }
        if !line.isEmpty { return SSHFailure(message: "\(action)失敗：\(line)", isFatal: false) }
        return SSHFailure(message: "\(action)失敗（ssh 結束碼 \(exitCode)）", isFatal: false)
    }
}
