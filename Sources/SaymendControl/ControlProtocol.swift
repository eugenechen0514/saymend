import Foundation

/// Saymend 本機控制介面的線上協定（v1）。完整契約見 `docs/control-interface.md`。
///
/// 兩層格式：
/// - **線上協定**（app ⇄ `saymend` CLI，經 unix domain socket）：本檔的 `ControlRequest`／`ControlMessage`。
/// - **CLI 輸出契約**（`saymend … --json`，給 mod 讀）：由 `CLIRunner` 從線上訊息重新組出來。
/// 兩者刻意分開：CLI 的輸出形狀是對外承諾，線上協定是內部實作，日後可以各自演進而不互相牽動。
public enum ControlProtocol {
    /// 線上協定與 CLI `--json` 輸出共用的版本號。每個 JSON 物件都帶 `"v": version`。
    public static let version = 1
    public static let socketFileName = "control.sock"
    /// 覆寫 socket 路徑（測試與除錯用）。正式使用不需要設。
    public static let socketPathEnvironmentKey = "SAYMEND_CONTROL_SOCKET"

    /// `~/Library/Application Support/Saymend`——與歷史、詞彙表同一個目錄（app 端 `AppDelegate.supportDir`）。
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Saymend", isDirectory: true)
    }

    public static func defaultSocketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        supportDirectory(home: home).appendingPathComponent(socketFileName).path
    }

    /// 環境變數有值就用它，否則預設路徑。app 與 CLI 用同一個解析，兩邊才不會各找各的。
    public static func resolvedSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[socketPathEnvironmentKey], !override.isEmpty { return override }
        return defaultSocketPath()
    }
}

/// 聽寫的對外狀態。四個值涵蓋熱鍵與 CLI 兩種來源。
public enum ControlState: String, Equatable, Sendable, CaseIterable {
    case idle
    /// 麥克風開著
    case recording
    /// 麥克風已關，辨識引擎還在處理（排空、批次上傳、等模型）
    case transcribing
    /// 辨識完成，語言模型潤飾在途
    case polishing
}

/// 目前這段聽寫是誰發起的。閒置時沒有來源（JSON 為 `null`）。
public enum ControlSource: String, Equatable, Sendable, CaseIterable {
    case hotkey
    case cli
}

/// CLI 的 exit code（契約 v1）。
public enum ControlExitCode {
    public static let success: Int32 = 0
    public static let general: Int32 = 1
    public static let usage: Int32 = 2
    public static let notRunning: Int32 = 3
    /// 忙碌（已有聽寫進行中）或沒有可停／可取消的 CLI 聽寫
    public static let busy: Int32 = 4
    public static let cancelled: Int32 = 5
    /// 沒偵測到說話，或辨識結果為空
    public static let noSpeech: Int32 = 6
    /// 模型未就緒或逾時
    public static let modelNotReady: Int32 = 7
    /// 權限不足（麥克風等）
    public static let permission: Int32 = 8
}

/// 錯誤碼：線上協定與 CLI `--json` 的 error 物件共用同一組字串。exit code 由它決定。
public enum ControlErrorCode: String, Equatable, Sendable, CaseIterable {
    case general = "error"
    case usage
    case notRunning = "not_running"
    case unsupportedVersion = "unsupported_version"
    case busy
    case nothingToStop = "nothing_to_stop"
    case cancelled
    case noSpeech = "no_speech"
    case emptyResult = "empty_result"
    case modelNotReady = "model_not_ready"
    case timeout
    case permissionDenied = "permission_denied"
    case microphoneUnavailable = "microphone_unavailable"
    case asrFailed = "asr_failed"
    /// app 沒有在時限內回應（主執行緒卡住等）。不歸 7：那是「模型」逾時，這是 app 本身沒反應。
    case noResponse = "no_response"

    public var exitCode: Int32 {
        switch self {
        case .general, .unsupportedVersion, .microphoneUnavailable, .asrFailed, .noResponse:
            return ControlExitCode.general
        case .usage: return ControlExitCode.usage
        case .notRunning: return ControlExitCode.notRunning
        case .busy, .nothingToStop: return ControlExitCode.busy
        case .cancelled: return ControlExitCode.cancelled
        case .noSpeech, .emptyResult: return ControlExitCode.noSpeech
        case .modelNotReady, .timeout: return ControlExitCode.modelNotReady
        case .permissionDenied: return ControlExitCode.permission
        }
    }
}

/// `dictate` 的參數。預設值即契約的預設值。
public struct DictateOptions: Equatable, Sendable {
    public static let defaultMaxSeconds: Double = 120
    /// 上限：一小時。比 Whisper 遠端的 10 分鐘上限寬，真正的限制由引擎自己報。
    public static let maxSecondsLimit: Double = 3600

