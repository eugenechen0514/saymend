import Darwin
import Foundation
import SaymendControl

/// 一台遠端主機的橋接（docs/remote.md）：在 Mac 上 listen 一個 unix socket，由 `ssh -R` 把遠端的
/// `~/.saymend-remote/bridge.sock` 接過來。每條連線讀一個請求（白名單見 `RemoteBridgeProtocol`）：
///
/// - `saymend …`：在 app 內執行同一份 `CLIRunner`（和 `saymend` CLI 是同一份程式碼，輸出與結束碼一致），
///   它經 `connectInProcess(origin:)` 接到控制介面——連線標著主機名稱，HUD 與歷史因此分得出遠端來源。
/// - `say`：執行 `/usr/bin/say`，文字走 stdin。
///
/// client 中途斷線＝取消：`CLIRunner` 收到 interrupt（dictate 會請 app 丟棄這一段並關麥克風），`say` 被結束。
/// **紀錄只有指令名稱、字數與結束碼**，不含聽寫或朗讀的內容。
public final class RemoteBridgeServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var socketPath: String
        /// 主機名稱：HUD、歷史、紀錄都用它標出來源
        public var origin: String
        public var appVersion: String
        public var sayPath: String
        /// 讀第一行請求的時限
        public var requestTimeout: Double
        /// client 斷線後等 app 確認取消聽寫的上限（同 CLI 收到 SIGINT）
        public var interruptGrace: Double
        /// 同時進行的請求上限。每條連線佔一個 fd 與執行緒；遠端失控（或被 prompt injection 的程式）
        /// 一直開連線時，不能把整個 app 的 fd 用光（GUI app 的預設上限只有 256）。
        public var maxSessions: Int

        public init(socketPath: String, origin: String, appVersion: String, sayPath: String = "/usr/bin/say",
                    requestTimeout: Double = 10, interruptGrace: Double = CLIRunner.defaultInterruptGrace,
                    maxSessions: Int = 16) {
            self.socketPath = socketPath
            self.origin = origin
            self.appVersion = appVersion
            self.sayPath = sayPath
            self.requestTimeout = requestTimeout
            self.interruptGrace = interruptGrace
            self.maxSessions = maxSessions
        }
    }

    public let configuration: Configuration
    private let connectControl: (String) throws -> Int32
    private let log: @Sendable (String) -> Void
    private let acceptQueue = DispatchQueue(label: "io.saymend.remote.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketInode: ino_t?
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: BridgeSession] = [:]
    private var stopped = false

    /// - Parameters:
    ///   - connectControl: 依主機名稱開一條 app 內的控制連線（`ControlServer.connectInProcess(origin:)`）
    ///   - log: 每個請求一行摘要（不含內容）
    public init(configuration: Configuration, connectControl: @escaping (String) throws -> Int32,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.connectControl = connectControl
        self.log = log
    }

    /// socket 0600、所在資料夾 0700（`UnixSocket.listen`）。路徑上若是死掉的 socket 就清掉重建。
    public func start() throws {
        let fd = try UnixSocket.listen(path: configuration.socketPath, tightenExistingDirectory: true)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var st = stat()
        if lstat(configuration.socketPath, &st) == 0 { socketInode = st.st_ino }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
    }

    /// 停止 listen、刪掉 socket 檔、斷開所有進行中的請求（進行中的聽寫因此被取消）。
    public func stop() {
        lock.lock()
        stopped = true
        let active = Array(sessions.values)
        lock.unlock()
        acceptSource?.cancel()
        acceptSource = nil
        if let ino = socketInode {
            var st = stat()
            if lstat(configuration.socketPath, &st) == 0, st.st_ino == ino { unlink(configuration.socketPath) }
            socketInode = nil
        }
        for s in active { s.disconnect() }
    }

    /// 進行中的請求數（測試用）
    public var activeSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    private func acceptPending() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            guard cfd >= 0 else { return }
            let flags = fcntl(cfd, F_GETFL)
            _ = fcntl(cfd, F_SETFL, flags & ~O_NONBLOCK)
            UnixSocket.disableSigPipe(cfd)
            // `ssh -R` 在 Mac 這一側以使用者本人的身分連進來；其他 uid 一律拒絕
            guard let uid = UnixSocket.peerUID(cfd), uid == getuid() else {
                log("拒絕不同使用者的連線")
                Darwin.close(cfd)
                continue
            }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let session = BridgeSession(fd: cfd, configuration: configuration, connectControl: connectControl, log: log)
            lock.lock()
            if stopped {
                lock.unlock()
                Darwin.close(cfd)
                continue
            }
            if sessions.count >= configuration.maxSessions {
                lock.unlock()
                log("拒絕：同時進行的請求已達上限（\(configuration.maxSessions)）")
                Darwin.close(cfd)
                continue
            }
            sessions[ObjectIdentifier(session)] = session
            lock.unlock()
            let thread = Thread { [weak self] in
                session.run()
                self?.remove(session)
            }
            thread.name = "io.saymend.remote.session"
            thread.start()
        }
    }

    private func remove(_ session: BridgeSession) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }
}

