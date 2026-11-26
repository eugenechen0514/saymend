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
        let line = try JSONLine.parse(#"{"a":true,"b":1,"c":1.5,"d":null,"e":"x","f":{"nested":1}}"#)
        #expect(line["a"] == .bool(true))
        #expect(line["b"] == .int(1))
        #expect(line["c"] == .double(1.5))
        #expect(line["d"] == .null)
        #expect(line["e"] == .string("x"))
        #expect(line["f"] == nil, "巢狀物件不在協定裡，當成沒有這個欄位")
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
            .status, .version, .stop, .cancel, .events,
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
            (.state(state: .recording, source: .hotkey, at: at),
             #"{"v":1,"type":"state","state":"recording","source":"hotkey","at":"2026-11-18T11:06:40.123Z"}"#),
            (.state(state: .idle, source: nil, at: at),
             #"{"v":1,"type":"state","state":"idle","source":null,"at":"2026-11-18T11:06:40.123Z"}"#),
            (.error(code: .busy, message: "忙"), #"{"v":1,"type":"error","code":"busy","message":"忙"}"#),
            (.ok, #"{"v":1,"type":"ok"}"#),
            (.status(state: .polishing, source: .cli, modelReady: false),
             #"{"v":1,"type":"status","state":"polishing","source":"cli","modelReady":false}"#),
            (.version(app: "0.1.0"), #"{"v":1,"type":"version","app":"0.1.0","protocol":1}"#),
        ]
        for (message, expected) in cases {
            #expect(message.encoded() == expected)
            #expect((try? ControlMessage.decode(expected)) == message, "\(expected) 要能解回同一則訊息")
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
        #expect(try CLIArguments.parse(["events", "--json"]) == .events(json: true))
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
