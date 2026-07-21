import Foundation

public enum ClaudeCLIError: Error, Equatable, Sendable {
    case cliNotFound
}

/// FIFO slot queue（spec §4.5 併發上限）。release 時 slot 直接轉移給隊首。
actor SlotQueue {
    private let capacity: Int
    private var used = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(capacity: Int) { self.capacity = capacity }
    func acquire() async {
        if used < capacity { used += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // 被喚醒＝slot 已轉移
    }
    func release() {
        if waiters.isEmpty { used -= 1 } else { waiters.removeFirst().resume() }
    }
}

/// 本機 claude CLI provider（spec §4）。hermetic 隔離、--system-prompt-file、
/// 私有 cwd、併發上限 2、monotonic deadline（含排隊、逾期不 spawn）。
public final class ClaudeCLIProvider: LLMProvider, @unchecked Sendable {
    public static let maxConcurrentProcesses = 2

    private let configProvider: @Sendable () -> ClaudeCLIConfig
    private let detect: @Sendable (String?) async -> ClaudeCLIDetection
    private let runner: any ProcessRunner
    private let slots = SlotQueue(capacity: ClaudeCLIProvider.maxConcurrentProcesses)
    private let clock = ContinuousClock()

    public init(configProvider: @escaping @Sendable () -> ClaudeCLIConfig,
                detect: @escaping @Sendable (String?) async -> ClaudeCLIDetection,
                runner: any ProcessRunner = LiveProcessRunner()) {
        self.configProvider = configProvider
        self.detect = detect
        self.runner = runner
    }

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let deadline = clock.now + .seconds(timeout)              // deadline 含排隊（spec §4.5）
        let config = configProvider()
        guard case .found(let cliPath, _) = await detect(config.cliPathOverride) else {
            throw ClaudeCLIError.cliNotFound
        }
        await slots.acquire()
        // slot 顯式釋放（兩處：成功 return 前、任何 throw 前）。不用 defer{Task{release}}：
        // 額外的非結構化 Task 在高平行負載下加劇 executor 壅塞、打亂 deadline timing
        // （Task 5 debug 實證：defer-Task 版在 9 測試平行時 queuedCallExpired 穩定失敗、隔離跑則過）。
        do {
            // 取得 slot 後重算剩餘；逾期不 spawn（含「排隊中逾時、slot 釋出也不補 spawn」）
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw ProcessRunnerError.timedOut }

            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("saymend-cli-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let sysFile = fm.temporaryDirectory
                .appendingPathComponent("saymend-sys-\(UUID().uuidString).txt")
            fm.createFile(atPath: sysFile.path, contents: Data(system.utf8),
                          attributes: [.posixPermissions: 0o600])
            defer {                                                // 成功/失敗/逾時所有路徑一律刪（spec §4.2/§4.3）
                try? fm.removeItem(at: workDir)
                try? fm.removeItem(at: sysFile)
            }

            let stdout = try await runner.run(
                executable: cliPath,
                arguments: Self.arguments(model: config.model, systemPromptFile: sysFile.path),
                stdin: user,                                       // user payload 走 stdin、不經 argv
                workingDirectory: workDir,
                timeout: Self.seconds(remaining))
            guard !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMError.emptyResponse
            }
            await slots.release()                                  // 成功路徑
            return stdout                                          // 原樣交下游 EnvelopeParser.strict
        } catch {
            await slots.release()                                  // 所有失敗/逾時路徑
            throw error
        }
    }

    /// hermetic flag 組合（spec §4.2 五條；Task 1 spike 定案 2026-07-21）。
    /// 不用 --bare：它強制 API-key auth、與 OAuth 互斥（help 明載）；
    /// 隔離靠 --setting-sources ""（不載 user/project/local ＝ CLAUDE.md/hooks/MCP 全不進）
    /// ＋ disableAllHooks（雙保險）＋ --tools ""（無工具）＋ --no-session-persistence（不落 session）。
    static func arguments(model: String, systemPromptFile: String) -> [String] {
        ["--print",
         "--no-session-persistence",
         "--settings", #"{"disableAllHooks":true}"#,
         "--tools", "",
         "--setting-sources", "",
         "--strict-mcp-config",
         "--system-prompt-file", systemPromptFile,
         "--output-format", "text",
         "--model", model]
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
