import Darwin
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

/// 一條長駐的 events 連線：背景執行緒逐行讀到 EOF，收到的行存起來給測試看。
final class StreamClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _ended = false

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return _ended }

    init(path: String, request: String) throws {
        fd = try UnixSocket.connect(path: path)
        UnixSocket.writeLine(fd, request)
        let fd = self.fd
        DispatchQueue.global().async { [self] in
            let reader = LineReader(fd: fd)
            while let line = try? reader.next() {
                lock.lock(); _lines.append(line); lock.unlock()
            }
            lock.lock(); _ended = true; lock.unlock()
        }
    }

    /// 像 CLI 結束一樣斷線：shutdown 讓背景的 read 立刻拿到 EOF，app 端也看到 EOF。
    func disconnect() {
        shutdown(fd, SHUT_RDWR)
    }

    deinit { close(fd) }
}

@MainActor
private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func presence(of line: String?) -> JSONLine? {
    line.flatMap { try? JSONLine.parse($0) }?["presence"]?.objectValue
}

/// 真的 socket ＋ 真的 `ControlServer` ＋ 真的 `ControlService`（預設的 main queue 合併排程）：
/// 驗證「連線斷了數量就減」走的是 server 偵測 EOF → `peerClosed` 這條真實路徑，不是測試直接呼叫。
@MainActor
@Suite(.serialized) struct ControlPresenceSocketTests {
    private func withService(_ body: (String, ControlService) async throws -> Void) async throws {
        let dir = NSTemporaryDirectory() + "smp-" + String(UUID().uuidString.prefix(8))
        let path = dir + "/c.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cli = makeCLI()
        let service = ControlService(cli: cli.c, hotkeyActivity: { .idle }, modelReady: { true }, appVersion: "t")
        let server = ControlServer(socketPath: path, handler: service)
        try server.start()
        defer { server.stop() }
        try await body(path, service)
    }

