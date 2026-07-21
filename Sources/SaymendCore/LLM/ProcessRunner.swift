import Foundation

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

    /// 輪詢等待（M3 教訓：輪詢是天然重試引擎；20ms 粒度對秒級 timeout 足夠）。
    /// 逾時：terminate（SIGTERM）→ 500ms 寬限 → SIGKILL；一律 waitUntilExit 收屍後才回。
    private static func waitOrKill(_ p: Process, timeout: TimeInterval) async -> Bool {
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
                await Task.detached { p.waitUntilExit() }.value
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await Task.detached { p.waitUntilExit() }.value
        return false
    }
}
