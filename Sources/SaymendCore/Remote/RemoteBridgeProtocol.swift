import Foundation
import SaymendControl

/// 遠端橋接的線上格式（docs/remote.md）。另一端是遠端的 client（`Resources/remote/saymend_remote.py`），
/// 改格式時兩邊要一起改：
///
/// - 請求（第一行）：`{"v":1,"cmd":"saymend","args":[…]}` 或 `{"v":1,"cmd":"say","voice":"…","text":"…"}`
/// - 回覆（多行）：`{"out":"…"}`、`{"err":"…"}`，最後一行 `{"exit":N}`
/// - client 中途關閉連線＝取消：Mac 上對應的聽寫丟棄、麥克風關閉。
public enum RemoteBridgeProtocol {
    public static let version = 1
    /// 請求那一行的長度上限（位元組）
    public static let maxRequestBytes = 256 * 1024
    /// 一次朗讀最多幾個字元，超過就截掉
    public static let maxSayCharacters = 8000
    /// 只放行 saymend-voice 會用到的子指令
    public static let subcommands = ["status", "dictate", "stop", "cancel", "events", "--version"]
    /// 只有 dictate 收、後面要帶數字的參數
    static let dictateValueFlags: Set<String> = ["--max-seconds", "--silence-ms", "--no-speech-seconds"]

    /// 檢查要交給 saymend CLI 的參數；不接受就回傳原因。
    /// 只放行 saymend-voice mod 會用到的子指令與參數；數字只收 ASCII（`١٢` 這類其他文字的數字一律拒絕）。
    public static func validateSaymendArgs(_ args: [String]) -> String? {
        guard let first = args.first, subcommands.contains(first) else {
            return "只接受這些子指令：\(subcommands.joined(separator: "、"))"
        }
        let isDictate = first == "dictate"
        let isEvents = first == "events"
        let rest = Array(args.dropFirst())
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            index += 1
            if arg == "--json" { continue }
            if isDictate && arg == "--polish" { continue }
            let (name, inlineValue): (String, String?) = {
                guard let eq = arg.firstIndex(of: "=") else { return (arg, nil) }
                return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
            }()
            if isEvents && name == "--presence" {
                var value = inlineValue
                if value == nil {
                    guard index < rest.count else { return "--presence 後面要有 tag" }
                    value = rest[index]
                    index += 1
                }
                guard let tag = value, ControlPresence.isValidTag(tag) else { return "--presence 的 tag 不合法" }
                continue
            }
            if isDictate && dictateValueFlags.contains(name) {
                var value = inlineValue
                if value == nil {
                    guard index < rest.count else { return "\(name) 後面要有數字" }
                    value = rest[index]
                    index += 1
                }
                guard let number = value, isPlainNumber(number) else { return "\(name) 的值必須是數字" }
                continue
            }
            return "不接受的參數：\(arg)"
        }
        return nil
    }

    /// `^[0-9]+(\.[0-9]+)?$`
    static func isPlainNumber(_ s: String) -> Bool {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { $0.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } }
    }

    /// 系統語音名稱：字母、數字、底線、空白與 `.()-`，1～64 字，不能以 `-` 開頭（才不會被 `say` 當成選項）。
    public static func isValidVoice(_ voice: String) -> Bool {
        guard (1...64).contains(voice.count), !voice.hasPrefix("-") else { return false }
        return voice.unicodeScalars.allSatisfy { s in
            CharacterSet.alphanumerics.contains(s) || " _.()-".unicodeScalars.contains(s)
        }
    }
}

/// 一個已通過檢查的請求。
public enum RemoteBridgeRequest: Equatable, Sendable {
    /// 交給 saymend CLI 的參數（已過白名單）
    case saymend(args: [String])
    /// 交給 `say` 的文字（已截到上限）與語音
    case say(text: String, voice: String?)

    /// 解析第一行。不接受就回傳原因（會原樣回給 client，所以要寫得讓人看得懂）。
    public static func parse(_ line: Data) -> Result<RemoteBridgeRequest, Rejection> {
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let dict = object as? [String: Any] else {
            return .failure(Rejection("請求不是 JSON 物件"))
        }
        // NSNumber 同時裝 Bool 與數字：`true` 不能被當成 1
        guard let v = dict["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(),
              v.doubleValue == Double(RemoteBridgeProtocol.version) else {
            return .failure(Rejection("版本不符（這個橋接是 v\(RemoteBridgeProtocol.version)）：請在 Saymend 的「遠端」設定重新連線，更新遠端的 client"))
        }
        switch dict["cmd"] as? String {
        case "saymend":
            guard let raw = dict["args"] as? [Any], let args = raw as? [String],
                  raw.allSatisfy({ $0 is String }) else {
                return .failure(Rejection("args 必須是字串陣列"))
            }
            if let reason = RemoteBridgeProtocol.validateSaymendArgs(args) { return .failure(Rejection(reason)) }
            return .success(.saymend(args: args))
        case "say":
            guard let text = dict["text"] as? String else { return .failure(Rejection("text 必須是字串")) }
            var voice: String?
            switch dict["voice"] {
            case nil, is NSNull: voice = nil
            case let s as String:
                guard RemoteBridgeProtocol.isValidVoice(s) else { return .failure(Rejection("語音名稱不合法")) }
                voice = s
            default:
                return .failure(Rejection("語音名稱不合法"))
            }
            return .success(.say(text: String(text.prefix(RemoteBridgeProtocol.maxSayCharacters)), voice: voice))
        default:
            return .failure(Rejection("不認得的 cmd"))
        }
    }

    /// 紀錄用的摘要：只有指令名稱與字數，**不含聽寫或朗讀的內容**。
    public var logSummary: String {
        switch self {
        case .saymend(let args): return "saymend \(args.first ?? "")"
        case .say(let text, _): return "say（\(text.count) 字）"
        }
    }

    public struct Rejection: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }
}

/// 回覆的一行。
public enum RemoteBridgeFrame: Equatable, Sendable {
    case out(String)
    case err(String)
    case exit(Int32)

    public func encoded() -> String {
        switch self {
        case .out(let s): return JSONLine([("out", .string(s))]).encoded()
        case .err(let s): return JSONLine([("err", .string(s))]).encoded()
        case .exit(let code): return JSONLine([("exit", .int(Int(code)))]).encoded()
        }
    }
}