    @Test func disconnectingADeclaringClientIsSeenByTheOthers() async throws {
        try await withService { path, service in
            let watcher = try StreamClient(path: path, request: #"{"v":1,"cmd":"events"}"#)
            #expect(await waitUntil { watcher.lines.count == 1 })
            #expect(watcher.lines.first?.contains(#""presence":{}"#) == true)

            let a = try StreamClient(path: path, request: #"{"v":1,"cmd":"events","presence":"loop"}"#)
            #expect(await waitUntil { a.lines.count == 1 })
            #expect(presence(of: a.lines.first) == JSONLine([("loop", .int(1))]), "第一行就看得到自己")
            #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine([("loop", .int(1))]) })

            let b = try StreamClient(path: path, request: #"{"v":1,"cmd":"events","presence":"loop"}"#)
            #expect(await waitUntil { presence(of: b.lines.first) == JSONLine([("loop", .int(2))]) })
            #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine([("loop", .int(2))]) })
            #expect(await waitUntil { presence(of: a.lines.last) == JSONLine([("loop", .int(2))]) })

            a.disconnect()
            #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine([("loop", .int(1))]) },
                    "斷線後其餘連線收到減少後的數量")
            #expect(await waitUntil { presence(of: b.lines.last) == JSONLine([("loop", .int(1))]) })
            b.disconnect()
            #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine() })
            #expect(service.snapshot().presence == [:])
            #expect(watcher.lines.allSatisfy { $0.contains(#""state":"idle""#) }, "state 沒變也照送")
        }
    }

    @Test func invalidPresenceOnTheWireIsAUsageErrorAndNotCounted() async throws {
        try await withService { path, service in
            let bad = try StreamClient(path: path, request: #"{"v":1,"cmd":"events","presence":"Bad Tag"}"#)
            #expect(await waitUntil { bad.ended })
            #expect(bad.lines.count == 1)
            #expect(bad.lines.first?.contains(#""code":"usage""#) == true)
            #expect(service.subscriberCount == 0)
            #expect(service.snapshot().presence == [:])
        }
    }
}

/// 以真的 `saymend` 行程驗證（預設跳過）：`SAYMEND_CLI_BINARY=<新版 CLI 路徑>`，
/// 可另給 `SAYMEND_OLD_CLI_BINARY=<舊版 CLI 路徑>` 驗證舊版 CLI 的相容行為。
/// 驗的是「CLI 行程被 kill -9／SIGTERM → 連線關閉 → 其他連線看到數量減少」。
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAYMEND_CLI_BINARY"] != nil))
struct ControlPresenceCLIProcessHarness {
    final class CLIProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var buffer = Data()

        init(binary: String, args: [String], socket: String) throws {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            process.environment = ["SAYMEND_CONTROL_SOCKET": socket, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                lock.lock(); buffer.append(d); lock.unlock()
            }
            try process.run()
        }

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
        }

        func signal(_ sig: Int32) { kill(process.processIdentifier, sig) }

        /// 不可用 `waitUntilExit()`：它會卡住 main thread，而 app 端（ControlService）正是在 main 上回覆。
        @MainActor
        func exited(_ timeout: Double = 15) async -> Bool {
            await waitUntil(timeout) { !process.isRunning }
        }
    }

    @Test func killedCLIProcessesStopCounting() async throws {
        let env = ProcessInfo.processInfo.environment
        let cliPath = try #require(env["SAYMEND_CLI_BINARY"])
        let dir = NSTemporaryDirectory() + "smh-" + String(UUID().uuidString.prefix(8))
        let path = dir + "/c.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cli = makeCLI()
        let service = ControlService(cli: cli.c, hotkeyActivity: { .idle }, modelReady: { true }, appVersion: "t")
        let server = ControlServer(socketPath: path, handler: service)
        try server.start()
        defer { server.stop() }

        let watcher = try CLIProcess(binary: cliPath, args: ["events", "--json"], socket: path)
        defer { watcher.signal(SIGKILL) }
        #expect(await waitUntil { watcher.lines.count == 1 })
        let a = try CLIProcess(binary: cliPath, args: ["events", "--json", "--presence", "loop"], socket: path)
        let b = try CLIProcess(binary: cliPath, args: ["events", "--json", "--presence=loop"], socket: path)
        #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine([("loop", .int(2))]) })
        #expect(await waitUntil { presence(of: a.lines.last) == JSONLine([("loop", .int(2))]) })

        a.signal(SIGKILL)
        #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine([("loop", .int(1))]) }, "kill -9 之後少一個")
        b.signal(SIGTERM)
        #expect(await waitUntil { presence(of: watcher.lines.last) == JSONLine() }, "SIGTERM 之後歸零")
        #expect(await a.exited())
        #expect(await b.exited())
        #expect(b.process.terminationStatus == 5, "SIGTERM 照慣例 exit 5")

        let status = try CLIProcess(binary: cliPath, args: ["status", "--json"], socket: path)
        #expect(await status.exited())
        #expect(await waitUntil { status.lines.count == 1 })
        #expect(status.lines.first == #"{"v":1,"app":"running","state":"idle","source":null,"modelReady":true,"presence":{}}"#)

        let bad = try CLIProcess(binary: cliPath, args: ["events", "--json", "--presence", "BAD"], socket: path)
        #expect(await bad.exited())
        #expect(bad.process.terminationStatus == 2)

        print("[presence harness] watcher 收到：\n" + watcher.lines.joined(separator: "\n"))

        // 舊版 CLI（不懂 --presence）：mod 的退回路徑依賴這兩點
        if let old = env["SAYMEND_OLD_CLI_BINARY"] {
            let rejected = try CLIProcess(binary: old, args: ["events", "--json", "--presence", "loop"], socket: path)
            #expect(await rejected.exited())
            #expect(rejected.process.terminationStatus == 2, "舊版 CLI 對 --presence 回 exit 2")
            let plain = try CLIProcess(binary: old, args: ["events", "--json"], socket: path)
            #expect(await waitUntil { plain.lines.count == 1 })
            print("[presence harness] 舊版 CLI 對新版 app 的第一行：\(plain.lines.first ?? "")")
            #expect(plain.lines.first?.hasPrefix(#"{"v":1,"type":"state","state":"idle","source":null,"at":"#) == true,
                    "舊版 CLI 讀新版 app：照常輸出，只是沒有 presence 欄位")
            plain.signal(SIGKILL)
        }
    }
}