/// 一條橋接連線：讀請求 → 執行 → 回覆，client 離開就取消。`run()` 在自己的執行緒上阻塞到結束。
final class BridgeSession: @unchecked Sendable {
    private let fd: Int32
    private let configuration: RemoteBridgeServer.Configuration
    private let connectControl: (String) throws -> Int32
    private let log: @Sendable (String) -> Void

    /// 狀態旗標的鎖。**不在寫入 socket 時持有**：對端不讀時寫入最多卡 5 秒（SO_SNDTIMEO），
    /// 那段期間 `disconnect()`（main thread 上關開關、app 結束）仍要能立刻 shutdown。
    private let lock = NSLock()
    /// 序列化寫入；`finish()` 也要拿到它才關 fd，確保沒有寫入正在用這個 fd。
    private let writeLock = NSLock()
    private var clientGone = false
    private var finished = false
    private var fdClosed = false
    /// client 離開時要做的事（interrupt CLIRunner／結束 say）。在鎖內設定與取出。
    private var onClientGone: (() -> Void)?
    private let watcherDone = DispatchSemaphore(value: 0)

    init(fd: Int32, configuration: RemoteBridgeServer.Configuration,
         connectControl: @escaping (String) throws -> Int32, log: @escaping @Sendable (String) -> Void) {
        self.fd = fd
        self.configuration = configuration
        self.connectControl = connectControl
        self.log = log
    }

    /// 由 server 呼叫（關掉開關、app 結束）：等同 client 離開。
    func disconnect() {
        lock.lock()
        if !fdClosed { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func run() {
        defer { finish() }
        guard let line = readRequestLine() else { return }
        let request: RemoteBridgeRequest
        switch RemoteBridgeRequest.parse(line) {
        case .failure(let rejection):
            log("拒絕：\(rejection.reason)")
            send(.err("saymend-remote: \(rejection.reason)\n"))
            send(.exit(2))
            return
        case .success(let r):
            request = r
        }
        startWatcher()
        let outcome: String
        switch request {
        case .saymend(let args): outcome = runSaymend(args)
        case .say(let text, let voice): outcome = runSay(text: text, voice: voice)
        }
        log("\(request.logSummary) → \(outcome)")
    }

    // MARK: - 請求

    /// 讀第一行。時限內沒送完、太長、或對方先關了，都回 nil（不回覆，直接關）。
    private func readRequestLine() -> Data? {
        UnixSocket.setReceiveTimeout(fd, seconds: configuration.requestTimeout)
        defer { UnixSocket.setReceiveTimeout(fd, seconds: 0) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                return pending[pending.startIndex..<nl]
            }
            if pending.count > RemoteBridgeProtocol.maxRequestBytes { return nil }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.append(contentsOf: chunk[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    // MARK: - saymend

    /// 在 app 內執行 `CLIRunner`。它的 stdout／stderr 每行轉成一個 frame，結束碼放在最後一行。
    private func runSaymend(_ args: [String]) -> String {
        let control = ControlLink()
        let origin = configuration.origin
        let connect = connectControl
        let output = CLIRunner.Output(out: { [weak self] line in self?.send(.out(line + "\n")) },
                                      err: { [weak self] line in self?.send(.err(line + "\n")) })
        let runner = CLIRunner(
            socketPath: "",
            output: output,
            cliVersion: configuration.appVersion,
            connect: { _ in
                let fd = try connect(origin)
                guard control.adopt(fd) else {
                    Darwin.close(fd)
                    throw UnixSocketError.notRunning
                }
                return fd
            },
            // CLI 的 terminate＝結束行程；在 app 內則是切斷這條控制連線，讓阻塞中的 run 讀到 EOF 返回
            terminate: { _ in control.cut() },
            interruptGrace: configuration.interruptGrace)
        setOnClientGone { runner.interrupt() }
        let code = runner.run(args)
        control.release()
        if isClientGone { return "client 離開，已取消" }
        send(.exit(code))
        return "exit \(code)"
    }

    // MARK: - say

    private func runSay(text: String, voice: String?) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.sayPath)
        process.arguments = voice.map { ["-v", $0] } ?? []
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            send(.err("saymend-remote: 無法執行 \(configuration.sayPath)：\(error.localizedDescription)\n"))
            send(.exit(1))
            return "無法執行 say"
        }
        setOnClientGone {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // 文字走 stdin（開頭是「-」的文字才不會被當成 `say` 的選項）；另開執行緒寫，免得卡住讀輸出。
        // say 先結束（被取消、語音不存在）時寫入要回 EPIPE，不能對整個 app 送 SIGPIPE
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let data = Data(text.utf8)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }
        let group = DispatchGroup()
        for (pipe, isErr) in [(stdout, false), (stderr, true)] {
            group.enter()
            DispatchQueue.global().async { [weak self] in
                var decoder = UTF8Chunker()
                let handle = pipe.fileHandleForReading
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    let text = decoder.feed(chunk)
                    if !text.isEmpty { self?.send(isErr ? .err(text) : .out(text)) }
                }
                let rest = decoder.flush()
                if !rest.isEmpty { self?.send(isErr ? .err(rest) : .out(rest)) }
                group.leave()
            }
        }
        exited.wait()
        group.wait()
        if isClientGone { return "client 離開，已結束 say" }
        // 被 signal 結束的行程照 shell 慣例回報 128+N
        let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        send(.exit(code))
        return "exit \(code)"
    }

    // MARK: - 共用

    private var isClientGone: Bool {
        lock.lock(); defer { lock.unlock() }
        return clientGone
    }

    private func setOnClientGone(_ action: @escaping () -> Void) {
        lock.lock()
        let already = clientGone
        onClientGone = action
        lock.unlock()
        if already { action() }
    }

    /// client 離開（讀到 EOF、寫入失敗、或被 server 斷開）。只觸發一次。
    private func markClientGone() {
        lock.lock()
        guard !clientGone, !finished else { lock.unlock(); return }
        clientGone = true
        let action = onClientGone
        lock.unlock()
        action?()
    }

    private func send(_ frame: RemoteBridgeFrame) {
        writeLock.lock()
        lock.lock()
        let skip = clientGone || fdClosed
        lock.unlock()
        let ok = skip || UnixSocket.writeLine(fd, frame.encoded())
        writeLock.unlock()
        if !ok { markClientGone() }
    }

    /// 監看 client 是否離開。請求之後 client 不會再送東西，讀到 EOF（含 ssh 斷線、client 被 kill）就是離開。
    private func startWatcher() {
        let fd = self.fd
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n > 0 { continue }                   // 多送的東西不理
                if n < 0 && errno == EINTR { continue }
                break
            }
            self?.markClientGone()
            self?.watcherDone.signal()
        }
        thread.name = "io.saymend.remote.watch"
        lock.lock()
        watcherStarted = true
        lock.unlock()
        thread.start()
    }

    private var watcherStarted = false

    /// 收尾：先標記結束（之後 watcher 讀到 EOF 不算 client 離開），切斷 socket 讓 watcher 返回，再關 fd。
    private func finish() {
        lock.lock()
        finished = true
        let waitForWatcher = watcherStarted
        shutdown(fd, SHUT_RDWR)
        lock.unlock()
        if waitForWatcher { watcherDone.wait() }
        writeLock.lock()                  // 等進行中的寫入（例如 CLIRunner 的逾時訊息）寫完
        lock.lock()
        fdClosed = true                   // 之後 disconnect() 不會再對這個 fd 號碼做 shutdown
        lock.unlock()
        Darwin.close(fd)
        writeLock.unlock()
    }
}