    /// 達到即正常定稿（不是錯誤）
    public var maxSeconds: Double
    /// 偵測到說話後連續靜音達此毫秒數即定稿；0＝不啟用
    public var silenceMs: Int
    /// 開始後這麼多秒內完全沒偵測到說話即放棄（exit 6）；0＝不啟用
    public var noSpeechSeconds: Double
    /// 走設定中的 LLM provider 潤飾；預設不潤飾
    public var polish: Bool

    public init(maxSeconds: Double = DictateOptions.defaultMaxSeconds, silenceMs: Int = 0,
                noSpeechSeconds: Double = 0, polish: Bool = false) {
        self.maxSeconds = maxSeconds
        self.silenceMs = silenceMs
        self.noSpeechSeconds = noSpeechSeconds
        self.polish = polish
    }

    /// 不合法時回傳說明（給 usage 錯誤用）；合法回 nil。
    public func validationError() -> String? {
        guard maxSeconds.isFinite, maxSeconds > 0, maxSeconds <= Self.maxSecondsLimit else {
            return "--max-seconds 必須介於 0（不含）與 \(Int(Self.maxSecondsLimit)) 之間"
        }
        guard silenceMs >= 0, silenceMs <= 600_000 else { return "--silence-ms 必須介於 0 與 600000 之間" }
        guard noSpeechSeconds.isFinite, noSpeechSeconds >= 0, noSpeechSeconds <= Self.maxSecondsLimit else {
            return "--no-speech-seconds 必須介於 0 與 \(Int(Self.maxSecondsLimit)) 之間"
        }
        return nil
    }
}

/// client → app 的請求。每條連線的第一行是請求；`dictate` 連線之後還可以送 `cancel`（取消這一段）。
public enum ControlRequest: Equatable, Sendable {
    case status
    case version
    case dictate(DictateOptions)
    case stop
    case cancel
    case events

    public enum DecodeError: Error, Equatable {
        case malformed(String)
        case unsupportedVersion(Int?)
    }

    public func encoded() -> String {
        var line = JSONLine([("v", .int(ControlProtocol.version))])
        switch self {
        case .status: line.set("cmd", .string("status"))
        case .version: line.set("cmd", .string("version"))
        case .stop: line.set("cmd", .string("stop"))
        case .cancel: line.set("cmd", .string("cancel"))
        case .events: line.set("cmd", .string("events"))
        case .dictate(let o):
            line.set("cmd", .string("dictate"))
            line.set("maxSeconds", .double(o.maxSeconds))
            line.set("silenceMs", .int(o.silenceMs))
            line.set("noSpeechSeconds", .double(o.noSpeechSeconds))
            line.set("polish", .bool(o.polish))
        }
        return line.encoded()
    }

    /// 先驗版本再看指令：版本不符的請求不論內容一律拒絕（不同版本的欄位語意不保證相同）。
    public static func decode(_ text: String) throws -> ControlRequest {
        let line: JSONLine
        do { line = try JSONLine.parse(text) } catch { throw DecodeError.malformed("不是 JSON 物件") }
        guard let v = line["v"]?.intValue else { throw DecodeError.unsupportedVersion(nil) }
        guard v == ControlProtocol.version else { throw DecodeError.unsupportedVersion(v) }
        guard let cmd = line["cmd"]?.stringValue else { throw DecodeError.malformed("缺少 cmd") }
        switch cmd {
        case "status": return .status
        case "version": return .version
        case "stop": return .stop
        case "cancel": return .cancel
        case "events": return .events
        case "dictate":
            var o = DictateOptions()
            if let x = line["maxSeconds"] { guard let d = x.doubleValue else { throw DecodeError.malformed("maxSeconds 不是數字") }; o.maxSeconds = d }
            if let x = line["silenceMs"] { guard let i = x.intValue else { throw DecodeError.malformed("silenceMs 不是整數") }; o.silenceMs = i }
            if let x = line["noSpeechSeconds"] { guard let d = x.doubleValue else { throw DecodeError.malformed("noSpeechSeconds 不是數字") }; o.noSpeechSeconds = d }
            if let x = line["polish"] { guard let b = x.boolValue else { throw DecodeError.malformed("polish 不是布林值") }; o.polish = b }
            if let problem = o.validationError() { throw DecodeError.malformed(problem) }
            return .dictate(o)
        default:
            throw DecodeError.malformed("未知指令：\(cmd)")
        }
    }
}

