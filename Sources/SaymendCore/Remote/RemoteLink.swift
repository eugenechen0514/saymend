import Foundation
import Observation

/// 一台遠端主機的連線：裝 client → `ssh -N -R` 把遠端的 bridge.sock 接回本機的橋接 socket →
/// 從遠端經橋接問一次 status 確認整條路是通的；ssh 斷了就退避重連（2 秒起、最多 30 秒）。
/// 驗證失敗、主機金鑰沒確認、遠端缺 python3 這類重試也沒用的錯誤，停在「未連線」並顯示原因。
@MainActor
@Observable
public final class RemoteLink: Identifiable {
    public enum State: Equatable, Sendable {
        case disconnected, connecting, connected, reconnecting

        public var label: String {
            switch self {
            case .disconnected: return "未連線"
            case .connecting: return "連線中"
            case .connected: return "已連上"
            case .reconnecting: return "重連中"
            }
        }
    }

    /// 由 `RemoteBridgeManager` 提供的外部依賴（測試可換掉）
    public struct Environment {
        public var runner: SSHRunner
        /// 要裝到遠端的 client 檔內容
        public var clientScript: () throws -> Data
        /// 建立並啟動這台主機的橋接（listen 本機 socket）
        public var makeBridge: (RemoteHost) throws -> RemoteBridgeServer
        /// 取消這台主機發起、還在進行的聽寫（參數是主機名稱）
        public var cancelDictation: (String) -> Void
        public var tunnelStarted: (RemoteHost, SSHProcess) -> Void
        public var tunnelEnded: (RemoteHost) -> Void
        public var sleep: (Double) async throws -> Void
        public var checkAttempts: Int
        public var checkInterval: Double

        public init(runner: SSHRunner, clientScript: @escaping () throws -> Data,
                    makeBridge: @escaping (RemoteHost) throws -> RemoteBridgeServer,
                    cancelDictation: @escaping (String) -> Void = { _ in },
                    tunnelStarted: @escaping (RemoteHost, SSHProcess) -> Void = { _, _ in },
                    tunnelEnded: @escaping (RemoteHost) -> Void = { _ in },
                    sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                    checkAttempts: Int = 5, checkInterval: Double = 1) {
            self.runner = runner
            self.clientScript = clientScript
            self.makeBridge = makeBridge
            self.cancelDictation = cancelDictation
            self.tunnelStarted = tunnelStarted
            self.tunnelEnded = tunnelEnded
            self.sleep = sleep
            self.checkAttempts = checkAttempts
            self.checkInterval = checkInterval
        }
    }

    public nonisolated let id: String
    public internal(set) var host: RemoteHost
    public private(set) var state: State = .disconnected
    /// 連線開關：使用者要它連著（重連中也算）。重試也沒用的錯誤會把它關掉。
    public private(set) var isOn = false
    public private(set) var lastError: String?
    /// 最近一次檢查／測試／移除的結果
    public private(set) var lastResult: String?
    /// 遠端實際的家目錄（裝 client 時回報）
    public private(set) var remoteHome: String?
    /// 測試或移除進行中（期間停用按鈕）
    public private(set) var activity: String?

    /// 已連上時要貼到遠端 Claude Code 的兩行
    public var setupLines: [String]? {
        guard state == .connected, let remoteHome else { return nil }
        return RemoteClientInstall.setupLines(home: remoteHome)
    }

    @ObservationIgnored private let env: Environment
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tunnel: SSHProcess?
    /// 「測試」臨時建的轉發（沒連線時）。和 `tunnel` 分開記，app 結束、移除主機時一樣要收掉。
    @ObservationIgnored private var probe: SSHProcess?
    @ObservationIgnored private var bridge: RemoteBridgeServer?
    /// 每次 connect 加一：舊的迴圈（關掉又馬上打開）看到不是自己的世代就不再動狀態
    @ObservationIgnored private var generation = 0

    public init(host: RemoteHost, environment: Environment) {
        self.id = host.id
        self.host = host
        self.env = environment
    }

    // MARK: - 對外操作

