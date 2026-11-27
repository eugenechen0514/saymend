import Darwin
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

/// 用假的 ssh（Fixtures/Remote/fake_ssh.py）走完整條路：裝 client → `ssh -N -R` 轉發 → 遠端 client 經橋接
/// 問 status。「遠端」是本機的假家目錄，轉發由假 ssh 在本機建 unix socket 模擬——不連任何真的主機。
@MainActor
final class LinkHarness {
    let dir: String
    let home: String
    let socketDir: String
    let sshLog: String
    let control: ControlServer
    let service: ControlService
    let cli: CLIHarness
    let settings: AppSettings
    let manager: RemoteBridgeManager
    let delays = LockedLines()

    init(fail: String? = nil, remotePath: String? = nil) throws {
        dir = RemoteTestPaths.makeDir("srl")
        home = dir + "/home"
        socketDir = dir + "/sock"
        sshLog = dir + "/ssh.log"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        cli = makeCLI()
        service = ControlService(cli: cli.c, hotkeyActivity: { .idle }, modelReady: { true }, appVersion: "9.9.9")
        control = ControlServer(socketPath: dir + "/c.sock", handler: service)
        try control.start()
        var env = ["PATH": RemoteTestPaths.searchPath, "FAKE_SSH_LOG": sshLog, "FAKE_REMOTE_HOME": home,
                   "FAKE_REMOTE_PATH": remotePath ?? RemoteTestPaths.searchPath]
        if let fail { env["FAKE_SSH_FAIL"] = fail }
        settings = AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID().uuidString)")!,
                               secrets: InMemorySecretStore())
        let delays = self.delays
        manager = RemoteBridgeManager(
            settings: settings, socketDirectory: URL(fileURLWithPath: socketDir),
            clientScriptURL: RemoteTestPaths.client, appVersion: "9.9.9",
            runner: SSHRunner(sshPath: RemoteTestPaths.fakeSSH.path, environment: env),
            sleep: { seconds in
                delays.append(String(seconds))
                try await Task.sleep(for: .milliseconds(min(seconds, 0.2) * 1000))
            })
        let control = self.control
        let cliController = cli.c
        manager.attach(connectControl: { try control.connectInProcess(origin: $0) },
                       cancelDictation: { origin in
                           if cliController.activeOrigin == origin { cliController.cancel(source: "test") }
                       })
    }

    func shutdown() {
        manager.shutdown()
        control.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    var sshInvocations: [[String]] {
        guard let text = try? String(contentsOfFile: sshLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        }
    }

    var remoteSocket: String { home + "/.saymend-remote/bridge.sock" }

    func addHost(_ host: RemoteHost = RemoteHost(id: "h1", kind: .sshConfig, host: "devbox")) -> RemoteLink {
        #expect(manager.add(host) == nil)
        return manager.links.last!
    }
}

