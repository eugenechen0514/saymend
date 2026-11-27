import Darwin
import Foundation
import Testing
@testable import SaymendControl

/// 腳本化的請求處理器：記下收到什麼，回覆由測試決定。
@MainActor
final class ScriptedHandler: ControlRequestHandler {
    var requests: [ControlRequest] = []
    var followUps: [ControlRequest] = []
    var closedCount = 0
    var peers: [any ControlPeer] = []
    /// 收到第一行請求時要回的訊息；nil＝不回（測試自己用 `peers` 回）
    var reply: (ControlRequest) -> [ControlMessage]? = { _ in nil }

    func handle(_ request: ControlRequest, peer: any ControlPeer) {
        requests.append(request)
        peers.append(peer)
        if let messages = reply(request) {
            for m in messages { peer.send(m) }
            if messages.last?.isTerminal == true { peer.close() }
        }
    }

    func handleFollowUp(_ request: ControlRequest, peer: any ControlPeer) {
        followUps.append(request)
    }

    func peerClosed(_ peer: any ControlPeer) {
        closedCount += 1
    }
}

/// 暫存目錄裡的 socket 路徑。`sun_path` 只有 104 bytes，目錄名刻意短。
func makeSocketPath() -> (dir: String, path: String) {
    let dir = NSTemporaryDirectory() + "smc-" + String(UUID().uuidString.prefix(8))
    return (dir, dir + "/c.sock")
}

/// 在背景執行緒做阻塞式 I/O（server 的回呼在 main，測試本身也在 main——不能在 main 上阻塞讀）。
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async { cont.resume(returning: work()) }
    }
}

/// 送一行、讀到 EOF 為止的所有行。
func exchange(path: String, send lines: [String]) async -> [String] {
    await background {
        guard let fd = try? UnixSocket.connect(path: path) else { return ["<connect failed>"] }
        defer { close(fd) }
        UnixSocket.setReceiveTimeout(fd, seconds: 5)
        for l in lines { UnixSocket.writeLine(fd, l) }
        let reader = LineReader(fd: fd)
        var out: [String] = []
        while let line = try? reader.next() { out.append(line) }
        return out
    }
}

