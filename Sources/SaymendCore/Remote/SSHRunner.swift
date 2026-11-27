import Darwin
import Foundation

/// 執行系統的 ssh。只負責起行程、收輸出、逾時與取消；參數由呼叫端組（`RemoteHost.sshArguments`）。
public struct SSHRunner: Sendable {
    public struct Result: Equatable, Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        /// stderr 最後一行非空白的內容（ssh 的錯誤原因通常在這裡）
        public var lastErrorLine: String? {
            stderr.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
        }
    }

    public var sshPath: String
    /// nil＝沿用 app 的環境（含 launchd 給的 SSH_AUTH_SOCK）
    public var environment: [String: String]?

    public init(sshPath: String = "/usr/bin/ssh", environment: [String: String]? = nil) {
        self.sshPath = sshPath
        self.environment = environment
    }

    /// 從 Finder／登入項目啟動的 app，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`：ssh config 裡的
    /// `ProxyCommand`（例如 Homebrew 裝的 cloudflared）會找不到。沿用 app 的環境（含 launchd 給的
    /// SSH_AUTH_SOCK），只在 PATH 後面補上 Homebrew 與 /usr/local 的 bin。
    public static func environmentForGUIApp(_ base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var env = base
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !parts.contains(extra) { parts.append(extra) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// 執行到結束。逾時或 Task 被取消都會結束 ssh（先 SIGTERM，2 秒後 SIGKILL）。
    /// ssh 結束後最多再等 2 秒把輸出讀完：萬一有子行程（例如使用者設定的背景 master）還開著 pipe，
    /// 不會一直等下去。
    public func run(_ args: [String], stdin: Data? = nil, timeout: TimeInterval) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = args
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let box = ProcessBox(process)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global().async {
                    let exited = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in exited.signal() }
                    do {
                        try process.run()
                    } catch {
                        cont.resume(returning: Result(exitCode: -1, stdout: "",
                                                      stderr: "無法執行 \(sshPath)：\(error.localizedDescription)",
                                                      timedOut: false))
                        return
                    }
                    box.started()
                    if let stdin, let inPipe {
                        // ssh 先結束（例如驗證失敗）時寫入要回 EPIPE，不能對整個 app 送 SIGPIPE
                        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        DispatchQueue.global().async {
                            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
                    let timer = DispatchWorkItem { box.stop(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let out = PipeCollector(outPipe.fileHandleForReading)
                    let err = PipeCollector(errPipe.fileHandleForReading)
                    exited.wait()
                    timer.cancel()
                    out.waitForEOF(upTo: 2)
                    err.waitForEOF(upTo: 2)
                    cont.resume(returning: Result(exitCode: process.terminationStatus,
                                                  stdout: String(decoding: out.data, as: UTF8.self),
                                                  stderr: String(decoding: err.data, as: UTF8.self),
                                                  timedOut: box.timedOut))
                }
            }
        } onCancel: {
            box.stop(timedOut: false)
        }
    }

    /// 起一個長駐的 ssh（轉發用）。stdout 丟棄，stderr 留最後幾行給錯誤訊息用。
    public func start(_ args: [String]) throws -> SSHProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = args
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        let handle = SSHProcess(process: process)
        process.terminationHandler = { p in handle.exited(code: p.terminationStatus) }
        try process.run()
        let reader = errPipe.fileHandleForReading
        DispatchQueue.global().async {
            while let chunk = try? reader.read(upToCount: 4096), !chunk.isEmpty {
                handle.appendStderr(chunk)
            }
            handle.stderrClosed()
        }
        return handle
    }
}

/// 在背景把一個 pipe 讀到 EOF，邊讀邊存。
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                lock.lock(); buffer.append(chunk); lock.unlock()
            }
            done.signal()
        }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }

    func waitForEOF(upTo seconds: Double) { _ = done.wait(timeout: .now() + seconds) }
}

/// 跨執行緒共用的 Process 狀態：取消可能早於啟動、逾時可能和正常結束同時發生。
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var isStarted = false
    private var stopRequested = false
    private(set) var timedOut = false

    init(_ process: Process) { self.process = process }

    func started() {
        lock.lock()
        isStarted = true
        let stop = stopRequested
        lock.unlock()
        if stop { terminate() }
    }

    func stop(timedOut: Bool) {
        lock.lock()
        if timedOut { self.timedOut = true }
        stopRequested = true
        let running = isStarted
        lock.unlock()
        if running { terminate() }
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// 一個長駐的 ssh 行程。
public final class SSHProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stderrTail = Data()
    private var exitCode: Int32?
    private var stderrDone = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process) { self.process = process }

    public var pid: pid_t { process.processIdentifier }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode == nil
    }

    /// stderr 最後一行非空白的內容
    public var lastErrorLine: String? {
        lock.lock()
        let text = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }

    /// 先 SIGTERM，2 秒內沒結束就 SIGKILL。
    public func terminate() {
        guard isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    /// 等它結束（且 stderr 讀完，錯誤訊息才完整），回傳結束碼。
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = exitCode, stderrDone {
                lock.unlock()
                cont.resume(returning: code)
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
    }

    fileprivate func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 8192 { stderrTail = stderrTail.suffix(4096) }
        lock.unlock()
    }

    fileprivate func exited(code: Int32) {
        lock.lock()
        exitCode = code
        resumeIfDone()
    }

    fileprivate func stderrClosed() {
        lock.lock()
        stderrDone = true
        resumeIfDone()
    }

    /// 在鎖內呼叫，會解鎖。
    private func resumeIfDone() {
        guard let code = exitCode, stderrDone else { lock.unlock(); return }
        let pending = waiters
        waiters = []
        lock.unlock()
        for w in pending { w.resume(returning: code) }
    }
}
