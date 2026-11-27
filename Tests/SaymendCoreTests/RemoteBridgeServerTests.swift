import Darwin
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

// MARK: - 共用的測試工具

@MainActor
func remoteWaitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// 執行緒安全的紀錄收集
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func append(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
}

/// 解開橋接回覆的 frame
enum DecodedFrame: Equatable {
    case out(String), err(String), exit(Int)

    static func decode(_ lines: [String]) -> [DecodedFrame] {
        lines.compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            if let s = obj["out"] as? String { return .out(s) }
            if let s = obj["err"] as? String { return .err(s) }
            if let n = obj["exit"] as? Int { return .exit(n) }
            return nil
        }
    }
}

/// 子行程（不阻塞 main：app 端的 ControlService 在 main 上回覆）
final class ChildProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    init(_ executable: String, _ args: [String], env: [String: String], stdin: String? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        let o = Pipe(), e = Pipe()
        process.standardOutput = o
        process.standardError = e
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock(); self.out.append(d); self.lock.unlock()
        }
        e.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock(); self.err.append(d); self.lock.unlock()
        }
        let i = Pipe()
        process.standardInput = i
        try process.run()
        if let stdin { try? i.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try? i.fileHandleForWriting.close()
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    var stdoutLines: [String] { stdout.split(separator: "\n").map(String.init) }

    @MainActor
    func exited(_ timeout: Double = 15) async -> Bool {
        let ok = await remoteWaitUntil(timeout) { !process.isRunning }
        try? await Task.sleep(for: .milliseconds(50))     // 讓 readabilityHandler 收完最後一段
        return ok
    }

    func signal(_ sig: Int32) { kill(process.processIdentifier, sig) }
}