@MainActor
@Suite(.serialized, .enabled(if: RemoteTestPaths.pythonAvailable)) struct RemoteLinkTests {
    @Test func connectInstallsTheClientForwardsAndChecksTheWholePath() async throws {
        let h = try LinkHarness()
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(link.isOn)
        #expect(await remoteWaitUntil(20) { link.state == .connected }, "\(link.lastError ?? "")")
        #expect(link.remoteHome == h.home)
        #expect(link.lastResult == "Saymend：idle", "遠端 → 轉發 → 橋接 → 控制介面整條路走過")
        #expect(link.lastError == nil)
        #expect(link.setupLines == ["/saymend bin \(h.home)/.saymend-remote/bin/saymend",
                                    "/saymend speaker \(h.home)/.saymend-remote/bin/say"])

        // 遠端裝好的東西：client 與兩個 symlink
        let base = h.home + "/.saymend-remote"
        #expect(FileManager.default.contents(atPath: base + "/saymend_remote.py")
                == FileManager.default.contents(atPath: RemoteTestPaths.client.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: base + "/bin/saymend") == "../saymend_remote.py")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: base + "/bin/say") == "../saymend_remote.py")

        // 每一次 ssh 都是 BatchMode，目的地前面有 --
        let calls = h.sshInvocations
        #expect(calls.count >= 3)
        for argv in calls {
            #expect(argv.starts(with: ["-o", "BatchMode=yes"]), "\(argv)")
            #expect(argv.contains("ControlMaster=no"), "不自己變成背景 master")
            let dash = try #require(argv.firstIndex(of: "--"))
            #expect(argv[dash + 1] == "devbox")
        }
        let tunnel = try #require(calls.first { $0.contains("-N") })
        let localSocket = h.socketDir + "/h1.sock"
        #expect(tunnel.contains("\(h.home)/.saymend-remote/bridge.sock:\(localSocket)"))
        #expect(tunnel.contains("ExitOnForwardFailure=yes"))
        #expect(tunnel.contains("ControlPath=none"), "轉發用自己的連線，不掛在共用的 master 上")
        #expect(FileManager.default.fileExists(atPath: h.socketDir + "/h1.ssh.pid"), "記下轉發的 ssh，當掉後下次啟動收得掉")

        link.disconnect()
        #expect(link.state == .disconnected)
        #expect(!link.isOn)
        #expect(await remoteWaitUntil { !FileManager.default.fileExists(atPath: h.remoteSocket) }, "轉發的 ssh 已結束")
        #expect(!FileManager.default.fileExists(atPath: localSocket), "本機的橋接 socket 收掉了")
        #expect(!FileManager.default.fileExists(atPath: h.socketDir + "/h1.ssh.pid"))
        #expect(link.setupLines == nil)
    }

    /// 遠端進行中的聽寫：關掉開關＝取消、麥克風關閉
    @Test func disconnectingCancelsARemoteDictation() async throws {
        let h = try LinkHarness()
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(await remoteWaitUntil(20) { link.state == .connected })
        let client = try ChildProcess(h.home + "/.saymend-remote/bin/saymend", ["dictate", "--json"],
                                      env: ["HOME": h.home, "PATH": RemoteTestPaths.searchPath])
        #expect(await remoteWaitUntil { h.cli.c.phase == .recording })
        #expect(h.cli.c.activeOrigin == "devbox")
        link.disconnect()
        #expect(await remoteWaitUntil { h.cli.c.phase == .idle })
        #expect(h.cli.audio.stopCount == 1)
        #expect(await client.exited())
        #expect(client.process.terminationStatus == 3, "client 看到連線中斷：照契約 exit 3")
    }

    /// 轉發的 ssh 死掉（網路斷）：自動重連，遠端上次留下的 socket 由安裝步驟清掉
    @Test func reconnectsAfterTheTunnelDies() async throws {
        let h = try LinkHarness()
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(await remoteWaitUntil(20) { link.state == .connected })
        let pidText = try String(contentsOfFile: h.socketDir + "/h1.ssh.pid", encoding: .utf8)
        let pid = try #require(pid_t(pidText.split(separator: " ")[0]))
        kill(pid, SIGKILL)                                  // 不留機會清掉遠端的 socket
        #expect(await remoteWaitUntil(10) { link.state != .connected })
        #expect(await remoteWaitUntil(20) { link.state == .connected && h.sshInvocations.filter { $0.contains("-N") }.count == 2 })
        #expect(h.delays.lines.first == "2.0", "重連前先等 2 秒（測試裡縮短）")
        link.disconnect()
    }

    /// 驗證失敗：重試沒用（還可能觸發 fail2ban），停在未連線並顯示原因
    @Test func authenticationFailureIsShownAndNotRetried() async throws {
        let h = try LinkHarness(fail: "alice@devbox: Permission denied (publickey).")
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(await remoteWaitUntil { !link.isOn })
        #expect(link.state == .disconnected)
        #expect(link.lastError?.contains("Permission denied") == true)
        #expect(link.lastError?.contains("不會詢問密碼") == true)
        #expect(h.sshInvocations.count == 1, "不重試")
        #expect(!FileManager.default.fileExists(atPath: h.socketDir + "/h1.sock"))
    }

    @Test func transientFailuresBackOffAndKeepRetrying() async throws {
        let h = try LinkHarness(fail: "ssh: connect to host devbox port 22: Connection refused")
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(await remoteWaitUntil(10) { h.delays.lines.count >= 3 })
        #expect(Array(h.delays.lines.prefix(3)) == ["2.0", "4.0", "8.0"])
        #expect(link.isOn)
        #expect(link.state == .reconnecting)
        #expect(link.lastError?.contains("Connection refused") == true)
        link.disconnect()
        #expect(link.state == .disconnected)
    }

    @Test func missingPythonOnTheRemoteIsFatal() async throws {
        // 遠端的 PATH 只有安裝步驟要用的工具，沒有 python3
        let bin = RemoteTestPaths.makeDir("srp")
        defer { try? FileManager.default.removeItem(atPath: bin) }
        for tool in ["sh", "mkdir", "chmod", "cat", "mv", "ln", "rm"] {
            let path = ["/bin/\(tool)", "/usr/bin/\(tool)"].first { FileManager.default.isExecutableFile(atPath: $0) }!
            try FileManager.default.createSymbolicLink(atPath: "\(bin)/\(tool)", withDestinationPath: path)
        }
        let h = try LinkHarness(remotePath: bin)
        defer { h.shutdown() }
        let link = h.addHost()
        link.connect()
        #expect(await remoteWaitUntil(10) { !link.isOn })
        #expect(link.lastError?.contains("python3") == true)
    }

    /// 測試鈕（沒連線時）：臨時裝 client、建轉發、問一次 status，問完收掉
    @Test func testButtonProbesTheWholePathAndCleansUp() async throws {
        let h = try LinkHarness()
        defer { h.shutdown() }
        let link = h.addHost()
        await link.test()
        #expect(link.lastResult == "Saymend：idle", "\(link.lastError ?? "")")
        #expect(link.state == .disconnected)
        #expect(!link.isOn)
        #expect(await remoteWaitUntil { !FileManager.default.fileExists(atPath: h.remoteSocket) }, "臨時的轉發收掉了")
        #expect(!FileManager.default.fileExists(atPath: h.socketDir + "/h1.sock"))

        // 移除遠端的 client
        await link.uninstallClient()
        #expect(link.lastResult == "已移除遠端的 ~/.saymend-remote")
        #expect(!FileManager.default.fileExists(atPath: h.home + "/.saymend-remote"))
    }

    /// 「測試」臨時建的轉發：app 結束時也要收掉
    @Test func quittingDuringATestStopsItsProbeTunnel() async throws {
        let h = try LinkHarness()
        defer { h.shutdown() }
        let link = h.addHost()
        let pidFile = h.socketDir + "/h1.ssh.pid"
        let testing = Task { await link.test() }
        #expect(await remoteWaitUntil(20) {
            FileManager.default.fileExists(atPath: h.remoteSocket) && FileManager.default.fileExists(atPath: pidFile)
        }, "臨時轉發建起來了，也記了 pid（當掉後下次啟動收得掉）")
        let pidText = try String(contentsOfFile: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText.split(separator: " ")[0]))
        h.manager.shutdown()
        // 同步檢查、不讓出 main actor：app 結束時沒有機會等 test() 自己的流程收尾
        #expect(!FileManager.default.fileExists(atPath: pidFile), "shutdown 當下就結束了臨時轉發")
        #expect(await remoteWaitUntil(10) { kill(pid, 0) != 0 }, "臨時轉發的 ssh 結束了")
        await testing.value
    }

    @Test func manualHostPassesPortAndUser() async throws {
        let h = try LinkHarness(fail: "ssh: connect to host 10.0.0.5 port 2222: Connection refused")
        defer { h.shutdown() }
        let link = h.addHost(RemoteHost(id: "m1", kind: .manual, host: "10.0.0.5", port: 2222, user: "eve"))
        link.connect()
        #expect(await remoteWaitUntil { !h.sshInvocations.isEmpty })
        link.disconnect()
        let argv = try #require(h.sshInvocations.first)
        let p = try #require(argv.firstIndex(of: "-p"))
        #expect(Array(argv[p..<min(p + 6, argv.count)]) == ["-p", "2222", "-l", "eve", "--", "10.0.0.5"])
    }
}

