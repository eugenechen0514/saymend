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

        // terminationHandler 必須在 run() 前安裝，才能讓 launch-to-exit 全程只有這一個
        // event-driven ownership；快速結束的 child 即使在 run() 返回前退出也不會漏訊號。
        let exitSignal = Self.installTerminationHandler(on: process)
        do { try process.run() } catch {
            process.terminationHandler = nil
            throw ProcessRunnerError.spawnFailed(String(describing: error))
        }
        // stdin 寫入後關閉——子程序才收得到 EOF（claude --print 讀 stdin 到 EOF）
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()

        // stdout/stderr 並行排空（pipe buffer 只有 64KB，不並行排空大輸出必死鎖）
        async let outData = Self.drain(outPipe.fileHandleForReading)
        async let errData = Self.drain(errPipe.fileHandleForReading)

        let completion = await Self.waitOrKill(process, exitSignal: exitSignal, timeout: timeout)
        let out = await outData
        let err = await errData
        guard case .exited(let exit) = completion else { throw ProcessRunnerError.timedOut }
        guard exit.status == 0 else {
            throw ProcessRunnerError.nonZeroExit(code: exit.status,
                                                 stderrSummary: String(decoding: err.prefix(500), as: UTF8.self))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `FileHandle.readToEnd()` 仍是 blocking drain，故暫放 detached task 以維持兩條 pipe 並行。
    /// 它與舊 `waitUntilExit()` 同屬阻塞 global executor 的技術債，但 event-driven pipe I/O
    /// 會同時改動 FD ownership／EOF／取消語意；issue #26 已記錄，這次不和收屍 lifecycle 混改。
    private static func drain(_ handle: FileHandle) async -> Data {
        await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
    }

    struct ExitEvent: Equatable, Sendable {
        let status: Int32
    }

    enum ExitWaitOutcome: Equatable, Sendable {
        case exited(ExitEvent)
        case timedOut
    }

    /// `terminationHandler` 的 callback context 未定義，不能假設它在 Swift actor 或特定 queue。
    /// callback 與 timer 在同一把 lock 下決定第一個完成者；resume 一律在 lock 外執行。
    final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var event: ExitEvent?
        private var waiters: [UUID: CheckedContinuation<ExitWaitOutcome, Never>] = [:]

        func finish(_ value: ExitEvent) {
            lock.lock()
            guard event == nil else { lock.unlock(); return }
            event = value
            let pending = Array(waiters.values)
            waiters = [:]
            lock.unlock()
            pending.forEach { $0.resume(returning: .exited(value)) }
        }

        func wait(limit: Duration) async -> ExitWaitOutcome {
            await withCheckedContinuation { continuation in
                let id = UUID()
                lock.lock()
                if let event {
                    lock.unlock()
                    continuation.resume(returning: .exited(event))
                    return
                }
                waiters[id] = continuation
                lock.unlock()

                // 每個 waiter 自己的有限 timer 會把 continuation 從字典移除再 resume。
                // callback 永遠不來時也不會形成 signal → continuation → task → signal 的永久環。
                Task {
                    try? await Task.sleep(for: limit)
                    self.timeOut(id)
                }
            }
        }

        private func timeOut(_ id: UUID) {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: .timedOut)
        }
    }

    typealias WaitOrKillOutcome = ExitWaitOutcome

    typealias ExitWait = @Sendable (
        _ limit: Duration,
        _ signal: ExitSignal
    ) async -> ExitWaitOutcome

    private static let terminationGrace: Duration = .milliseconds(500)
    private static let reapLimit: Duration = .seconds(1)
    private static let log = Logger(subsystem: "io.saymend.app", category: "ProcessRunner")

    /// Foundation 明定 handler 在底層 process 結束時才呼叫。`terminationStatus` 因此只在
    /// handler 內 snapshot，等 snapshot 完成後才發布事件；其他路徑不再碰 status，也不再把
    /// `isRunning == false` 當作「status 已同步」的替代證明。
    static func installTerminationHandler(on process: Process) -> ExitSignal {
        let signal = ExitSignal()
        process.terminationHandler = { finished in
            signal.finish(ExitEvent(status: finished.terminationStatus))
        }
        return signal
    }

    /// 等 event-driven termination callback，但不讓 callback delivery 問題重新拖死呼叫端。
    /// timer 與 callback 直接在 `ExitSignal` 內仲裁並移除 loser；不建立 blocking waiter，
    /// 也不把 timeout 後的 suspension task 永久留在記憶體。
    static func awaitExit(limit: Duration, signal: ExitSignal) async -> ExitWaitOutcome {
        await signal.wait(limit: limit)
    }

    /// 等 termination event；execution budget 到期後送 SIGTERM，500ms 仍未退出才送 SIGKILL。
    /// 正常與 timeout／SIGKILL 路徑都只接受 handler 發布的 exit event 作為「已收屍」證據。
    static func waitOrKill(
        _ process: Process,
        exitSignal: ExitSignal,
        timeout: TimeInterval,
        wait: @escaping ExitWait = { limit, signal in
            await LiveProcessRunner.awaitExit(limit: limit, signal: signal)
        }
    ) async -> WaitOrKillOutcome {
        switch await wait(.seconds(timeout), exitSignal) {
        case .exited(let event):
            return .exited(event)
        case .timedOut:
            break
        }

        // callback 與 deadline 可同時到；isRunning 只用來避免對已退出 pid 多送 signal，
        // 不再拿來判定 status 是否可讀。
        if process.isRunning { process.terminate() }
        switch await wait(Self.terminationGrace, exitSignal) {
        case .exited:
            return .timedOut
        case .timedOut:
            break
        }

        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if case .timedOut = await wait(Self.reapLimit, exitSignal) {
            Self.log.error("SIGKILL 後等 terminationHandler 回報逾時（pid \(process.processIdentifier, privacy: .public)，上限 \(Self.reapLimit.components.seconds, privacy: .public) 秒）")
        }
        return .timedOut
    }
}
