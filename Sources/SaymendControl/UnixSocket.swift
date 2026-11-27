import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable, CustomStringConvertible {
    /// `sun_path` 只有 104 bytes（含結尾 NUL）
    case pathTooLong(String)
    /// 沒有 socket 檔，或檔案在但沒人 listen——app 沒在跑
    case notRunning
    /// 已有另一個活著的 server 在這個路徑上
    case alreadyInUse(String)
    /// 路徑上有東西但不是 socket（不刪別人的檔案）
    case notASocket(String)
    /// 目錄不是本人擁有
    case insecureDirectory(String)
    /// 連線對端不是同一個 uid
    case peerRejected(uid: uid_t)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "socket 路徑過長（上限 103 bytes）：\(p)"
        case .notRunning: return "Saymend.app 未執行"
        case .alreadyInUse(let p): return "已有另一個 Saymend 在使用 \(p)"
        case .notASocket(let p): return "路徑上已有非 socket 的檔案：\(p)"
        case .insecureDirectory(let p): return "socket 所在目錄不屬於目前使用者，或權限比 0700 寬：\(p)"
        case .peerRejected(let uid): return "拒絕不同使用者的連線（uid \(uid)）"
        case .syscall(let name, let err): return "\(name) 失敗：\(String(cString: strerror(err)))（errno \(err)）"
        }
    }
}

/// POSIX unix domain socket 的薄包裝。不做任何協定層的事。
public enum UnixSocket {
    /// 建 `sockaddr_un`。macOS 的 `sun_path` 是 104 bytes，含結尾 NUL。
    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// 寫入 broken pipe 時回 EPIPE，而不是對整個行程送 SIGPIPE（app 不能因為 CLI 被 kill 而跟著死）。
    public static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 對端的有效 uid。取不到回 nil（呼叫端一律當成拒絕）。
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    /// 連到 server。沒檔案、沒人 listen 都回 `.notRunning`。
    /// 連上之後也驗對端 uid：socket 目錄是 0700，正常情況不可能是別人；驗它是縱深防禦。
    public static func connect(path: String, expectedUID: uid_t = getuid()) throws -> Int32 {
        var addr = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.syscall("socket", errno) }
        disableSigPipe(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(fd)
            switch err {
            case ENOENT, ECONNREFUSED, ENOTDIR: throw UnixSocketError.notRunning
            default: throw UnixSocketError.syscall("connect", err)
            }
        }
        guard let uid = peerUID(fd), uid == expectedUID else {
            let uid = peerUID(fd) ?? uid_t.max
            Darwin.close(fd)
            throw UnixSocketError.peerRejected(uid: uid)
        }
        return fd
    }

    /// 讀取逾時（只給一次性請求用；串流指令不設）。
    public static func setReceiveTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 寫完整段資料。EINTR 重試；其他錯誤回 false（對端已關）。
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n > 0 {
                    p += n
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    ok = false
                    return
                }
            }
        }
        return ok
    }

    /// 寫一行（自動補 `\n`）。
    @discardableResult
    public static func writeLine(_ fd: Int32, _ line: String) -> Bool {
        writeAll(fd, Data((line + "\n").utf8))
    }

    /// 建 listen socket。檔案權限 0600、所在目錄 0700；路徑上若是**死掉的** socket（沒人 listen）就清掉重建，
    /// 若有人在 listen 就拒絕（不搶另一個執行中的 Saymend 的 socket）。
    /// - Parameter tightenExistingDirectory: 既有目錄權限比 0700 寬時要不要收緊。只給預設路徑
    ///   （`~/Library/Application Support/Saymend`）用；覆寫路徑（`SAYMEND_CONTROL_SOCKET`）的既有目錄
    ///   可能是任何地方（例如家目錄），不能替使用者改權限——太寬就拒絕啟動。
    public static func listen(path: String, backlog: Int32 = 16, tightenExistingDirectory: Bool = false) throws -> Int32 {
        var addr = try address(for: path)
        try prepareDirectory(for: path, tightenExisting: tightenExistingDirectory)
        try removeStaleSocket(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.syscall("socket", errno) }
        disableSigPipe(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            Darwin.close(fd)
            throw UnixSocketError.syscall("bind", err)
        }
        // bind 建出來的 socket 檔權限受 umask 影響；這裡明確收緊。bind 到 chmod 之間的短暫窗口裡，
        // 外層目錄已是 0700，其他使用者連路徑都走不進來；accept 時還有 getpeereid 第二道。
        guard chmod(path, 0o600) == 0 else {
            let err = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.syscall("chmod", err)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let err = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.syscall("listen", err)
        }
        return fd
    }

    /// 目錄不存在就以 0700 建立；存在就確認是本人擁有，權限比 0700 寬時收緊（`tightenExisting`）或拒絕。
    static func prepareDirectory(for path: String, tightenExisting: Bool = true) throws {
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        if stat(dir, &st) != 0 {
            guard errno == ENOENT else { throw UnixSocketError.syscall("stat", errno) }
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw UnixSocketError.syscall("mkdir", errno == 0 ? EIO : errno)
            }
            guard stat(dir, &st) == 0 else { throw UnixSocketError.syscall("stat", errno) }
        }
        guard st.st_uid == getuid() else { throw UnixSocketError.insecureDirectory(dir) }
        if st.st_mode & 0o077 != 0 {
            guard tightenExisting else { throw UnixSocketError.insecureDirectory(dir) }
            guard chmod(dir, 0o700) == 0 else { throw UnixSocketError.syscall("chmod", errno) }
        }
    }

    /// 只清「是 socket、且沒人在 listen」的檔案。
    static func removeStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }   // 不存在＝沒東西要清
        guard st.st_mode & S_IFMT == S_IFSOCK else { throw UnixSocketError.notASocket(path) }
        do {
            let fd = try connect(path: path)
            Darwin.close(fd)
            throw UnixSocketError.alreadyInUse(path)
        } catch UnixSocketError.notRunning {
            guard unlink(path) == 0 || errno == ENOENT else { throw UnixSocketError.syscall("unlink", errno) }
        }
    }
}

/// 從 fd 逐行讀取（阻塞）。CLI 端用。
public final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private var eof = false

    public init(fd: Int32) { self.fd = fd }

    public enum ReadError: Error, Equatable {
        case timedOut
        case failed(Int32)
    }

    /// 下一行（不含換行）；EOF 回 nil。行尾的 `\r` 一併去掉。
    public func next() throws -> String? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
            if eof {
                guard !buffer.isEmpty else { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                eof = true
            } else {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { throw ReadError.timedOut }
                if err == ECONNRESET { eof = true; continue }   // 對端被 kill：當成 EOF
                throw ReadError.failed(err)
            }
        }
    }
}