@MainActor
@Suite(.serialized) struct RemoteBridgeManagerTests {
    private func makeManager(sshPath: String = "/usr/bin/false") -> (RemoteBridgeManager, AppSettings, String) {
        let dir = RemoteTestPaths.makeDir("srm")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID().uuidString)")!,
                                   secrets: InMemorySecretStore())
        let m = RemoteBridgeManager(settings: settings, socketDirectory: URL(fileURLWithPath: dir),
                                    clientScriptURL: RemoteTestPaths.client, appVersion: "t",
                                    runner: SSHRunner(sshPath: sshPath))
        return (m, settings, dir)
    }

    @Test func hostsArePersistedAndDeduplicated() {
        let (m, settings, dir) = makeManager()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(m.add(RemoteHost(kind: .sshConfig, host: "devbox")) == nil)
        #expect(m.add(RemoteHost(kind: .sshConfig, host: "devbox")) != nil, "同名的不重複加")
        #expect(m.add(RemoteHost(kind: .manual, host: "-x")) != nil)
        #expect(settings.remoteHosts.map(\.host) == ["devbox"])
        let id = m.links[0].id
        m.setAutoConnect(id: id, true)
        #expect(settings.remoteHosts.first?.autoConnect == true)
        // 重新開 app：清單從設定讀回來
        let reopened = RemoteBridgeManager(settings: settings, socketDirectory: URL(fileURLWithPath: dir),
                                           clientScriptURL: nil, appVersion: "t")
        #expect(reopened.links.map(\.host) == settings.remoteHosts)
        m.remove(id: id)
        #expect(settings.remoteHosts.isEmpty)
    }

    @Test func connectWithoutTheControlInterfaceExplainsWhy() {
        let (m, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        m.add(RemoteHost(kind: .sshConfig, host: "devbox"))
        #expect(!m.isControlAvailable)
        m.links[0].connect()
        #expect(!m.links[0].isOn)
        #expect(m.links[0].lastError?.contains("控制介面沒有啟動") == true)
    }

    /// app 當掉留下的轉發 ssh：下次啟動依 pid 檔收掉；pid 被別的行程重用（啟動時間對不上）就不動
    @Test func orphanedTunnelsFromACrashAreCleanedUp() async throws {
        let (m, _, dir) = makeManager(sshPath: "/bin/sleep")   // 用 sleep 扮演 ssh
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/bin/sleep")
        orphan.arguments = ["30"]
        try orphan.run()
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        try bystander.run()
        defer { bystander.terminate() }
        let started = try #require(RemoteBridgeManager.processStartTime(orphan.processIdentifier))
        try "\(orphan.processIdentifier) \(started)\n".write(toFile: dir + "/a.ssh.pid", atomically: true, encoding: .utf8)
        try "\(bystander.processIdentifier) 12345\n".write(toFile: dir + "/b.ssh.pid", atomically: true, encoding: .utf8)
        m.cleanupOrphanedTunnels()
        #expect(await remoteWaitUntil { !orphan.isRunning })
        // Process 要等回收子行程才更新 isRunning：給它時間，被誤殺的話這裡才看得出來
        try await Task.sleep(for: .milliseconds(500))
        #expect(bystander.isRunning, "啟動時間對不上：不是我們的 ssh，不動")
        #expect(!FileManager.default.fileExists(atPath: dir + "/a.ssh.pid"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/b.ssh.pid"))
    }

    @Test(.enabled(if: RemoteTestPaths.pythonAvailable)) func sshConfigEntriesShowResolvedSubtitles() async throws {
        let dir = RemoteTestPaths.makeDir("src")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "Host devbox staging\nHost *.internal\n".write(toFile: dir + "/config", atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID().uuidString)")!,
                                   secrets: InMemorySecretStore())
        let m = RemoteBridgeManager(settings: settings, socketDirectory: URL(fileURLWithPath: dir),
                                    clientScriptURL: nil, appVersion: "t",
                                    runner: SSHRunner(sshPath: RemoteTestPaths.fakeSSH.path,
                                                      environment: ["PATH": RemoteTestPaths.searchPath]))
        let entries = await m.sshConfigEntries(sshDirectory: dir)
        #expect(entries.map(\.alias) == ["devbox", "staging"])
        #expect(entries.first?.subtitle == "alice@devbox.example.com:2222")
    }
}
