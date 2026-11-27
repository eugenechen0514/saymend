import Darwin
import Foundation

/// `saymend` 的本體：連到執行中的 app、送一個請求、把回覆轉成 CLI 輸出契約、決定 exit code。
/// 不錄音、不載模型。`main.swift` 只負責接上 stdout／stderr 與訊號。
public final class CLIRunner {
    /// stdout／stderr 的寫入口。**每次呼叫＝一整行**，實作必須當場 flush（NDJSON 的消費端是逐行讀的）。
    public struct Output {
        public var out: (String) -> Void
        public var err: (String) -> Void
        public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void) {
            self.out = out
            self.err = err
        }
    }

    /// 一次性請求（status／stop／cancel／version）等回覆的上限。串流指令不設。
    public static let replyTimeout: Double = 10
    /// 收到 SIGINT／SIGTERM 後等 app 確認取消的預設上限；逾時直接以 exit 5 結束（app 端也會因斷線而取消）。
    public static let defaultInterruptGrace: Double = 2

    private let socketPath: String
    private let output: Output
    private let cliVersion: String
    private let connect: (String) throws -> Int32
    private let terminate: (Int32) -> Void
    private let interruptGrace: Double

    private let lock = NSLock()
    /// 進行中 dictate 的 socket；訊號處理器用它送 cancel
    private var dictateFD: Int32?
    private var dictateJSON = false
    private var interrupted = false
    /// 測試用：在送出 dictate 請求之前呼叫（用來把訊號釘在「已連上、請求還沒送」這個窗口）
    var beforeDictateRequest: (() -> Void)?

    public init(socketPath: String, output: Output, cliVersion: String,
                connect: @escaping (String) throws -> Int32 = { try UnixSocket.connect(path: $0) },
                terminate: @escaping (Int32) -> Void = { exit($0) },
                interruptGrace: Double = CLIRunner.defaultInterruptGrace) {
        self.socketPath = socketPath
        self.interruptGrace = interruptGrace
        self.output = output
        self.cliVersion = cliVersion
        self.connect = connect
        self.terminate = terminate
    }

    public func run(_ args: [String]) -> Int32 {
        let command: CLICommand
        do {
            command = try CLIArguments.parse(args)
        } catch let e as CLIUsageError {
            emitError(.usage, e.message, json: e.json)
            output.err(CLIArguments.usage)
            return ControlExitCode.usage
        } catch {
            return ControlExitCode.usage
        }
        switch command {
        case .help:
            output.out(CLIArguments.usage)
            return ControlExitCode.success
        case .version(let json): return runVersion(json: json)
        case .status(let json): return runStatus(json: json)
        case .stop(let json): return runSimple(.stop, json: json)
        case .cancel(let json): return runSimple(.cancel, json: json)
        case .events(let presence, let json): return runEvents(presence: presence, json: json)
        case .dictate(let options, let json): return runDictate(options, json: json)
        }
    }

    /// SIGINT／SIGTERM（`main.swift` 從訊號佇列呼叫，可與 `run` 並行）。
    /// dictate 進行中：請 app 取消這一段，並在寬限期後強制以 exit 5 結束（app 端也會因為斷線自行取消）。
    /// 其他時候：立刻以 exit 5 結束——只有 dictate 有「取消」的語意，其餘指令沒有東西要丟棄，照慣例結束即可。
    public func interrupt() {
        lock.lock()
        let first = !interrupted
        interrupted = true
        let json = dictateJSON
        let active = dictateFD != nil
        // 持鎖寫：`runDictate` 收尾時先在鎖內清掉 dictateFD 才 close，這裡就不會寫到已關閉（或被重用）的 fd
        if first, let fd = dictateFD { UnixSocket.writeLine(fd, ControlRequest.cancel.encoded()) }
        lock.unlock()
        guard first else { return }
        guard active else {
            terminate(ControlExitCode.cancelled)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptGrace) { [self] in
            guard dictateIsActive else { return }   // run 已經自己收尾了
            emitError(.cancelled, "已取消（app 未在時限內確認）", json: json)
            terminate(ControlExitCode.cancelled)
        }
    }

    // MARK: - 指令

    private func runStatus(json: Bool) -> Int32 {
        let fd: Int32
        do { fd = try connect(socketPath) } catch {
            if case UnixSocketError.notRunning = error {
                if json {
                    output.out(JSONLine([("v", .int(ControlProtocol.version)), ("app", .string("not_running"))]).encoded())
                } else {
                    output.err("Saymend.app 未執行")
                }
                return ControlExitCode.notRunning
            }
            return connectFailure(error, json: json)
        }
        defer { close(fd) }
        UnixSocket.setReceiveTimeout(fd, seconds: Self.replyTimeout)
        guard UnixSocket.writeLine(fd, ControlRequest.status.encoded()) else { return lostApp(json: json) }
        switch readReply(fd) {
        case .message(.status(let state, let source, let modelReady, let presence)):
            if json {
                var line = JSONLine([("v", .int(ControlProtocol.version)), ("app", .string("running")),
                                     ("state", .string(state.rawValue)),
                                     ("source", source.map { .string($0.rawValue) } ?? .null),
                                     ("modelReady", .bool(modelReady))])
                // 舊版 app 不送 presence：照實不輸出這個欄位，不假裝成 `{}`
                if let presence { line.set("presence", ControlPresence.jsonValue(presence)) }
                output.out(line.encoded())
            } else {
                var text = "Saymend 執行中｜狀態 \(state.rawValue)｜來源 \(source?.rawValue ?? "—")｜模型\(modelReady ? "已就緒" : "未就緒")"
                if let presence { text += "｜presence \(Self.presenceText(presence) ?? "—")" }
                output.out(text)
            }
            return ControlExitCode.success
        case .message(.error(let code, let message)):
            emitError(code, message, json: json)
            return code.exitCode
        case .message:
            return unexpected(json: json)
        case .failure(let code, let message):
            emitError(code, message, json: json)
            return code.exitCode
        }
    }

    private func runSimple(_ request: ControlRequest, json: Bool) -> Int32 {
        let fd: Int32
        do { fd = try connect(socketPath) } catch { return connectFailure(error, json: json) }
        defer { close(fd) }
        UnixSocket.setReceiveTimeout(fd, seconds: Self.replyTimeout)
        guard UnixSocket.writeLine(fd, request.encoded()) else { return lostApp(json: json) }
        switch readReply(fd) {
        case .message(.ok):
            if json { output.out(ControlMessage.ok.encoded()) }
            return ControlExitCode.success
        case .message(.error(let code, let message)):
            emitError(code, message, json: json)
            return code.exitCode
        case .message:
            return unexpected(json: json)
        case .failure(let code, let message):
            emitError(code, message, json: json)
            return code.exitCode
        }
    }

    private func runVersion(json: Bool) -> Int32 {
        var appVersion: String?
        if let fd = try? connect(socketPath) {
            UnixSocket.setReceiveTimeout(fd, seconds: Self.replyTimeout)
            if UnixSocket.writeLine(fd, ControlRequest.version.encoded()),
               case .message(.version(let app)) = readReply(fd) {
                appVersion = app
            }
            close(fd)
        }
        if json {
            output.out(JSONLine([("v", .int(ControlProtocol.version)), ("cli", .string(cliVersion)),
                                 ("app", appVersion.map { .string($0) } ?? .null),
                                 ("protocol", .int(ControlProtocol.version))]).encoded())
        } else {
            output.out("saymend CLI \(cliVersion)")
            output.out("Saymend.app \(appVersion ?? "（未執行）")")
            output.out("protocol v\(ControlProtocol.version)")
        }
        return ControlExitCode.success
    }

    private func runEvents(presence: String?, json: Bool) -> Int32 {
        let fd: Int32
        do { fd = try connect(socketPath) } catch { return connectFailure(error, json: json) }
        defer { close(fd) }
        guard UnixSocket.writeLine(fd, ControlRequest.events(presence: presence).encoded()) else { return lostApp(json: json) }
        let reader = LineReader(fd: fd)
        while true {
            let line: String?
            do { line = try reader.next() } catch { return lostApp(json: json) }
            guard let line else { return lostApp(json: json) }   // app 結束＝串流結束、exit 3
            guard let message = try? ControlMessage.decode(line) else { continue }
            switch message {
            case .state(let state, let source, let presence, let at):
                if json {
                    output.out(message.encoded())
                } else {
                    var text = "\(ControlTimestamp.format(at)) \(state.rawValue) \(source?.rawValue ?? "-")"
                    if let presence, let p = Self.presenceText(presence) { text += " \(p)" }
                    output.out(text)
                }
            case .error(let code, let msg):
                emitError(code, msg, json: json)
                return code.exitCode
            default:
                continue
            }
        }
    }

    private func runDictate(_ options: DictateOptions, json: Bool) -> Int32 {
        let fd: Int32
        do { fd = try connect(socketPath) } catch { return connectFailure(error, json: json) }
        defer {
            lock.lock(); dictateFD = nil; lock.unlock()
            close(fd)
        }
        lock.lock()
        dictateJSON = json
        let alreadyInterrupted = interrupted
        lock.unlock()
        // 送出請求之前就收到訊號：直接放棄，不開麥克風
        if alreadyInterrupted {
            emitError(.cancelled, "已取消", json: json)
            return ControlExitCode.cancelled
        }
        beforeDictateRequest?()
        guard UnixSocket.writeLine(fd, ControlRequest.dictate(options).encoded()) else { return lostApp(json: json) }
        // dictate 請求**寫出之後**才讓訊號處理器看得到這個 fd。若在寫出之前就給它，cancel 可能變成這條連線的
        // 第一行——app 會把它當成獨立的 `saymend cancel`，取消掉別人正在進行的聽寫。
        // 寫出前到寫出後之間收到的訊號，在這裡補送（此時它已是這條 dictate 連線的後續行）。
        lock.lock()
        dictateFD = fd
        if interrupted { UnixSocket.writeLine(fd, ControlRequest.cancel.encoded()) }
        lock.unlock()
        let reader = LineReader(fd: fd)
        while true {
            let line: String?
            do { line = try reader.next() } catch { return lostApp(json: json) }
            guard let line else {
                if isInterrupted { emitError(.cancelled, "已取消", json: json); return ControlExitCode.cancelled }
                return lostApp(json: json)
            }
            guard let message = try? ControlMessage.decode(line) else { continue }
            switch message {
            case .started, .partial:
                if json, !isInterrupted { output.out(message.encoded()) }
            case .final(let text, _, _):
                // 已送出取消卻先收到定稿（兩者交錯）：照取消處理——SIGINT 的語意是「丟棄」
                if isInterrupted { emitError(.cancelled, "已取消", json: json); return ControlExitCode.cancelled }
                if json { output.out(message.encoded()) } else { output.out(text) }
                return ControlExitCode.success
            case .error(let code, let msg):
                if isInterrupted { emitError(.cancelled, "已取消", json: json); return ControlExitCode.cancelled }
                emitError(code, msg, json: json)
                return code.exitCode
            default:
                continue
            }
        }
    }

    // MARK: - 共用

    /// 人讀格式：`loop=2,other=1`（依 tag 排序、只列大於 0 的）；沒有任何 tag 回 nil。
    static func presenceText(_ counts: ControlPresence.Counts) -> String? {
        let parts = counts.keys.sorted().compactMap { tag in counts[tag].flatMap { $0 > 0 ? "\(tag)=\($0)" : nil } }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    private var dictateIsActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return dictateFD != nil
    }

    private var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    private enum Reply {
        case message(ControlMessage)
        case failure(ControlErrorCode, String)
    }

    private func readReply(_ fd: Int32) -> Reply {
        let reader = LineReader(fd: fd)
        do {
            guard let line = try reader.next() else { return .failure(.notRunning, "Saymend.app 在回覆前關閉了連線") }
            do {
                return .message(try ControlMessage.decode(line))
            } catch ControlRequest.DecodeError.unsupportedVersion(let v) {
                return .failure(.unsupportedVersion, "app 回覆的協定版本 \(v.map(String.init) ?? "?") 與 CLI（v\(ControlProtocol.version)）不符")
            } catch {
                return .failure(.general, "無法解析 app 的回覆")
            }
        } catch LineReader.ReadError.timedOut {
            return .failure(.noResponse, "Saymend.app 未在 \(Int(Self.replyTimeout)) 秒內回應")
        } catch {
            return .failure(.notRunning, "與 Saymend.app 的連線中斷")
        }
    }

    private func connectFailure(_ error: Error, json: Bool) -> Int32 {
        if case UnixSocketError.notRunning = error {
            emitError(.notRunning, "Saymend.app 未執行", json: json)
            return ControlExitCode.notRunning
        }
        emitError(.general, "\(error)", json: json)
        return ControlExitCode.general
    }

    private func lostApp(json: Bool) -> Int32 {
        emitError(.notRunning, "Saymend.app 已結束或中斷了連線", json: json)
        return ControlExitCode.notRunning
    }

    private func unexpected(json: Bool) -> Int32 {
        emitError(.general, "app 回覆了非預期的訊息", json: json)
        return ControlExitCode.general
    }

    /// `--json` 時輸出一行 error 物件到 stdout（契約）；一律另寫一行人讀的訊息到 stderr。
    private func emitError(_ code: ControlErrorCode, _ message: String, json: Bool) {
        if json { output.out(ControlMessage.error(code: code, message: message).encoded()) }
        output.err("saymend: \(message)")
    }
}