@MainActor
func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite(.serialized) struct ControlServerTests {
    @Test func socketIs0600AndItsDirectoryIs0700() throws {
        let (dir, path) = makeSocketPath()
        // 目錄預先以寬鬆權限存在：server 啟動時要把它收緊
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = ControlServer(socketPath: path, tightenExistingDirectory: true, handler: ScriptedHandler())
        try server.start()
        defer { server.stop() }
        var st = stat()
        #expect(lstat(path, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(stat(dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func requestAndReplyRoundTrip() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        handler.reply = { _ in [.status(state: .idle, source: nil, modelReady: true, presence: [:])] }
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()
        defer { server.stop() }

        let lines = await exchange(path: path, send: [ControlRequest.status.encoded()])
        #expect(lines == [#"{"v":1,"type":"status","state":"idle","source":null,"modelReady":true,"presence":{}}"#])
        #expect(handler.requests == [.status])
        #expect(await waitUntil { handler.closedCount == 1 }, "每條連線恰通知一次關閉")
    }

    @Test func connectionsFromAnotherUIDAreDroppedWithoutAByte() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        handler.reply = { _ in [.ok] }
        // 模擬「對端不是允許的 uid」：允許的 uid 設成別人，自己連進去就是陌生人
        let server = ControlServer(socketPath: path, allowedUID: getuid() &+ 1, handler: handler)
        try server.start()
        defer { server.stop() }

        let lines = await background { () -> [String] in
            // client 端也驗對端 uid（縱深防禦）——這裡要繞過它，直接看 server 的行為
            guard let fd = try? UnixSocket.connect(path: path) else { return ["<connect failed>"] }
            defer { close(fd) }
            UnixSocket.setReceiveTimeout(fd, seconds: 2)
            UnixSocket.writeLine(fd, ControlRequest.status.encoded())
            let reader = LineReader(fd: fd)
            var out: [String] = []
            while let line = try? reader.next() { out.append(line) }
            return out
        }
        #expect(lines.isEmpty, "不同 uid 的連線一個位元組都不回")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(handler.requests.isEmpty, "也不得交給處理器")
    }

    @Test func malformedAndWrongVersionRequestsGetAnErrorAndNeverReachTheHandler() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()
        defer { server.stop() }

        let wrongVersion = await exchange(path: path, send: [#"{"v":99,"cmd":"status"}"#])
        #expect(wrongVersion.count == 1)
        #expect(wrongVersion.first?.contains(#""code":"unsupported_version""#) == true)
        let garbage = await exchange(path: path, send: ["hello"])
        #expect(garbage.first?.contains(#""code":"usage""#) == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(handler.requests.isEmpty)
    }

    @Test func followUpLinesAndDisconnectReachTheHandlerInOrder() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()
        defer { server.stop() }

        _ = await background {
            guard let fd = try? UnixSocket.connect(path: path) else { return }
            UnixSocket.writeLine(fd, ControlRequest.dictate(DictateOptions()).encoded())
            UnixSocket.writeLine(fd, ControlRequest.cancel.encoded())
            usleep(100_000)
            close(fd)                       // 像 CLI 被 kill：直接斷線
        }
        #expect(await waitUntil { handler.closedCount == 1 })
        #expect(handler.requests == [.dictate(DictateOptions())])
        #expect(handler.followUps == [.cancel])
    }

    @Test func staleSocketIsReplacedButALiveOneIsNot() throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 死掉的 socket：bind 過但沒人 listen（模擬 app 當掉留下的檔）
        try UnixSocket.prepareDirectory(for: path)
        var addr = try UnixSocket.address(for: path)
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(dead)

        let first = ControlServer(socketPath: path, handler: ScriptedHandler())
        try first.start()
        defer { first.stop() }
        let second = ControlServer(socketPath: path, handler: ScriptedHandler())
        #expect(throws: UnixSocketError.alreadyInUse(path)) { try second.start() }
    }

    @Test func refusesToDeleteSomethingThatIsNotASocket() throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))
        let server = ControlServer(socketPath: path, handler: ScriptedHandler())
        #expect(throws: UnixSocketError.notASocket(path)) { try server.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep me".utf8))
    }

    @Test func stopRemovesTheSocketAndEndsOpenStreams() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        handler.reply = { _ in [.state(state: .idle, source: nil, presence: [:], at: Date())] }   // 非終局：連線保持開著
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()

        async let lines = exchange(path: path, send: [ControlRequest.events(presence: nil).encoded()])
        #expect(await waitUntil { handler.requests.count == 1 })
        server.stop()
        let received = await lines
        #expect(received.count == 1, "串流在 server 停止時以 EOF 結束")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: UnixSocketError.notRunning) { try UnixSocket.connect(path: path) }
    }

    /// `SAYMEND_CONTROL_SOCKET` 覆寫的路徑：既有目錄可能是任何地方（例如家目錄），不得替使用者改權限
    @Test func overridePathNeverChmodsAnExistingLooseDirectory() throws {
        let (dir, path) = makeSocketPath()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = ControlServer(socketPath: path, handler: ScriptedHandler())   // 非預設路徑：預設不收緊
        #expect(throws: UnixSocketError.insecureDirectory(dir)) { try server.start() }
        var st = stat()
        #expect(stat(dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o755, "權限原封不動")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// `stop()` 剛好落在 accept 與 `start()` 之間：連線已被關閉才要建 read source——fd 要關掉、不得空轉
    @Test func connectionClosedBeforeStartStillClosesItsDescriptor() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[1]) }
        let handler = ScriptedHandler()
        var removed = 0
        let conn = ControlConnection(fd: fds[0], handler: handler) { _ in removed += 1 }
        conn.close()
        conn.start()
        #expect(await waitUntil { handler.closedCount == 1 && removed == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fcntl(fds[0], F_GETFD) == -1, "fd 已關閉")
        // 對端看到 EOF
        var byte: UInt8 = 0
        #expect(read(fds[1], &byte, 1) == 0)
    }

    @Test func pathsLongerThanSunPathAreRejected() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: UnixSocketError.pathTooLong(long)) { try UnixSocket.connect(path: long) }
    }
}
