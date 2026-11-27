import Foundation
import Testing
@testable import SaymendControl

/// 線上協定與 CLI 輸出契約的字面形狀。mod 端是逐字依賴這些字串的，這裡一律比對完整字串，不比對解析後的值。
@Suite struct JSONLineTests {
    @Test func encodesFieldsInInsertionOrderWithVersionFirst() {
        let line = JSONLine([("v", .int(1)), ("app", .string("running")), ("source", .null), ("modelReady", .bool(true))])
        #expect(line.encoded() == #"{"v":1,"app":"running","source":null,"modelReady":true}"#)
    }

    @Test func escapesEverythingThatCouldBreakALine() {
        let line = JSONLine([("text", .string("a\"b\\c\nd\re\tf\u{01}g\u{2028}h"))])
        #expect(line.encoded() == #"{"text":"a\"b\\c\nd\re\tf\u0001g"# + "\\u2028" + #"h"}"#)
        #expect(!line.encoded().contains("\n"), "NDJSON：輸出不得含真正的換行")
    }

    @Test func keepsNonASCIIAsUTF8() {
        #expect(JSONLine([("text", .string("繁體中文 OK"))]).encoded() == #"{"text":"繁體中文 OK"}"#)
    }

    @Test func parseDistinguishesBoolFromNumber() throws {
        let line = try JSONLine.parse(#"{"a":true,"b":1,"c":1.5,"d":null,"e":"x","f":{"nested":1},"g":[1,2]}"#)
        #expect(line["a"] == .bool(true))
        #expect(line["b"] == .int(1))
        #expect(line["c"] == .double(1.5))
        #expect(line["d"] == .null)
        #expect(line["e"] == .string("x"))
        #expect(line["f"] == .object(JSONLine([("nested", .int(1))])), "巢狀物件（presence 用）解成 .object")
        #expect(line["g"] == nil, "陣列不在協定裡，當成沒有這個欄位")
    }

    @Test func nestedObjectsEncodeInInsertionOrder() {
        let line = JSONLine([("v", .int(1)), ("presence", .object(JSONLine([("loop", .int(2)), ("a", .int(1))]))),
                             ("empty", .object(JSONLine()))])
        #expect(line.encoded() == #"{"v":1,"presence":{"loop":2,"a":1},"empty":{}}"#)
    }

    @Test func parseRejectsNonObjects() {
        #expect(throws: JSONLine.ParseError.notJSONObject) { try JSONLine.parse("[1,2]") }
        #expect(throws: JSONLine.ParseError.notJSONObject) { try JSONLine.parse("not json") }
    }

    @Test func integralDoublesEncodeWithoutFraction() {
        #expect(JSONLine([("n", .double(120))]).encoded() == #"{"n":120}"#)
        #expect(JSONLine([("n", .double(1.5))]).encoded() == #"{"n":1.5}"#)
        #expect(JSONLine([("n", .double(.nan))]).encoded() == #"{"n":null}"#)
    }
}

@Suite struct ControlProtocolTests {
    @Test func everyRequestRoundTrips() throws {
        let requests: [ControlRequest] = [
            .status, .version, .stop, .cancel, .events(presence: nil), .events(presence: "loop"),
            .dictate(DictateOptions()),
            .dictate(DictateOptions(maxSeconds: 30.5, silenceMs: 1200, noSpeechSeconds: 8, polish: true)),
        ]
        for r in requests {
            #expect(try ControlRequest.decode(r.encoded()) == r)
        }
    }

    @Test func dictateDefaultsMatchTheContract() throws {
        guard case .dictate(let o) = try ControlRequest.decode(#"{"v":1,"cmd":"dictate"}"#) else {
            Issue.record("不是 dictate"); return
        }
        #expect(o.maxSeconds == 120)
        #expect(o.silenceMs == 0)
        #expect(o.noSpeechSeconds == 0)
        #expect(o.polish == false)
    }

    @Test func versionIsCheckedBeforeAnythingElse() {
        #expect(throws: ControlRequest.DecodeError.unsupportedVersion(2)) {
            try ControlRequest.decode(#"{"v":2,"cmd":"status"}"#)
        }
        #expect(throws: ControlRequest.DecodeError.unsupportedVersion(nil)) {
            try ControlRequest.decode(#"{"cmd":"status"}"#)
        }
        #expect(throws: ControlRequest.DecodeError.unsupportedVersion(2)) {
            try ControlRequest.decode(#"{"v":2,"cmd":"bogus"}"#)
        }
    }