enum RemoteTestPaths {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let client = repoRoot.appendingPathComponent("Resources/remote/saymend_remote.py")
    static let fakeSSH = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Remote/fake_ssh.py")
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    /// python3 在不在（遠端 client 與假 ssh 都是 Python）
    static let pythonAvailable: Bool = searchPath.split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/python3")
    }

    /// 短路徑的暫存目錄（`sun_path` 只有 104 bytes）
    static func makeDir(_ prefix: String) -> String {
        let dir = "/tmp/\(prefix)-" + String(UUID().uuidString.prefix(8)).lowercased()
        // 0700：控制介面的 socket 也放這裡，覆寫路徑的資料夾比 0700 寬會被拒絕（安全邊界）
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// 真的 ControlServer＋ControlService（CLI 聽寫用假的麥克風與辨識器）＋真的橋接 socket
@MainActor
final class BridgeHarness {
    let dir: String
    let bridgeSocket: String
    let control: ControlServer
    let service: ControlService
    let cli: CLIHarness
    let bridge: RemoteBridgeServer
    let logs = LockedLines()

    init(origin: String = "devbox", sayScript: String? = nil, interruptGrace: Double = 2, maxSessions: Int = 16) throws {
        dir = RemoteTestPaths.makeDir("srb")
        bridgeSocket = dir + "/remote/h.sock"
        cli = makeCLI()
        let service = ControlService(cli: cli.c, hotkeyActivity: { .idle }, modelReady: { true }, appVersion: "9.9.9")
        self.service = service
        control = ControlServer(socketPath: dir + "/c.sock", handler: service)
        try control.start()
        var sayPath = "/usr/bin/false"
        if let sayScript {
            sayPath = dir + "/fake-say"
            try sayScript.write(toFile: sayPath, atomically: true, encoding: .utf8)
            chmod(sayPath, 0o755)
        }
        let logs = self.logs
        let control = self.control
        bridge = RemoteBridgeServer(
            configuration: .init(socketPath: bridgeSocket, origin: origin, appVersion: "9.9.9", sayPath: sayPath,
                                 interruptGrace: interruptGrace, maxSessions: maxSessions),
            connectControl: { try control.connectInProcess(origin: $0) },
            log: { logs.append($0) })
        try bridge.start()
    }

    func shutdown() {
        bridge.stop()
        control.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// 送一個請求，回傳持續讀回覆的 client
    func send(_ request: String) throws -> StreamClient {
        try StreamClient(path: bridgeSocket, request: request)
    }

    /// 讓進行中的 CLI 聽寫正常定稿
    func finishDictation(_ text: String) {
        cli.c.receive(.finalized(text), session: 1)
        cli.c.stop()
        cli.c.streamEnded(session: 1)
    }
}

// MARK: - 橋接本體（raw socket）

@MainActor
@Suite(.serialized) struct RemoteBridgeServerTests {
    @Test func socketIs0600AndItsDirectory0700() throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        var st = stat()
        #expect(lstat(h.bridgeSocket, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(stat((h.bridgeSocket as NSString).deletingLastPathComponent, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    /// 輸出與結束碼和 `saymend status --json` 一模一樣（app 內跑的就是同一份 CLIRunner）
    @Test func statusRunsTheCLIContractInProcess() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["status","--json"]}"#)
        #expect(await remoteWaitUntil { c.ended })
        #expect(DecodedFrame.decode(c.lines) == [
            .out(#"{"v":1,"app":"running","state":"idle","source":null,"modelReady":true,"presence":{}}"# + "\n"),
            .exit(0),
        ])
        #expect(h.logs.lines == ["saymend status → exit 0"])
    }

    @Test func versionReportsTheAppVersionAsTheCLIVersion() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["--version","--json"]}"#)
        #expect(await remoteWaitUntil { c.ended })
        #expect(DecodedFrame.decode(c.lines) == [.out(#"{"v":1,"cli":"9.9.9","app":"9.9.9","protocol":1}"# + "\n"), .exit(0)])
    }

    /// 遠端發起的聽寫：HUD 與歷史標出主機名稱，和本機 CLI 分得開
    @Test func dictationFromARemoteHostIsLabelledWithTheHost() async throws {
        let h = try BridgeHarness(origin: "devbox")
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["dictate","--json","--silence-ms","1500"]}"#)
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        #expect(h.cli.c.activeOrigin == "devbox")
        #expect(h.cli.hud.states.last == .cliListening(volatile: "", loadingModel: false, origin: "devbox"))
        h.finishDictation("你好")
        #expect(await remoteWaitUntil { c.ended })
        let frames = DecodedFrame.decode(c.lines)
        #expect(frames.first == .out(#"{"v":1,"type":"started"}"# + "\n"))
        #expect(frames.contains(.out(#"{"v":1,"type":"final","text":"〈你好〉","raw":"你好","durationMs":0}"# + "\n")))
        #expect(frames.last == .exit(0))
        #expect(h.cli.history.sessions.first?.appName == "遠端 devbox（saymend）")
        #expect(h.cli.history.sessions.first?.targetKind == "cli")
    }

    /// client 中途斷線＝取消：聽寫丟棄、麥克風關閉
    @Test func clientDisconnectCancelsTheDictationAndClosesTheMic() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["dictate","--json"]}"#)
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        c.disconnect()
        #expect(await remoteWaitUntil { h.cli.c.phase == .idle })
        #expect(h.cli.audio.stopCount == 1)
        #expect(h.cli.asr.cancelCount == 1)
        #expect(await remoteWaitUntil { h.logs.lines == ["saymend dictate → client 離開，已取消"] })
        #expect(await remoteWaitUntil { h.bridge.activeSessionCount == 0 })
    }

    /// 關掉開關（橋接 stop）：進行中的遠端聽寫一樣取消
    @Test func stoppingTheBridgeCancelsInFlightDictation() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["dictate","--json"]}"#)
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        h.bridge.stop()
        #expect(await remoteWaitUntil { h.cli.c.phase == .idle })
        #expect(h.cli.audio.stopCount == 1)
        #expect(await remoteWaitUntil { c.ended })
        #expect(!FileManager.default.fileExists(atPath: h.bridgeSocket))
    }

    @Test func requestsOutsideTheWhitelistNeverReachTheApp() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        for request in [#"{"v":1,"cmd":"saymend","args":["dictate","--output","/tmp/x"]}"#,
                        #"{"v":1,"cmd":"shell","args":["ls"]}"#,
                        #"{"v":2,"cmd":"saymend","args":["status"]}"#] {
            let c = try h.send(request)
            #expect(await remoteWaitUntil { c.ended })
            let frames = DecodedFrame.decode(c.lines)
            #expect(frames.count == 2)
            guard case .err(let message)? = frames.first else { Issue.record("\(frames)"); continue }
            #expect(message.hasPrefix("saymend-remote: "))
            #expect(frames.last == .exit(2))
        }
        #expect(h.control.connectionCount == 0, "沒有建立任何控制連線")
        #expect(h.cli.audio.startCount == 0)
    }

    /// 遠端的 `events --presence loop` 也算進 presence；斷線就減
    @Test func presenceFromARemoteHostIsCountedWhileConnected() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"saymend","args":["events","--json","--presence","loop"]}"#)
        #expect(await remoteWaitUntil { c.lines.count == 1 })
        #expect(c.lines.first?.contains(#"\"presence\":{\"loop\":1}"#) == true)
        #expect(h.service.snapshot().presence == ["loop": 1])
        c.disconnect()
        #expect(await remoteWaitUntil { h.service.snapshot().presence == [:] })
    }

    @Test func sayTextGoesThroughStdinAndTheVoiceThroughArguments() async throws {
        let dir = RemoteTestPaths.makeDir("srs")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let h = try BridgeHarness(sayScript: """
            #!/bin/sh
            echo "$@" > "\(dir)/say.args"
            cat > "\(dir)/say.text"
            """)
        defer { h.shutdown() }
        let text = "-f 開頭像選項的文字\\n第二行"
        let c = try h.send(#"{"v":1,"cmd":"say","voice":"Meijia","text":"\#(text)"}"#)
        #expect(await remoteWaitUntil { c.ended })
        #expect(DecodedFrame.decode(c.lines) == [.exit(0)])
        #expect(try String(contentsOfFile: dir + "/say.args", encoding: .utf8) == "-v Meijia\n")
        #expect(try String(contentsOfFile: dir + "/say.text", encoding: .utf8) == "-f 開頭像選項的文字\n第二行")
        #expect(h.logs.lines == ["say（15 字） → exit 0"], "紀錄只有字數，不含朗讀內容")
    }

    @Test func clientDisconnectStopsSay() async throws {
        let dir = RemoteTestPaths.makeDir("srs")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let h = try BridgeHarness(sayScript: """
            #!/bin/sh
            trap 'echo term > "\(dir)/say.term"; exit 143' TERM
            cat > /dev/null
            echo started > "\(dir)/say.started"
            while :; do sleep 0.1; done
            """)
        defer { h.shutdown() }
        let c = try h.send(#"{"v":1,"cmd":"say","text":"很長的一段話"}"#)
        #expect(await remoteWaitUntil { FileManager.default.fileExists(atPath: dir + "/say.started") })
        c.disconnect()
        #expect(await remoteWaitUntil { FileManager.default.fileExists(atPath: dir + "/say.term") }, "say 要被結束")
        #expect(await remoteWaitUntil { h.logs.lines == ["say（6 字） → client 離開，已結束 say"] })
    }

    /// 遠端一直開連線也不能把 app 的 fd 用光：超過上限的連線直接關掉
    @Test func concurrentRequestsAreCapped() async throws {
        let h = try BridgeHarness(maxSessions: 2)
        defer { h.shutdown() }
        let fds = try (0..<2).map { _ in try UnixSocket.connect(path: h.bridgeSocket) }   // 不送請求：佔著
        defer { fds.forEach { close($0) } }
        #expect(await remoteWaitUntil { h.bridge.activeSessionCount == 2 })
        let third = try h.send(#"{"v":1,"cmd":"saymend","args":["status","--json"]}"#)
        #expect(await remoteWaitUntil { third.ended })
        #expect(third.lines.isEmpty, "超過上限：不處理、直接關")
        #expect(h.logs.lines.contains { $0.contains("上限") })
    }

    /// 對端不讀、寫入卡住時，關開關（main thread 上的 stop）不能被卡住的寫入擋住
    @Test func stopIsNotBlockedByAStalledWrite() async throws {
        let h = try BridgeHarness(sayScript: "#!/bin/sh\ncat > /dev/null\nyes 0123456789 | head -c 20000000\n")
        defer { h.shutdown() }
        let fd = try UnixSocket.connect(path: h.bridgeSocket)       // 送了請求就不再讀
        defer { close(fd) }
        UnixSocket.writeLine(fd, #"{"v":1,"cmd":"say","text":"x"}"#)
        try await Task.sleep(for: .milliseconds(800))               // 讓 socket 緩衝填滿、寫入卡住
        let started = Date()
        h.bridge.stop()
        #expect(Date().timeIntervalSince(started) < 1, "stop 花了 \(Date().timeIntervalSince(started)) 秒")
        #expect(await remoteWaitUntil(8) { h.bridge.activeSessionCount == 0 })
    }

    @Test func logsNeverContainDictatedOrSpokenText() async throws {
        let h = try BridgeHarness(sayScript: "#!/bin/sh\ncat > /dev/null\n")
        defer { h.shutdown() }
        let d = try h.send(#"{"v":1,"cmd":"saymend","args":["dictate","--json"]}"#)
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        h.finishDictation("秘密的聽寫內容")
        #expect(await remoteWaitUntil { d.ended })
        let s = try h.send(#"{"v":1,"cmd":"say","text":"秘密的朗讀內容"}"#)
        #expect(await remoteWaitUntil { s.ended })
        #expect(await remoteWaitUntil { h.logs.lines.count == 2 })
        #expect(!h.logs.lines.joined().contains("秘密"))
    }
}

// MARK: - 真的 Python client ⇄ 橋接（不經 SSH）

@MainActor
@Suite(.serialized, .enabled(if: RemoteTestPaths.pythonAvailable)) struct RemoteClientEndToEndTests {
    /// 和遠端一樣透過 bin/saymend、bin/say 兩個 symlink 執行 client
    private func installClient(in dir: String) throws -> String {
        let bin = dir + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["saymend", "say"] {
            try FileManager.default.createSymbolicLink(atPath: bin + "/" + name, withDestinationPath: RemoteTestPaths.client.path)
        }
        return bin
    }

    private func env(socket: String) -> [String: String] {
        ["SAYMEND_REMOTE_SOCKET": socket, "PATH": RemoteTestPaths.searchPath, "HOME": NSTemporaryDirectory()]
    }

    @Test func clientGetsTheSameOutputAndExitCodeAsTheCLI() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let bin = try installClient(in: h.dir)
        let status = try ChildProcess(bin + "/saymend", ["status", "--json"], env: env(socket: h.bridgeSocket))
        #expect(await status.exited())
        #expect(status.process.terminationStatus == 0)
        #expect(status.stdoutLines == [#"{"v":1,"app":"running","state":"idle","source":null,"modelReady":true,"presence":{}}"#])

        let dictate = try ChildProcess(bin + "/saymend", ["dictate", "--json"], env: env(socket: h.bridgeSocket))
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        h.finishDictation("今天天氣很好")
        #expect(await dictate.exited())
        #expect(dictate.process.terminationStatus == 0)
        #expect(dictate.stdoutLines.first == #"{"v":1,"type":"started"}"#)
        #expect(dictate.stdoutLines.last == #"{"v":1,"type":"final","text":"〈今天天氣很好〉","raw":"今天天氣很好","durationMs":0}"#)

        let stop = try ChildProcess(bin + "/saymend", ["stop"], env: env(socket: h.bridgeSocket))
        #expect(await stop.exited())
        #expect(stop.process.terminationStatus == 4, "沒有可停的聽寫：照 CLI 契約 exit 4")
        #expect(stop.stderr.contains("saymend: "))
    }

    @Test func killingTheClientCancelsTheDictation() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let bin = try installClient(in: h.dir)
        let dictate = try ChildProcess(bin + "/saymend", ["dictate", "--json"], env: env(socket: h.bridgeSocket))
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        dictate.signal(SIGTERM)
        #expect(await remoteWaitUntil { h.cli.c.phase == .idle }, "client 被結束，Mac 上的聽寫要取消")
        #expect(h.cli.audio.stopCount == 1)
    }

    @Test func whitelistRejectionReachesTheClientAsExit2() async throws {
        let h = try BridgeHarness()
        defer { h.shutdown() }
        let bin = try installClient(in: h.dir)
        let bad = try ChildProcess(bin + "/saymend", ["dictate", "--output", "/tmp/x"], env: env(socket: h.bridgeSocket))
        #expect(await bad.exited())
        #expect(bad.process.terminationStatus == 2)
        #expect(bad.stderr.contains("不接受的參數"))
    }

    @Test func sayFromTheClient() async throws {
        let dir = RemoteTestPaths.makeDir("srs")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let h = try BridgeHarness(sayScript: """
            #!/bin/sh
            echo "$@" > "\(dir)/say.args"
            cat > "\(dir)/say.text"
            """)
        defer { h.shutdown() }
        let bin = try installClient(in: h.dir)
        let say = try ChildProcess(bin + "/say", ["-v", "Meijia"], env: env(socket: h.bridgeSocket), stdin: "測試一下")
        #expect(await say.exited())
        #expect(say.process.terminationStatus == 0)
        #expect(try String(contentsOfFile: dir + "/say.args", encoding: .utf8) == "-v Meijia\n")
        #expect(try String(contentsOfFile: dir + "/say.text", encoding: .utf8) == "測試一下")
    }

    /// 連不上 Mac：exit 3、status 帶 message、其他帶 code unreachable（mod 依賴這個形狀）
    @Test func unreachableBridgeIsReportedPerTheContract() async throws {
        let dir = RemoteTestPaths.makeDir("sru")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bin = try installClient(in: dir)
        let nowhere = dir + "/nowhere.sock"
        let status = try ChildProcess(bin + "/saymend", ["status", "--json"], env: env(socket: nowhere))
        #expect(await status.exited())
        #expect(status.process.terminationStatus == 3)
        let line = try #require(status.stdoutLines.first)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["app"] as? String == "not_running")
        #expect((obj["message"] as? String)?.hasPrefix("連不上 Mac") == true)

        let dictate = try ChildProcess(bin + "/saymend", ["dictate", "--json"], env: env(socket: nowhere))
        #expect(await dictate.exited())
        #expect(dictate.process.terminationStatus == 3)
        #expect(dictate.stdout.contains(#""code": "unreachable""#))

        let say = try ChildProcess(bin + "/say", [], env: env(socket: nowhere), stdin: "測試")
        #expect(await say.exited())
        #expect(say.process.terminationStatus == 1)
        #expect(say.stderr.contains("連不上 Mac"))
    }
}