    public func connect() {
        guard !isOn, activity == nil else { return }
        lastError = nil
        lastResult = nil
        do {
            try openBridge()
        } catch {
            lastError = "無法建立本機的橋接 socket：\(error)"
            return
        }
        isOn = true
        generation += 1
        let gen = generation
        loop = Task { [weak self] in await self?.runLoop(gen) }
    }

    /// 關掉開關：結束 ssh、斷開所有遠端請求（進行中的遠端聽寫取消、麥克風關閉）。
    public func disconnect() {
        guard isOn else { return }
        isOn = false
        generation += 1
        loop?.cancel()
        loop = nil
        stopTunnel()
        closeBridge()
        state = .disconnected
    }

    /// 測試：已連上就從遠端經橋接問一次 status；沒連上就臨時裝 client、建轉發、問完收掉。
    public func test() async {
        guard activity == nil, state == .connected || !isOn else { return }
        activity = "測試中…"
        defer { activity = nil }
        lastResult = nil
        if state == .connected, let home = remoteHome, let tunnel {
            let check = await check(home: home, tunnel: tunnel)
            report(check)
            return
        }
        lastError = nil
        do { try openBridge() } catch {
            lastError = "無法建立本機的橋接 socket：\(error)"
            return
        }
        defer { if !isOn { closeBridge() } }
        let home: String
        switch await install() {
        case .failed(let f):
            lastError = f.message
            return
        case .installed(let h):
            home = h
            remoteHome = h
        }
        let probe: SSHProcess
        do { probe = try env.runner.start(tunnelArguments(home: home)) } catch {
            lastError = "無法執行 ssh：\(error.localizedDescription)"
            return
        }
        self.probe = probe
        env.tunnelStarted(host, probe)
        let check = await check(home: home, tunnel: probe)
        stopProbe()
        let code = await probe.waitForExit()
        if !check.ok, let line = probe.lastErrorLine {
            lastError = SSHFailure.classify(exitCode: code, stderrLine: line, action: "建立轉發").message
        } else {
            report(check)
        }
    }

    /// 移除遠端的 client（連著的話先斷線）。
    public func uninstallClient() async {
        guard activity == nil else { return }
        disconnect()
        activity = "移除中…"
        defer { activity = nil }
        lastResult = nil
        lastError = nil
        let result = await env.runner.run(host.sshArguments(command: [RemoteClientInstall.uninstallCommand]),
                                          timeout: 60)
        let outcome = RemoteClientInstall.parseUninstall(result)
        if case .failed = outcome { lastError = outcome.message } else {
            lastResult = outcome.message
            remoteHome = nil
        }
    }

    // MARK: - 連線迴圈

    private func runLoop(_ gen: Int) async {
        var delay = 2.0
        var everConnected = false
        while isCurrent(gen) {
            state = everConnected ? .reconnecting : .connecting
            switch await install() {
            case .failed(let f):
                guard isCurrent(gen) else { return }
                lastError = f.message
                if f.isFatal { giveUp(); return }
            case .installed(let home):
                guard isCurrent(gen) else { return }
                remoteHome = home
                let startedAt = Date()
                let process: SSHProcess
                do { process = try env.runner.start(tunnelArguments(home: home)) } catch {
                    lastError = "無法執行 ssh：\(error.localizedDescription)"
                    giveUp()
                    return
                }
                tunnel = process
                env.tunnelStarted(host, process)
                let check = await check(home: home, tunnel: process)
                guard isCurrent(gen) else { return }
                if process.isRunning {
                    state = .connected
                    everConnected = true
                    report(check)
                }
                let code = await process.waitForExit()
                guard isCurrent(gen) else { return }
                tunnel = nil
                env.tunnelEnded(host)
                // ssh 斷了：橋接上進行中的請求跟著斷（ssh 結束時它開的連線也會關），聽寫取消
                env.cancelDictation(host.displayName)
                let failure = SSHFailure.classify(exitCode: code, stderrLine: process.lastErrorLine, action: "SSH 連線")
                lastError = failure.message
                if failure.isFatal { giveUp(); return }
                if Date().timeIntervalSince(startedAt) > 60 { delay = 2 }
            }
            state = .reconnecting
            do { try await env.sleep(delay) } catch { return }
            delay = min(delay * 2, 30)
        }
    }