/// app 內控制連線的持有者：`CLIRunner` 自己會關它拿到的 fd，所以這裡留一份 dup。
/// `cut()` 對 dup 做 shutdown（作用在底層 socket，原 fd 上阻塞的讀取也會返回），不會碰到已被關閉、
/// 可能已被別人重用的 fd 號碼。
final class ControlLink: @unchecked Sendable {
    private let lock = NSLock()
    private var dupFD: Int32 = -1
    private var isCut = false

    /// 記下剛建立的控制連線。已經被切斷（client 在連上之前就離開）回 false。
    func adopt(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isCut else { return false }
        dupFD = dup(fd)
        return dupFD >= 0                 // dup 失敗（fd 用光）就沒辦法中斷它：當成連不上
    }

    func cut() {
        lock.lock(); defer { lock.unlock() }
        isCut = true
        if dupFD >= 0 { shutdown(dupFD, SHUT_RDWR) }
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        if dupFD >= 0 { Darwin.close(dupFD) }
        dupFD = -1
    }
}

/// 把位元組串逐段解成 UTF-8；跨段被切開的字元留到下一段（解不了的位元組換成 U+FFFD）。
struct UTF8Chunker {
    private var pending = Data()

    mutating func feed(_ data: Data) -> String {
        pending.append(data)
        // 從尾端往回找：最後一個字元若還沒收完整，留著
        var cut = pending.count
        var back = 0
        var i = pending.count - 1
        while i >= 0 && back < 4 {
            let b = pending[pending.startIndex + i]
            if b & 0b1100_0000 != 0b1000_0000 {           // 起始位元組
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                if back + 1 < need { cut = i }
                break
            }
            back += 1
            i -= 1
        }
        let head = pending.prefix(cut)
        pending = Data(pending.suffix(from: pending.startIndex + cut))
        return String(decoding: head, as: UTF8.self)
    }

    mutating func flush() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}
