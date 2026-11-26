import Foundation

/// `saymend` 的指令。
public enum CLICommand: Equatable, Sendable {
    case status(json: Bool)
    case dictate(DictateOptions, json: Bool)
    case stop(json: Bool)
    case cancel(json: Bool)
    case events(json: Bool)
    case version(json: Bool)
    case help

    public var json: Bool {
        switch self {
        case .status(let j), .dictate(_, let j), .stop(let j), .cancel(let j), .events(let j), .version(let j): return j
        case .help: return false
        }
    }
}

/// 用法錯誤（exit 2）。`json`：命令列上有沒有 `--json`——有的話錯誤也要以 NDJSON error 物件輸出。
public struct CLIUsageError: Error, Equatable {
    public let message: String
    public let json: Bool
}

public enum CLIArguments {
    public static let usage = """
        用法：saymend <指令> [選項]

        指令：
          status [--json]                 app 狀態（state／source／modelReady）
          dictate [--json] [--max-seconds N] [--silence-ms N] [--no-speech-seconds N] [--polish]
                                          開始一段 CLI 來源的聽寫，阻塞到結束；結果只回給呼叫端、不上屏
          stop [--json]                   結束目前 CLI 聽寫並定稿
          cancel [--json]                 丟棄目前 CLI 聽寫
          events [--json]                 長駐串流所有來源的狀態變化
          --version [--json]              CLI／app／協定版本

        exit code：0 成功、1 一般錯誤、2 用法錯誤、3 app 未執行、4 忙碌／無可停的聽寫、
                   5 已取消、6 沒偵測到說話／結果為空、7 模型未就緒或逾時、8 權限不足
        """

    public static func parse(_ args: [String]) throws -> CLICommand {
        let json = args.contains("--json")
        func fail(_ message: String) -> CLIUsageError { CLIUsageError(message: message, json: json) }

        guard let first = args.first else { throw fail("缺少指令") }
        if first == "-h" || first == "--help" || first == "help" { return .help }
        if first == "--version" || first == "version" {
            try rejectUnknown(args.dropFirst(), allowed: ["--json"], fail: fail)
            return .version(json: json)
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "status":
            try rejectUnknown(rest[...], allowed: ["--json"], fail: fail)
            return .status(json: json)
        case "stop":
            try rejectUnknown(rest[...], allowed: ["--json"], fail: fail)
            return .stop(json: json)
        case "cancel":
            try rejectUnknown(rest[...], allowed: ["--json"], fail: fail)
            return .cancel(json: json)
        case "events":
            try rejectUnknown(rest[...], allowed: ["--json"], fail: fail)
            return .events(json: json)
        case "dictate":
            return .dictate(try parseDictate(rest, fail: fail), json: json)
        default:
            throw fail("未知指令：\(first)")
        }
    }

    private static func rejectUnknown(_ args: ArraySlice<String>, allowed: Set<String>,
                                      fail: (String) -> CLIUsageError) throws {
        for a in args where !allowed.contains(a) { throw fail("未知選項：\(a)") }
    }

    /// 數值選項同時接受 `--flag N` 與 `--flag=N`。
    private static func parseDictate(_ args: [String], fail: (String) -> CLIUsageError) throws -> DictateOptions {
        var o = DictateOptions()
        var i = 0
        func value(_ flag: String, inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < args.count else { throw fail("\(flag) 缺少數值") }
            return args[i]
        }
        while i < args.count {
            let raw = args[i]
            let (flag, inline): (String, String?) = {
                guard raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") else { return (raw, nil) }
                return (String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
            }()
            switch flag {
            case "--json":
                guard inline == nil else { throw fail("--json 不接受數值") }
            case "--polish":
                guard inline == nil else { throw fail("--polish 不接受數值") }
                o.polish = true
            case "--max-seconds":
                let v = try value(flag, inline: inline)
                guard let d = Double(v) else { throw fail("--max-seconds 不是數字：\(v)") }
                o.maxSeconds = d
            case "--silence-ms":
                let v = try value(flag, inline: inline)
                guard let n = Int(v) else { throw fail("--silence-ms 不是整數：\(v)") }
                o.silenceMs = n
            case "--no-speech-seconds":
                let v = try value(flag, inline: inline)
                guard let d = Double(v) else { throw fail("--no-speech-seconds 不是數字：\(v)") }
                o.noSpeechSeconds = d
            default:
                throw fail("未知選項：\(raw)")
            }
            i += 1
        }
        if let problem = o.validationError() { throw fail(problem) }
        return o
    }
}

/// CLI 自己的版本：從它所在的 app bundle 讀（`Saymend.app/Contents/Helpers/saymend` → `Contents/Info.plist`）。
/// 版本號只在 Info.plist 維護一份，CLI 與 app 不會各寫各的而飄掉。不在 bundle 裡（`swift run`）回 nil。
public enum CLIVersion {
    public static func detect(executable: URL) -> String? {
        let resolved = executable.resolvingSymlinksInPath()
        let contents = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let plist = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String else { return nil }
        return version
    }
}
