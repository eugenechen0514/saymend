import Darwin
import Foundation
import OSLog

/// 一條控制連線的對外操作（app 端的請求處理器看到的就是它）。
/// `send`／`close` 可從任何執行緒呼叫，實際 I/O 在連線自己的序列佇列上依序執行——
/// 所以「送出終局訊息後關閉」只要依序呼叫兩者，終局訊息保證先寫完。
public protocol ControlPeer: AnyObject {
    func send(_ message: ControlMessage)
    func close()
}

/// app 端的請求處理器。三個方法都在 main thread 上呼叫。
@MainActor
public protocol ControlRequestHandler: AnyObject {
    /// 連線的第一行請求
    func handle(_ request: ControlRequest, peer: any ControlPeer)
    /// 同一條連線之後送來的請求。協定只定義一種：`dictate` 連線上的 `cancel`（取消這一段，CLI 收到 SIGINT 時送）。
    func handleFollowUp(_ request: ControlRequest, peer: any ControlPeer)
    /// 連線已關——對端斷線或 app 端主動關都算。每條連線恰呼叫一次，且在它的所有請求回呼之後。
    func peerClosed(_ peer: any ControlPeer)
}

/// unix domain socket 的 server：accept、驗對端 uid、逐行切分、解碼請求、交給處理器。
///
/// **安全邊界**：這個介面能遠端開麥克風。三道防線：
/// ① socket 檔 0600；② 所在目錄 0700（且必須是本人擁有，否則拒絕啟動）；
/// ③ 每條連線 accept 後立刻 `getpeereid`，uid 不同就直接關掉，不回任何一個位元組。
public final class ControlServer {
    public let socketPath: String
    private let allowedUID: uid_t
    private let handler: any ControlRequestHandler
    private let acceptQueue = DispatchQueue(label: "io.saymend.control.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// bind 時的 inode：關閉時只刪自己建的那個檔（避免刪到之後另一個實例建的）
    private var socketInode: ino_t?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ControlConnection] = [:]
    static let log = Logger(subsystem: "io.saymend.app", category: "control")

    public init(socketPath: String, allowedUID: uid_t = getuid(), handler: any ControlRequestHandler) {
        self.socketPath = socketPath
        self.allowedUID = allowedUID
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(path: socketPath)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)   // accept 不能在假喚醒時卡住佇列
        var st = stat()
        if lstat(socketPath, &st) == 0 { socketInode = st.st_ino }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
        Self.log.notice("控制介面已啟動：\(self.socketPath, privacy: .public)")
    }

    /// 停止 listen、刪掉 socket 檔、關閉所有連線（串流中的 `events` client 會收到 EOF）。
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if let ino = socketInode {
            var st = stat()
            if lstat(socketPath, &st) == 0, st.st_ino == ino { unlink(socketPath) }
            socketInode = nil
        }
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.close() }
    }

    /// 目前連線數（測試用）
    public var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    private func acceptPending() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            guard cfd >= 0 else { return }   // EAGAIN＝這一輪收完了
            // BSD 的 accept 會繼承 listen socket 的 O_NONBLOCK；連線端要阻塞式寫入，清掉它。
            let flags = fcntl(cfd, F_GETFL)
            _ = fcntl(cfd, F_SETFL, flags & ~O_NONBLOCK)
            UnixSocket.disableSigPipe(cfd)
            guard let uid = UnixSocket.peerUID(cfd), uid == allowedUID else {
                Self.log.error("拒絕不同使用者的控制連線（uid \(UnixSocket.peerUID(cfd).map(String.init) ?? "?", privacy: .public)）")
                Darwin.close(cfd)
                continue
            }
            // 對端不讀（卡住）時寫入最多等 5 秒，之後當斷線處理——不讓一個壞 client 永久卡住它的 I/O 佇列。
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let conn = ControlConnection(fd: cfd, handler: handler) { [weak self] c in self?.remove(c) }
            lock.lock()
            connections[ObjectIdentifier(conn)] = conn
            lock.unlock()
            conn.start()
        }
    }

    private func remove(_ c: ControlConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(c))
        lock.unlock()
    }
}

/// 一條連線。所有狀態只在自己的 I/O 佇列上改。
final class ControlConnection: ControlPeer {
    /// 一行的上限。協定裡最長的是 dictate 請求（不到 200 bytes）；超過就是壞掉的 client。
    static let maxLineBytes = 64 * 1024

    private let fd: Int32
    private let handler: any ControlRequestHandler
    private let onRemoved: (ControlConnection) -> Void
    private let io = DispatchQueue(label: "io.saymend.control.connection")
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    private var receivedFirst = false

    init(fd: Int32, handler: any ControlRequestHandler, onRemoved: @escaping (ControlConnection) -> Void) {
        self.fd = fd
        self.handler = handler
        self.onRemoved = onRemoved
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let fd = self.fd
        source.setCancelHandler { Darwin.close(fd) }   // fd 只在這裡關：cancel 之後 dispatch 不會再碰它
        readSource = source
        source.resume()
    }

    func send(_ message: ControlMessage) {
        let line = message.encoded()
        io.async {
            guard !self.closed else { return }
            if !UnixSocket.writeLine(self.fd, line) { self.teardown() }
        }
    }

    func close() {
        io.async { self.teardown() }
    }

    private func readAvailable() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                dispatchLine(line)
                if closed { return }
            }
            if buffer.count > Self.maxLineBytes { teardown() }
        } else if n == 0 {
            teardown()                                   // 對端關閉（含 CLI 被 kill）
        } else if errno != EINTR && errno != EAGAIN {
            teardown()
        }
    }

    private func dispatchLine(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let isFirst = !receivedFirst
        receivedFirst = true
        let request: ControlRequest
        do {
            request = try ControlRequest.decode(line)
        } catch let ControlRequest.DecodeError.unsupportedVersion(v) {
            rejectAndClose(.error(code: .unsupportedVersion,
                                  message: "不支援的協定版本 \(v.map(String.init) ?? "（未提供）")，本 app 為 v\(ControlProtocol.version)"))
            return
        } catch let ControlRequest.DecodeError.malformed(why) {
            rejectAndClose(.error(code: .usage, message: "請求格式錯誤：\(why)"))
            return
        } catch {
            rejectAndClose(.error(code: .usage, message: "請求格式錯誤"))
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isFirst {
                    self.handler.handle(request, peer: self)
                } else {
                    self.handler.handleFollowUp(request, peer: self)
                }
            }
        }
    }

    private func rejectAndClose(_ message: ControlMessage) {
        _ = UnixSocket.writeLine(fd, message.encoded())
        teardown()
    }

    /// 只在 I/O 佇列上呼叫。冪等。
    private func teardown() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        // 排在本連線所有請求回呼之後（同樣經 main queue，FIFO）：處理器看到的順序一定是「請求 → 關閉」。
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handler.peerClosed(self) }
            self.onRemoved(self)
        }
    }
}
