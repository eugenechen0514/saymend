import Darwin
import Foundation
import Testing
@testable import SaymendControl

/// 執行緒安全的輸出收集（runner 在背景執行緒寫）
final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var _out: [String] = []
    private var _err: [String] = []
    var out: [String] { lock.lock(); defer { lock.unlock() }; return _out }
    var err: [String] { lock.lock(); defer { lock.unlock() }; return _err }
    var output: CLIRunner.Output {
        CLIRunner.Output(out: { [self] l in lock.lock(); _out.append(l); lock.unlock() },
                         err: { [self] l in lock.lock(); _err.append(l); lock.unlock() })
    }
}

/// CLI 輸出契約（mod 逐字依賴）：以真的 socket 接上腳本化的 app 端。
@MainActor
@Suite(.serialized) struct CLIRunnerTests {
    private func withServer(_ reply: @escaping (ControlRequest) -> [ControlMessage]?,
                            _ body: (String, ScriptedHandler) async throws -> Void) async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        handler.reply = reply
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()
        defer { server.stop() }
        try await body(path, handler)
    }

    private func run(_ path: String, _ args: [String], grace: Double = 2) async -> (Int32, CapturedOutput) {
        let captured = CapturedOutput()
        let runner = CLIRunner(socketPath: path, output: captured.output, cliVersion: "1.2.3",
                               terminate: { _ in }, interruptGrace: grace)
        let code = await background { runner.run(args) }
        return (code, captured)
    }

    @Test func statusJSONMatchesTheContract() async throws {
        try await withServer({ _ in [.status(state: .recording, source: .hotkey, modelReady: true)] }) { path, _ in
            let (code, o) = await run(path, ["status", "--json"])
            #expect(code == 0)
            #expect(o.out == [#"{"v":1,"app":"running","state":"recording","source":"hotkey","modelReady":true}"#])
        }
    }

    @Test func statusWhenAppIsNotRunning() async {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (code, o) = await run(path, ["status", "--json"])
        #expect(code == 3)
        #expect(o.out == [#"{"v":1,"app":"not_running"}"#])
        let (code2, o2) = await run(path, ["dictate", "--json"])
        #expect(code2 == 3)
        #expect(o2.out == [#"{"v":1,"type":"error","code":"not_running","message":"Saymend.app 未執行"}"#])
    }

    @Test func dictateStreamsEventsAndPassesOptions() async throws {
        let final = ControlMessage.final(text: "你好。", raw: "你好", durationMs: 1500)
        try await withServer({ _ in [.started, .partial("你"), .partial("你好"), final] }) { path, handler in
            let (code, o) = await run(path, ["dictate", "--json", "--silence-ms", "1200", "--no-speech-seconds", "5"])
            #expect(code == 0)
            #expect(o.out == [#"{"v":1,"type":"started"}"#,
                              #"{"v":1,"type":"partial","text":"你"}"#,
                              #"{"v":1,"type":"partial","text":"你好"}"#,
                              #"{"v":1,"type":"final","text":"你好。","raw":"你好","durationMs":1500}"#])
            #expect(handler.requests == [.dictate(DictateOptions(silenceMs: 1200, noSpeechSeconds: 5))])
        }
    }

    @Test func dictateWithoutJSONPrintsOnlyTheFinalText() async throws {
        try await withServer({ _ in [.started, .partial("x"), .final(text: "最終文字", raw: "最終", durationMs: 1)] }) { path, _ in
            let (code, o) = await run(path, ["dictate"])
            #expect(code == 0)
            #expect(o.out == ["最終文字"])
        }
    }

    /// 每個錯誤碼都要原樣轉成 error 物件、並以契約的 exit code 結束。
    @Test func dictateErrorsMapToExitCodes() async throws {
        for code in [ControlErrorCode.busy, .cancelled, .noSpeech, .emptyResult, .modelNotReady, .timeout,
                     .permissionDenied, .asrFailed] {
            try await withServer({ _ in [.started, .error(code: code, message: "m")] }) { path, _ in
                let (exit, o) = await run(path, ["dictate", "--json"])
                #expect(exit == code.exitCode, "\(code.rawValue)")
                #expect(o.out.last == #"{"v":1,"type":"error","code":"\#(code.rawValue)","message":"m"}"#)
            }
        }
    }

    @Test func stopAndCancelReportOkOrNothingToStop() async throws {
        try await withServer({ r in r == .stop ? [.ok] : [.error(code: .nothingToStop, message: "沒有")] }) { path, _ in
            let (stopCode, s) = await run(path, ["stop", "--json"])
            #expect(stopCode == 0)
            #expect(s.out == [#"{"v":1,"type":"ok"}"#])
            let (cancelCode, c) = await run(path, ["cancel"])
            #expect(cancelCode == 4)
            #expect(c.out.isEmpty, "沒有 --json 時 stdout 不輸出錯誤物件")
            #expect(c.err.contains("saymend: 沒有"))
        }
    }

    @Test func usageErrorsExit2AndEmitJSONWhenAsked() async {
        let (code, o) = await run("/nonexistent/x.sock", ["dictate", "--json", "--max-seconds", "abc"])
        #expect(code == 2)
        #expect(o.out.count == 1)
        #expect(o.out.first?.hasPrefix(#"{"v":1,"type":"error","code":"usage""#) == true)
        #expect(o.err.filter { $0.hasPrefix("saymend:") }.count == 1, "stderr 的錯誤訊息只印一次")
        let (code2, o2) = await run("/nonexistent/x.sock", ["frobnicate"])
        #expect(code2 == 2)
        #expect(o2.out.isEmpty)
    }

    @Test func eventsStreamUntilTheAppGoesAwayThenExit3() async throws {
        let (dir, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let handler = ScriptedHandler()
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        handler.reply = { _ in [.state(state: .idle, source: nil, at: at)] }
        let server = ControlServer(socketPath: path, handler: handler)
        try server.start()

        let captured = CapturedOutput()
        let runner = CLIRunner(socketPath: path, output: captured.output, cliVersion: "1", terminate: { _ in })
        async let exit = background { runner.run(["events", "--json"]) }
        #expect(await waitUntil { handler.peers.count == 1 })
        handler.peers[0].send(.state(state: .recording, source: .cli, at: at))
        #expect(await waitUntil { captured.out.count == 2 })
        server.stop()                                   // app 結束
        #expect(await exit == 3)
        #expect(captured.out.prefix(2) == [
            #"{"v":1,"type":"state","state":"idle","source":null,"at":"2026-11-18T11:06:40.000Z"}"#,
            #"{"v":1,"type":"state","state":"recording","source":"cli","at":"2026-11-18T11:06:40.000Z"}"#,
        ])
        #expect(captured.out.last?.contains(#""code":"not_running""#) == true)
    }

    /// SIGINT：runner 在 dictate 連線上送 cancel，app 回 cancelled，exit 5。
    @Test func interruptDuringDictateAsksTheAppToCancel() async throws {
        try await withServer({ _ in [.started] }) { path, handler in
            let captured = CapturedOutput()
            let runner = CLIRunner(socketPath: path, output: captured.output, cliVersion: "1",
                                   terminate: { _ in }, interruptGrace: 30)
            async let exit = background { runner.run(["dictate", "--json"]) }
            #expect(await waitUntil { captured.out.count == 1 })   // started
            runner.interrupt()
            #expect(await waitUntil { handler.followUps == [.cancel] }, "cancel 要送在同一條 dictate 連線上")
            handler.peers[0].send(.error(code: .cancelled, message: "已取消"))
            handler.peers[0].close()
            #expect(await exit == 5)
            #expect(captured.out.last == #"{"v":1,"type":"error","code":"cancelled","message":"已取消"}"#)
        }
    }

    /// 送出取消之後才到的定稿不得印出：SIGINT 的語意是丟棄。
    @Test func finalArrivingAfterInterruptIsDiscarded() async throws {
        try await withServer({ _ in [.started] }) { path, handler in
            let captured = CapturedOutput()
            let runner = CLIRunner(socketPath: path, output: captured.output, cliVersion: "1",
                                   terminate: { _ in }, interruptGrace: 30)
            async let exit = background { runner.run(["dictate", "--json"]) }
            #expect(await waitUntil { captured.out.count == 1 })
            runner.interrupt()
            #expect(await waitUntil { handler.followUps.count == 1 })
            handler.peers[0].send(.final(text: "不該出現", raw: "x", durationMs: 1))
            handler.peers[0].close()
            #expect(await exit == 5)
            #expect(!captured.out.contains { $0.contains("不該出現") })
        }
    }

    @Test func versionWorksWithAndWithoutTheApp() async throws {
        try await withServer({ _ in [.version(app: "0.1.0")] }) { path, _ in
            let (code, o) = await run(path, ["--version", "--json"])
            #expect(code == 0)
            #expect(o.out == [#"{"v":1,"cli":"1.2.3","app":"0.1.0","protocol":1}"#])
        }
        let (code, o) = await run("/nonexistent/x.sock", ["--version"])
        #expect(code == 0)
        #expect(o.out == ["saymend CLI 1.2.3", "Saymend.app （未執行）", "protocol v1"])
    }
}