    private func isCurrent(_ gen: Int) -> Bool { isOn && generation == gen && !Task.isCancelled }

    /// 重試也沒用：關掉開關、停在未連線，錯誤訊息留著。
    private func giveUp() {
        isOn = false
        generation += 1
        loop = nil
        stopTunnel()
        closeBridge()
        state = .disconnected
    }

    // MARK: - 步驟

    private func install() async -> RemoteClientInstall.InstallOutcome {
        let script: Data
        do { script = try env.clientScript() } catch {
            return .failed(SSHFailure(message: "找不到要安裝的 client 檔：\(error.localizedDescription)", isFatal: true))
        }
        let result = await env.runner.run(host.sshArguments(command: [RemoteClientInstall.installCommand]),
                                          stdin: script, timeout: 60)
        return RemoteClientInstall.parseInstall(result)
    }

    private func tunnelArguments(home: String) -> [String] {
        let local = bridge?.configuration.socketPath ?? ""
        return host.sshArguments(options: [
            // 轉發一律用自己的連線：共用別人的 master 時，轉發會掛在那個 master 上，關開關、app 結束都收不掉
            "-o", "ControlPath=none",
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-R", "\(RemoteClientInstall.remoteSocketPath(home: home)):\(local)",
        ])
    }

    struct CheckResult {
        var ok: Bool
        var message: String
    }

    /// 從遠端執行 client 問一次 status：遠端 → ssh 轉發 → 本機橋接 → 控制介面，整條路都走過。
    private func check(home: String, tunnel: SSHProcess) async -> CheckResult {
        let command = [RemoteClientInstall.shellQuote(RemoteClientInstall.clientPath(home: home)), "status", "--json"]
        var detail = ""
        for attempt in 0..<max(1, env.checkAttempts) {
            if Task.isCancelled || !tunnel.isRunning { break }
            if attempt > 0 { try? await env.sleep(env.checkInterval) }
            let result = await env.runner.run(host.sshArguments(command: command), timeout: 30)
            let firstLine = result.stdout.components(separatedBy: .newlines).first ?? ""
            if let data = firstLine.data(using: .utf8),
               let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if status["app"] as? String == "running" {
                    return CheckResult(ok: true, message: "Saymend：\(status["state"] as? String ?? "未知")")
                }
                detail = (status["message"] as? String) ?? ""
            } else if result.exitCode != 0 {
                detail = SSHFailure.classify(result, action: "檢查").message
            }
        }
        return CheckResult(ok: false, message: detail.isEmpty ? "轉發沒有建立起來" : "轉發沒有建立起來（\(detail)）")
    }

    private func report(_ check: CheckResult) {
        if check.ok {
            lastResult = check.message
            lastError = nil
        } else {
            lastError = check.message
        }
    }

    private func openBridge() throws {
        guard bridge == nil else { return }
        bridge = try env.makeBridge(host)
    }

    private func closeBridge() {
        bridge?.stop()
        bridge = nil
        env.cancelDictation(host.displayName)
    }

    private func stopTunnel() {
        guard let t = tunnel else { return }
        t.terminate()
        tunnel = nil
        env.tunnelEnded(host)
    }

    private func stopProbe() {
        guard let p = probe else { return }
        p.terminate()
        probe = nil
        env.tunnelEnded(host)
    }

    /// app 結束、移除主機：同步收掉所有 ssh（含「測試」臨時建的轉發）與橋接。
    public func shutdown() {
        stopProbe()
        disconnect()
        if !isOn { closeBridge() }
    }

    #if DEBUG
    /// SwiftUI 預覽與設定頁畫面快照用：直接設定要顯示的狀態（不連線）。
    public func setPreviewState(_ state: State, isOn: Bool, lastError: String? = nil, lastResult: String? = nil,
                                remoteHome: String? = nil, activity: String? = nil) {
        self.state = state
        self.isOn = isOn
        self.lastError = lastError
        self.lastResult = lastResult
        self.remoteHome = remoteHome
        self.activity = activity
    }
    #endif
}
