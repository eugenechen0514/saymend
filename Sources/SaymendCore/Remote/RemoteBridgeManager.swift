import Darwin
import Foundation
import Observation
import OSLog
import SaymendControl

/// 設定頁「遠端」的後端：主機清單（存在 AppSettings）、每台主機一條 `RemoteLink`、app 啟動自動連線、
/// app 結束收掉所有 ssh。每台主機用自己的本機 socket（`<socketDirectory>/<id>.sock`），
/// 橋接因此知道請求來自哪台主機，HUD 與歷史標得出來源。
@MainActor
@Observable
public final class RemoteBridgeManager {
    public private(set) var links: [RemoteLink] = []
    /// 控制介面有沒有起來（沒起來就沒辦法提供橋接）
    public private(set) var isControlAvailable = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let socketDirectory: URL
    @ObservationIgnored private let clientScriptURL: URL?
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let runner: SSHRunner
    @ObservationIgnored private let sayPath: String
    @ObservationIgnored private let sleep: (Double) async throws -> Void
    @ObservationIgnored private var connectControl: ((String) throws -> Int32)?
    @ObservationIgnored private var cancelDictation: (String) -> Void = { _ in }
    private nonisolated static let log = Logger(subsystem: "io.saymend.app", category: "remote")

    public init(settings: AppSettings, socketDirectory: URL, clientScriptURL: URL?, appVersion: String,
                runner: SSHRunner = SSHRunner(), sayPath: String = "/usr/bin/say",
                sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.settings = settings
        self.socketDirectory = socketDirectory
        self.clientScriptURL = clientScriptURL
        self.appVersion = appVersion
        self.runner = runner
        self.sayPath = sayPath
        self.sleep = sleep
        links = settings.remoteHosts.map(makeLink)
    }

    /// 控制介面起來之後接上：`connectControl` 開一條標著主機名稱的 app 內控制連線，
    /// `cancelDictation` 取消某台主機發起、還在進行的聽寫。
    public func attach(connectControl: @escaping (String) throws -> Int32,
                       cancelDictation: @escaping (String) -> Void) {
        self.connectControl = connectControl
        self.cancelDictation = cancelDictation
        isControlAvailable = true
    }

    /// app 啟動時：先收掉上次沒結束的 ssh（app 當掉留下的），再連「自動連線」的主機。
    public func startAutoConnect() {
        cleanupOrphanedTunnels()
        for link in links where link.host.autoConnect { link.connect() }
    }

    /// 新增主機。不接受就回傳原因。
    @discardableResult
    public func add(_ host: RemoteHost) -> String? {
        if let problem = RemoteHost.validate(kind: host.kind, host: host.host, port: host.port, user: host.user) {
            return problem
        }
        guard !links.contains(where: { $0.host.displayName == host.displayName }) else {
            return "\(host.displayName) 已經在清單裡"
        }
        links.append(makeLink(host))
        persist()
        return nil
    }

    public func remove(id: String) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        links[i].shutdown()
        links.remove(at: i)
        persist()
    }

    public func setAutoConnect(id: String, _ on: Bool) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        link.host.autoConnect = on
        persist()
    }

    /// app 結束：同步收掉所有 ssh 與橋接（進行中的遠端聽寫取消、麥克風關閉）。
    public func shutdown() {
        for link in links { link.shutdown() }
    }

    /// 「新增主機」的下拉選單：~/.ssh/config 的別名，副標用 `ssh -G` 解析出的 user@hostname:port。
    public func sshConfigEntries(sshDirectory: String = NSString(string: "~/.ssh").expandingTildeInPath) async
        -> [SSHConfigEntry] {
        let aliases = SSHConfigReader.aliases(sshDirectory: sshDirectory)
        let runner = self.runner
        return await withTaskGroup(of: (Int, SSHConfigEntry).self) { group in
            for (i, alias) in aliases.enumerated() {
                group.addTask {
                    // `--` 之後才是別名：別名不可能被當成選項（`isPlainAlias` 也已排除 - 開頭）
                    let r = await runner.run(["-G", "--", alias], timeout: 5)
                    guard r.exitCode == 0 else { return (i, SSHConfigEntry(alias: alias)) }
                    return (i, SSHConfigReader.parseResolved(alias: alias, output: r.stdout))
                }
            }
            var entries = [SSHConfigEntry?](repeating: nil, count: aliases.count)
            for await (i, entry) in group { entries[i] = entry }
            return entries.compactMap { $0 }
        }
    }

    // MARK: - 私有

    private func persist() {
        settings.remoteHosts = links.map(\.host)
    }

    func socketPath(for host: RemoteHost) -> String {
        socketDirectory.appendingPathComponent("\(host.id).sock").path
    }

    private func pidFile(for host: RemoteHost) -> URL {
        socketDirectory.appendingPathComponent("\(host.id).ssh.pid")
    }

    private func makeLink(_ host: RemoteHost) -> RemoteLink {
        let env = RemoteLink.Environment(
            runner: runner,
            clientScript: { [clientScriptURL] in
                guard let url = clientScriptURL else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "app 裡沒有附 client 檔"])
                }
                return try Data(contentsOf: url)
            },
            makeBridge: { [weak self] host in
                guard let self, let connect = self.connectControl else {
                    throw RemoteBridgeError.controlUnavailable
                }
                let origin = host.displayName
                let bridge = RemoteBridgeServer(
                    configuration: .init(socketPath: self.socketPath(for: host), origin: origin,
                                         appVersion: self.appVersion, sayPath: self.sayPath),
                    connectControl: connect,
                    log: { line in Self.log.notice("遠端 \(origin, privacy: .public)：\(line, privacy: .public)") })
                try bridge.start()
                return bridge
            },
            cancelDictation: { [weak self] origin in self?.cancelDictation(origin) },
            tunnelStarted: { [weak self] host, process in self?.recordTunnel(host, pid: process.pid) },
            tunnelEnded: { [weak self] host in self?.forgetTunnel(host) },
            sleep: sleep)
        return RemoteLink(host: host, environment: env)
    }

    /// 記下轉發用的 ssh：app 當掉時它不會跟著結束，下次啟動靠這個檔收掉。pid 之外也記行程的啟動時間，
    /// 免得 pid 被別的行程重用時誤殺。
    private func recordTunnel(_ host: RemoteHost, pid: pid_t) {
        guard let started = Self.processStartTime(pid) else { return }
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? "\(pid) \(started)\n".write(to: pidFile(for: host), atomically: true, encoding: .utf8)
    }

    private func forgetTunnel(_ host: RemoteHost) {
        try? FileManager.default.removeItem(at: pidFile(for: host))
    }

    func cleanupOrphanedTunnels() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: socketDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasSuffix(".ssh.pid") {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = pid_t(parts[0]), let started = UInt64(parts[1]),
                  Self.processStartTime(pid) == started, Self.executablePath(pid) == runner.sshPath else { continue }
            Self.log.notice("收掉上次留下的 ssh 轉發（pid \(pid, privacy: .public)）")
            kill(pid, SIGTERM)
        }
    }

    static func processStartTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

public enum RemoteBridgeError: Error, CustomStringConvertible {
    case controlUnavailable

    public var description: String {
        switch self {
        case .controlUnavailable: return "控制介面沒有啟動（另一個 Saymend 可能正在使用 control.sock）"
        }
    }
}
