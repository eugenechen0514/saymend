import Foundation
import OSLog

/// 可測的 process 邊界（spec §4.3）：ClaudeCLIProvider 只依賴本 protocol，
/// 單元測試注入假件、live 實作有自己的真 process 測試。
public protocol ProcessRunner: Sendable {
    /// 回 stdout。timeout＝execution budget（>0 且 finite 即可、允許 <1s——spec §5 兩層契約）。
    func run(executable: String, arguments: [String], stdin: String,
             workingDirectory: URL, timeout: TimeInterval) async throws -> String
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case timedOut
    case nonZeroExit(code: Int32, stderrSummary: String)
    case spawnFailed(String)
}

public struct LiveProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String], stdin: String,
                    workingDirectory: URL, timeout: TimeInterval) async throws -> String {
        // runner 邊界防禦（spec §5）：budget 必須 >0 且 finite——非正／非有限＝已逾期，
        // 不 spawn。注意這**不是** range clamp（把 0.2s 擴成 1s 會違反 deadline）。
        guard timeout.isFinite, timeout > 0 else { throw ProcessRunnerError.timedOut }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw ProcessRunnerError.spawnFailed(String(describing: error))
        }
        // stdin 寫入後關閉——子程序才收得到 EOF（claude --print 讀 stdin 到 EOF）
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()

        // stdout/stderr 並行排空（pipe buffer 只有 64KB，不並行排空大輸出必死鎖）
        async let outData = Self.drain(outPipe.fileHandleForReading)
        async let errData = Self.drain(errPipe.fileHandleForReading)

        let timedOut = await Self.waitOrKill(process, timeout: timeout)
        let out = await outData
        let err = await errData
        if timedOut { throw ProcessRunnerError.timedOut }
        let code = process.terminationStatus
        guard code == 0 else {
            throw ProcessRunnerError.nonZeroExit(code: code,
                                                 stderrSummary: String(decoding: err.prefix(500), as: UTF8.self))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// FileHandle.readToEnd 是阻塞呼叫——放 detached task，不佔 cooperative pool。
    private static func drain(_ handle: FileHandle) async -> Data {
        await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
    }

    typealias ReapWait = @Sendable (
        _ limit: Duration,
        _ waiter: @escaping @Sendable () async -> Void
    ) async -> BoundedWaitOutcome

    private static let reapLimit: Duration = .seconds(1)
    private static let log = Logger(subsystem: "io.saymend.app", category: "ProcessRunner")

    /// 正常路徑開始收屍時 `isRunning` 已是 false，本來應立刻返回；1 秒已是 20ms 輪詢粒度的
    /// 50 倍，足夠吸收 executor 排程延遲，也不會讓 Foundation 通知未派送時變成多秒卡頓。
    ///
    /// `terminationStatus` 在 process 還在跑時會丟 `NSInvalidArgumentException`，但 Foundation
    /// 的 contract 明確以 `isRunning == false` 作為可安全讀取的條件，並不要求
    /// `waitUntilExit()` 已返回。因此正常路徑即使放棄收屍等待，`run()` 仍可讀 status；
    /// 逾時路徑則會先丟 `.timedOut`，根本不讀 status。
    ///
    /// 這是止住呼叫端的有界等待，不是根治：`awaitBounded` 不會中止 `waiter`。若
    /// `waitUntilExit()` 永遠收不到 notification，逾時後那個 detached task 仍會永久佔住一條
    /// global executor 執行緒並保留 Process／pipe。terminationHandler 必須提前到 `run()` 前安裝，
    /// 並改寫 launch-to-exit 的 ownership；這個 hotfix 先保留已驗證的 `isRunning` 輪詢與既有
    /// process lifecycle，至少以 error log 讓每次外洩可追。
    static func awaitReap(
        limit: Duration,
        waiter: @escaping @Sendable () async -> Void
    ) async -> BoundedWaitOutcome {
        await awaitBounded(limit: limit, work: waiter)
    }

    /// 輪詢等待（M3 教訓：輪詢是天然重試引擎；20ms 粒度對秒級 timeout 足夠）。
    /// 逾時：terminate（SIGTERM）→ 500ms 寬限 → SIGKILL；兩條路徑的收屍都另有 1 秒上限。
    static func waitOrKill(
        _ p: Process,
        timeout: TimeInterval,
        reap: @escaping ReapWait = { limit, waiter in
            await LiveProcessRunner.awaitReap(limit: limit, waiter: waiter)
        }
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while p.isRunning {
            if clock.now >= deadline {
                p.terminate()
                let grace = clock.now + .milliseconds(500)
                while p.isRunning && clock.now < grace {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                let outcome = await reap(Self.reapLimit) {
                    await Task.detached { p.waitUntilExit() }.value
                }
                if outcome == .timedOut {
                    Self.log.error("逾時終止後等 process 收屍逾時（SIGKILL 路徑，pid \(p.processIdentifier, privacy: .public)，上限 \(Self.reapLimit.components.seconds, privacy: .public) 秒）")
                }
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let outcome = await reap(Self.reapLimit) {
            await Task.detached { p.waitUntilExit() }.value
        }
        if outcome == .timedOut {
            Self.log.error("正常結束後等 process 收屍逾時（pid \(p.processIdentifier, privacy: .public)，上限 \(Self.reapLimit.components.seconds, privacy: .public) 秒）")
        }
        return false
    }
}