/// app → client 的訊息。
public enum ControlMessage: Equatable, Sendable {
    case status(state: ControlState, source: ControlSource?, modelReady: Bool)
    case version(app: String)
    case started
    case partial(String)
    case final(text: String, raw: String, durationMs: Int)
    case state(state: ControlState, source: ControlSource?, at: Date)
    /// `stop`／`cancel` 成功
    case ok
    case error(code: ControlErrorCode, message: String)

    public func jsonLine() -> JSONLine {
        var line = JSONLine([("v", .int(ControlProtocol.version))])
        switch self {
        case .status(let state, let source, let modelReady):
            line.set("type", .string("status"))
            line.set("state", .string(state.rawValue))
            line.set("source", source.map { .string($0.rawValue) } ?? .null)
            line.set("modelReady", .bool(modelReady))
        case .version(let app):
            line.set("type", .string("version"))
            line.set("app", .string(app))
            line.set("protocol", .int(ControlProtocol.version))
        case .started:
            line.set("type", .string("started"))
        case .partial(let text):
            line.set("type", .string("partial"))
            line.set("text", .string(text))
        case .final(let text, let raw, let durationMs):
            line.set("type", .string("final"))
            line.set("text", .string(text))
            line.set("raw", .string(raw))
            line.set("durationMs", .int(durationMs))
        case .state(let state, let source, let at):
            line.set("type", .string("state"))
            line.set("state", .string(state.rawValue))
            line.set("source", source.map { .string($0.rawValue) } ?? .null)
            line.set("at", .string(ControlTimestamp.format(at)))
        case .ok:
            line.set("type", .string("ok"))
        case .error(let code, let message):
            line.set("type", .string("error"))
            line.set("code", .string(code.rawValue))
            line.set("message", .string(message))
        }
        return line
    }

    public func encoded() -> String { jsonLine().encoded() }

    public static func decode(_ text: String) throws -> ControlMessage {
        let line: JSONLine
        do { line = try JSONLine.parse(text) } catch { throw ControlRequest.DecodeError.malformed("不是 JSON 物件") }
        guard let v = line["v"]?.intValue else { throw ControlRequest.DecodeError.unsupportedVersion(nil) }
        guard v == ControlProtocol.version else { throw ControlRequest.DecodeError.unsupportedVersion(v) }
        func str(_ k: String) throws -> String {
            guard let s = line[k]?.stringValue else { throw ControlRequest.DecodeError.malformed("缺少 \(k)") }
            return s
        }
        func source() throws -> ControlSource? {
            switch line["source"] {
            case .null?, nil: return nil
            case .string(let s)?:
                guard let src = ControlSource(rawValue: s) else { throw ControlRequest.DecodeError.malformed("未知 source：\(s)") }
                return src
            default: throw ControlRequest.DecodeError.malformed("source 型別錯誤")
            }
        }
        func state() throws -> ControlState {
            let s = try str("state")
            guard let st = ControlState(rawValue: s) else { throw ControlRequest.DecodeError.malformed("未知 state：\(s)") }
            return st
        }
        switch try str("type") {
        case "status":
            guard let ready = line["modelReady"]?.boolValue else { throw ControlRequest.DecodeError.malformed("缺少 modelReady") }
            return .status(state: try state(), source: try source(), modelReady: ready)
        case "version":
            return .version(app: try str("app"))
        case "started":
            return .started
        case "partial":
            return .partial(try str("text"))
        case "final":
            guard let ms = line["durationMs"]?.intValue else { throw ControlRequest.DecodeError.malformed("缺少 durationMs") }
            return .final(text: try str("text"), raw: try str("raw"), durationMs: ms)
        case "state":
            guard let at = ControlTimestamp.parse(try str("at")) else { throw ControlRequest.DecodeError.malformed("at 不是 ISO 8601") }
            return .state(state: try state(), source: try source(), at: at)
        case "ok":
            return .ok
        case "error":
            let code = ControlErrorCode(rawValue: try str("code")) ?? .general   // 未知碼＝一般錯誤，不讓新版 app 的新碼炸掉舊 CLI
            return .error(code: code, message: (line["message"]?.stringValue) ?? "")
        case let other:
            throw ControlRequest.DecodeError.malformed("未知訊息類型：\(other)")
        }
    }

    /// 這則訊息之後 app 端會關閉連線（一次性請求的回覆、dictate 的終局）。
    public var isTerminal: Bool {
        switch self {
        case .status, .version, .final, .ok, .error: return true
        case .started, .partial, .state: return false
        }
    }
}

/// ISO 8601（UTC、含毫秒），例：`2026-11-26T13:20:30.123Z`。事件的先後要分得出毫秒級。
public enum ControlTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    public static func format(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}