    @Test func malformedRequestsAreRejected() {
        for text in [#"{"v":1}"#, #"{"v":1,"cmd":"bogus"}"#,
                     #"{"v":1,"cmd":"dictate","maxSeconds":0}"#,
                     #"{"v":1,"cmd":"dictate","maxSeconds":"x"}"#,
                     #"{"v":1,"cmd":"dictate","silenceMs":-1}"#,
                     #"{"v":1,"cmd":"dictate","silenceMs":1.5}"#,
                     #"{"v":1,"cmd":"dictate","polish":1}"#,
                     "garbage"] {
            #expect(throws: ControlRequest.DecodeError.self, "\(text)") { try ControlRequest.decode(text) }
        }
    }

    @Test func messagesEncodeToTheExactContractShape() {
        let at = Date(timeIntervalSince1970: 1_795_000_000.123)
        let cases: [(ControlMessage, String)] = [
            (.started, #"{"v":1,"type":"started"}"#),
            (.partial("你好"), #"{"v":1,"type":"partial","text":"你好"}"#),
            (.final(text: "你好。", raw: "你好", durationMs: 1234),
             #"{"v":1,"type":"final","text":"你好。","raw":"你好","durationMs":1234}"#),
            (.state(state: .recording, source: .hotkey, presence: [:], at: at),
             #"{"v":1,"type":"state","state":"recording","source":"hotkey","presence":{},"at":"2026-11-18T11:06:40.123Z"}"#),
            (.state(state: .idle, source: nil, presence: ["loop": 2], at: at),
             #"{"v":1,"type":"state","state":"idle","source":null,"presence":{"loop":2},"at":"2026-11-18T11:06:40.123Z"}"#),
            // 舊版 app（0.1.0）不送 presence：解成 nil，再編回去也不出現這個欄位
            (.state(state: .idle, source: nil, presence: nil, at: at),
             #"{"v":1,"type":"state","state":"idle","source":null,"at":"2026-11-18T11:06:40.123Z"}"#),
            (.error(code: .busy, message: "忙"), #"{"v":1,"type":"error","code":"busy","message":"忙"}"#),
            (.ok, #"{"v":1,"type":"ok"}"#),
            (.status(state: .polishing, source: .cli, modelReady: false, presence: [:]),
             #"{"v":1,"type":"status","state":"polishing","source":"cli","modelReady":false,"presence":{}}"#),
            (.status(state: .idle, source: nil, modelReady: true, presence: ["loop": 1]),
             #"{"v":1,"type":"status","state":"idle","source":null,"modelReady":true,"presence":{"loop":1}}"#),
            (.status(state: .idle, source: nil, modelReady: true, presence: nil),
             #"{"v":1,"type":"status","state":"idle","source":null,"modelReady":true}"#),
            (.version(app: "0.1.0"), #"{"v":1,"type":"version","app":"0.1.0","protocol":1}"#),
        ]
        for (message, expected) in cases {
            #expect(message.encoded() == expected)
            #expect((try? ControlMessage.decode(expected)) == message, "\(expected) 要能解回同一則訊息")
        }
    }

    // MARK: - presence

    @Test func eventsRequestCarriesPresenceOnlyWhenDeclared() throws {
        #expect(ControlRequest.events(presence: nil).encoded() == #"{"v":1,"cmd":"events"}"#)
        #expect(ControlRequest.events(presence: "loop").encoded() == #"{"v":1,"cmd":"events","presence":"loop"}"#)
        #expect(try ControlRequest.decode(#"{"v":1,"cmd":"events"}"#) == .events(presence: nil))
        #expect(try ControlRequest.decode(#"{"v":1,"cmd":"events","presence":null}"#) == .events(presence: nil))
        #expect(try ControlRequest.decode(#"{"v":1,"cmd":"events","presence":"a-b_9"}"#) == .events(presence: "a-b_9"))
        let longest = String(repeating: "x", count: 32)
        #expect(try ControlRequest.decode(#"{"v":1,"cmd":"events","presence":"\#(longest)"}"#) == .events(presence: longest))
    }

    @Test func invalidPresenceInTheRequestIsMalformed() {
        let tooLong = String(repeating: "x", count: 33)
        for value in [#""""#, #""LOOP""#, #""a b""#, #""迴圈""#, #""a.b""#, #""a/b""#, "\"\(tooLong)\"",
                      "1", "true", #"{"loop":1}"#] {
            let text = #"{"v":1,"cmd":"events","presence":"# + value + "}"
            #expect(throws: ControlRequest.DecodeError.self, "\(text)") { try ControlRequest.decode(text) }
        }
    }

    @Test func tagCharsetIsLowercaseDigitsUnderscoreAndDash() {
        for ok in ["loop", "a", "0", "_", "-", "a-b_c9", String(repeating: "z", count: 32)] {
            #expect(ControlPresence.isValidTag(ok), "\(ok)")
        }
        for bad in ["", "Loop", "a b", "a.b", "ä", "迴圈", "a\n", String(repeating: "z", count: 33)] {
            #expect(!ControlPresence.isValidTag(bad), "\(bad)")
        }
    }

    /// 只列數量大於 0 的 tag、依 tag 排序（輸出可重現）
    @Test func presenceListsOnlyPositiveCountsSortedByTag() {
        let at = Date(timeIntervalSince1970: 1_795_000_000.123)
        let m = ControlMessage.state(state: .idle, source: nil, presence: ["zeta": 1, "loop": 2, "gone": 0], at: at)
        #expect(m.encoded()
                == #"{"v":1,"type":"state","state":"idle","source":null,"presence":{"loop":2,"zeta":1},"at":"2026-11-18T11:06:40.123Z"}"#)
        #expect(ControlPresence.jsonValue(["gone": 0]) == .object(JSONLine()))
    }

    @Test func malformedPresenceInMessagesIsRejected() {
        for presence in [#""loop""#, #"{"loop":"2"}"#, #"{"loop":1.5}"#, "1"] {
            let state = #"{"v":1,"type":"state","state":"idle","source":null,"presence":"# + presence
                + #","at":"2026-11-18T11:06:40.123Z"}"#
            #expect(throws: ControlRequest.DecodeError.self, "\(state)") { try ControlMessage.decode(state) }
            let status = #"{"v":1,"type":"status","state":"idle","source":null,"modelReady":true,"presence":"# + presence + "}"
            #expect(throws: ControlRequest.DecodeError.self, "\(status)") { try ControlMessage.decode(status) }
        }
    }

    @Test func unknownErrorCodesDegradeToGeneral() throws {
        let m = try ControlMessage.decode(#"{"v":1,"type":"error","code":"from_the_future","message":"x"}"#)
        #expect(m == .error(code: .general, message: "x"))
    }

    /// 契約 v1 的 exit code 表，逐項寫死（不從實作推導）。
    @Test func errorCodesMapToContractExitCodes() {
        let table: [ControlErrorCode: Int32] = [
            .general: 1, .usage: 2, .notRunning: 3, .unsupportedVersion: 1,
            .busy: 4, .nothingToStop: 4, .cancelled: 5, .noSpeech: 6, .emptyResult: 6,
            .modelNotReady: 7, .timeout: 7, .permissionDenied: 8,
            .microphoneUnavailable: 1, .asrFailed: 1, .noResponse: 1,
        ]
        #expect(Set(table.keys) == Set(ControlErrorCode.allCases), "新增錯誤碼時要回來補這張表")
        for (code, exit) in table { #expect(code.exitCode == exit, "\(code.rawValue)") }
    }

    @Test func defaultSocketPathLivesInSaymendSupportDirectory() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ControlProtocol.defaultSocketPath(home: home)
                == "/Users/someone/Library/Application Support/Saymend/control.sock")
        #expect(ControlProtocol.resolvedSocketPath(environment: ["SAYMEND_CONTROL_SOCKET": "/x/y.sock"]) == "/x/y.sock")
    }
}

@Suite struct CLIArgumentsTests {
    @Test func parsesEveryCommand() throws {
        #expect(try CLIArguments.parse(["status", "--json"]) == .status(json: true))
        #expect(try CLIArguments.parse(["status"]) == .status(json: false))
        #expect(try CLIArguments.parse(["stop"]) == .stop(json: false))
        #expect(try CLIArguments.parse(["cancel", "--json"]) == .cancel(json: true))
        #expect(try CLIArguments.parse(["events", "--json"]) == .events(presence: nil, json: true))
        #expect(try CLIArguments.parse(["events"]) == .events(presence: nil, json: false))
        #expect(try CLIArguments.parse(["--version"]) == .version(json: false))
        #expect(try CLIArguments.parse(["--version", "--json"]) == .version(json: true))
        #expect(try CLIArguments.parse(["--help"]) == .help)
        #expect(try CLIArguments.parse(["dictate", "--json"]) == .dictate(DictateOptions(), json: true))
    }

    @Test func parsesDictateFlagsInBothForms() throws {
        let expected = DictateOptions(maxSeconds: 30, silenceMs: 1200, noSpeechSeconds: 8, polish: true)
        #expect(try CLIArguments.parse(["dictate", "--json", "--max-seconds", "30", "--silence-ms", "1200",
                                        "--no-speech-seconds", "8", "--polish"]) == .dictate(expected, json: true))
        #expect(try CLIArguments.parse(["dictate", "--max-seconds=30", "--silence-ms=1200",
                                        "--no-speech-seconds=8", "--polish"]) == .dictate(expected, json: false))
    }

    @Test func parsesEventsPresenceInBothFormsAndAnyOrder() throws {
        let expected = CLICommand.events(presence: "loop", json: true)
        #expect(try CLIArguments.parse(["events", "--json", "--presence", "loop"]) == expected)
        #expect(try CLIArguments.parse(["events", "--presence", "loop", "--json"]) == expected)
        #expect(try CLIArguments.parse(["events", "--presence=loop", "--json"]) == expected)
        #expect(try CLIArguments.parse(["events", "--presence", "a-b_9"]) == .events(presence: "a-b_9", json: false))
        #expect(try CLIArguments.parse(["events", "--presence=-x"]) == .events(presence: "-x", json: false),
                "= 形式的 tag 可以以 - 開頭（字元集允許）")
    }

    /// 不合法的 tag 一律是用法錯誤（exit 2）——mod 靠這點判斷舊版 CLI 以外的錯誤，也靠它在舊版 CLI 上退回
    @Test func invalidPresenceIsAUsageError() {
        let bad: [[String]] = [
            ["events", "--presence"], ["events", "--presence", "LOOP"], ["events", "--presence", ""],
            ["events", "--presence="], ["events", "--presence", String(repeating: "x", count: 33)],
            ["events", "--presence", "a b"], ["events", "--presence", "迴圈"],
            ["events", "--presence", "--json"],                       // 漏了 tag：`--json` 不得被當成 tag
            ["events", "--presence", "loop", "--presence", "other"],  // 一條連線只宣告一個 tag
            ["events", "--presence", "loop", "extra"], ["events", "--verbose"],
            ["status", "--presence", "loop"],                         // 只有 events 收 --presence
            ["dictate", "--presence", "loop"],
        ]
        for args in bad {
            #expect(throws: CLIUsageError.self, "\(args)") { try CLIArguments.parse(args) }
        }
        do {
            _ = try CLIArguments.parse(["events", "--json", "--presence", "BAD"])
            Issue.record("應該丟用法錯誤")
        } catch let e as CLIUsageError {
            #expect(e.json)
        } catch {
            Issue.record("錯誤型別不對：\(error)")
        }
    }

    @Test func usageErrorsRememberWhetherJSONWasAsked() {
        let bad: [[String]] = [
            [], ["bogus"], ["status", "--verbose"], ["dictate", "--max-seconds"], ["dictate", "--max-seconds", "x"],
            ["dictate", "--max-seconds", "0"], ["dictate", "--silence-ms", "1.5"], ["dictate", "--silence-ms", "-5"],
            ["dictate", "--no-speech-seconds", "-1"], ["dictate", "--polish=yes"], ["dictate", "--frobnicate"],
        ]
        for args in bad {
            #expect(throws: CLIUsageError.self, "\(args)") { try CLIArguments.parse(args) }
        }
        do {
            _ = try CLIArguments.parse(["dictate", "--json", "--max-seconds", "x"])
            Issue.record("應該丟用法錯誤")
        } catch let e as CLIUsageError {
            #expect(e.json, "有 --json 時錯誤也要以 NDJSON 輸出")
        } catch {
            Issue.record("錯誤型別不對：\(error)")
        }
    }

    @Test func versionIsReadFromTheEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saymend-cli-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Saymend.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("Saymend.app/Contents/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9.8.7"],
                                                      format: .xml, options: 0)
        try data.write(to: plist)
        let exe = helpers.appendingPathComponent("saymend")
        try Data().write(to: exe)
        // 經 symlink 呼叫（~/.local/bin/saymend）也要找得到所在的 bundle
        let link = root.appendingPathComponent("saymend-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
        #expect(CLIVersion.detect(executable: exe) == "9.8.7")
        #expect(CLIVersion.detect(executable: link) == "9.8.7")
        #expect(CLIVersion.detect(executable: root.appendingPathComponent("nowhere/saymend")) == nil)
    }
}
