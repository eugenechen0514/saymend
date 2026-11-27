import Foundation

/// NDJSON 一行裡的值。只收契約用得到的型別：純量，加上巢狀物件（`presence` 的 tag → 連線數）。
/// 陣列在協定裡不存在，解析時遇到就當成沒有這個欄位（fail closed：拿不到值的欄位由呼叫端套預設或報錯）。
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    /// 巢狀物件。與最外層一樣依加入順序輸出。
    indirect case object(JSONLine)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// 整數欄位。`2.0` 這種剛好是整數的浮點數也收（JSONSerialization 對 `2.0` 會給 Double）。
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: JSONLine? {
        if case .object(let o) = self { return o }
        return nil
    }
}

/// 一個 JSON 物件，**依加入順序輸出**。
///
/// 為什麼不用 `JSONEncoder`：它不保證鍵的順序（`.sortedKeys` 又會把 `"v"` 排到 `"app"` 後面）。
/// 契約範例一律把 `"v"` 放第一個，人眼掃 log 與 mod 端的 grep 都依賴這個形狀；
/// 順序在 JSON 語意上無關，但沒有理由讓它飄。
public struct JSONLine: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: JSONValue
    }

    public private(set) var fields: [Field] = []

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { set(k, v) }
    }

    /// 同名鍵以後寫為準、保留第一次出現的位置。
    public mutating func set(_ key: String, _ value: JSONValue) {
        if let i = fields.firstIndex(where: { $0.key == key }) {
            fields[i] = Field(key: key, value: value)
        } else {
            fields.append(Field(key: key, value: value))
        }
    }

    public subscript(key: String) -> JSONValue? {
        fields.first(where: { $0.key == key })?.value
    }

    /// 單行、不含結尾換行。字串照 RFC 8259 跳脫（控制字元一律跳脫，非 ASCII 原樣輸出 UTF-8）——
    /// 換行絕不會出現在輸出裡，NDJSON 的「一行一個物件」因此由構造保證。
    public func encoded() -> String {
        var out = "{"
        for (i, f) in fields.enumerated() {
            if i > 0 { out += "," }
            out += Self.quote(f.key)
            out += ":"
            out += Self.encode(f.value)
        }
        out += "}"
        return out
    }

    public enum ParseError: Error, Equatable {
        case notJSONObject
    }

    /// 解析一行。最外層必須是物件；巢狀物件解成 `.object`，陣列略過（見 `JSONValue`）。
    public static func parse(_ line: String) throws -> JSONLine {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            throw ParseError.notJSONObject
        }
        return Self.object(from: dict)
    }

    private static func object(from dict: [String: Any]) -> JSONLine {
        var result = JSONLine()
        // 字典沒有順序；依鍵排序只為了讓解析結果可重現（測試比對用），不代表線上順序。
        for key in dict.keys.sorted() {
            if let v = Self.value(from: dict[key] as Any) { result.set(key, v) }
        }
        return result
    }

    private static func value(from any: Any) -> JSONValue? {
        switch any {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let d as [String: Any]:
            return .object(Self.object(from: d))
        case let n as NSNumber:
            // NSNumber 同時裝 Bool 與數字：只能看底層型別判別，否則 `true` 會變成 1。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        default:
            return nil
        }
    }

    private static func encode(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .int(let i): return String(i)
        case .double(let d):
            guard d.isFinite else { return "null" }   // JSON 沒有 NaN／Infinity
            return d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object(let o): return o.encoded()
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            // U+2028／U+2029 在 JSON 合法，但部分 JavaScript 解析器會把它們當成行尾——一併跳脫最穩。
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
