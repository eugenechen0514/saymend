import Foundation
import Testing
@testable import SaymendCore

/// 假 runner：記錄呼叫、可鎖住（模擬慢 CLI）、腳本化結果。
actor FakeRunner: ProcessRunner {
    struct Call: Sendable {
        let executable: String, arguments: [String], stdin: String
        let workingDirectory: URL, timeout: TimeInterval
        /// run() 當下抓的快照：系統 prompt 檔內容/權限、workDir 是否存在且為空
        let sysFileContent: String?, sysFilePerms: Int?, workDirExistsEmpty: Bool, workDirPerms: Int?
    }
    private(set) var calls: [Call] = []
    var result: Result<String, Error> = .success(#"{"intent":"new_content","text":"ok"}"#)
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var blockNextCalls = false

    func setBlocking(_ b: Bool) { blockNextCalls = b }
    func setResult(_ r: Result<String, Error>) { result = r }
    func open() { waiters.forEach { $0.resume() }; waiters.removeAll() }

    func run(executable: String, arguments: [String], stdin: String,
             workingDirectory: URL, timeout: TimeInterval) async throws -> String {
        let fm = FileManager.default
        let sysPath = Self.value(after: "--system-prompt-file", in: arguments)
        let sysContent = sysPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let sysPerms = sysPath.flatMap { (try? fm.attributesOfItem(atPath: $0))?[.posixPermissions] as? Int }
        let wdEmpty = ((try? fm.contentsOfDirectory(atPath: workingDirectory.path))?.isEmpty ?? false)
        let wdPerms = (try? fm.attributesOfItem(atPath: workingDirectory.path))?[.posixPermissions] as? Int
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin,
                          workingDirectory: workingDirectory, timeout: timeout,
                          sysFileContent: sysContent, sysFilePerms: sysPerms,
                          workDirExistsEmpty: wdEmpty, workDirPerms: wdPerms))
        if blockNextCalls { await withCheckedContinuation { waiters.append($0) } }
        return try result.get()
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

private func makeProvider(_ runner: FakeRunner,
                          detection: ClaudeCLIDetection = .found(path: "/x/claude", version: "2.1.216"),
                          model: String = "sonnet") -> ClaudeCLIProvider {
    ClaudeCLIProvider(configProvider: { ClaudeCLIConfig(cliPathOverride: nil, model: model) },
                      detect: { _ in detection },
                      runner: runner)
}

@Test func hermeticArgumentsCompleteAndStdinCarriesUser() async throws {
    let r = FakeRunner()
    _ = try await makeProvider(r, model: "sonnet").complete(system: "SYS", user: "USER-PAYLOAD", timeout: 10)
    let call = await r.calls[0]
    #expect(call.executable == "/x/claude")
    #expect(call.stdin == "USER-PAYLOAD")                          // user 走 stdin、不經 argv
    let a = call.arguments
    for flag in ["--print", "--no-session-persistence"] {
        #expect(a.contains(flag), "缺 hermetic flag \(flag)")
    }
    #expect(!a.contains("--bare"), "--bare 與 OAuth 互斥（spike 定案：不得使用）")
    #expect(FakeRunner.value(after: "--settings", in: a) == #"{"disableAllHooks":true}"#)
    #expect(FakeRunner.value(after: "--tools", in: a) == "")
    #expect(FakeRunner.value(after: "--setting-sources", in: a) == "")   // 排除 user/project/local（spike 定案的關鍵救援）
    #expect(a.contains("--strict-mcp-config"), "MCP 雙保險（spike (f) 實測無異狀後加入）")
    #expect(FakeRunner.value(after: "--output-format", in: a) == "text")
    #expect(FakeRunner.value(after: "--model", in: a) == "sonnet")
    #expect(a.contains { $0.contains("SYS") } == false)            // system prompt 絕不在 argv
}

@Test func systemPromptFileLifecycle() async throws {
    let r = FakeRunner()
    _ = try await makeProvider(r).complete(system: "秘密規則", user: "u", timeout: 10)
    let call = await r.calls[0]
    #expect(call.sysFileContent == "秘密規則")                      // run 期間存在且內容正確
    #expect(call.sysFilePerms == 0o600)
    let path = FakeRunner.value(after: "--system-prompt-file", in: call.arguments)!
    #expect(!FileManager.default.fileExists(atPath: path))          // 成功路徑：用後即刪
}

@Test func tempResourcesCleanedOnRunnerThrow() async throws {
    let r = FakeRunner()
    await r.setResult(.failure(ProcessRunnerError.nonZeroExit(code: 1, stderrSummary: "x")))
    await #expect(throws: ProcessRunnerError.nonZeroExit(code: 1, stderrSummary: "x")) {
        _ = try await makeProvider(r).complete(system: "s", user: "u", timeout: 10)
    }
    let call = await r.calls[0]
    let sysPath = FakeRunner.value(after: "--system-prompt-file", in: call.arguments)!
    #expect(!FileManager.default.fileExists(atPath: sysPath))       // 失敗路徑也刪
    #expect(!FileManager.default.fileExists(atPath: call.workingDirectory.path))
}

@Test func workingDirectoryFreshPrivateUniquePerCall() async throws {
    let r = FakeRunner()
    let p = makeProvider(r)
    _ = try await p.complete(system: "s", user: "u", timeout: 10)
    _ = try await p.complete(system: "s", user: "u", timeout: 10)
    let c0 = await r.calls[0], c1 = await r.calls[1]
    #expect(c0.workDirExistsEmpty && c1.workDirExistsEmpty)         // run 期間存在且為空
    #expect(c0.workDirPerms == 0o700)
    #expect(c0.workingDirectory != c1.workingDirectory)             // 每次呼叫唯一
    #expect(!FileManager.default.fileExists(atPath: c0.workingDirectory.path))  // 用後即刪
}

@Test func cliNotFoundThrowsWithoutSpawning() async {
    let r = FakeRunner()
    let p = makeProvider(r, detection: .notFound)
    await #expect(throws: ClaudeCLIError.cliNotFound) {
        _ = try await p.complete(system: "s", user: "u", timeout: 10)
    }
    #expect(await r.calls.isEmpty)                                   // runner 未被呼叫
}

@Test func emptyStdoutThrowsEmptyResponse() async {
    let r = FakeRunner()
    await r.setResult(.success("  \n"))
    await #expect(throws: LLMError.emptyResponse) {
        _ = try await makeProvider(r).complete(system: "s", user: "u", timeout: 10)
    }
}

@Test func concurrencyCappedAtTwoWithFIFO() async throws {
    let r = FakeRunner()
    await r.setBlocking(true)
    let p = makeProvider(r)
    let t1 = Task { try await p.complete(system: "s", user: "u1", timeout: 30) }
    let t2 = Task { try await p.complete(system: "s", user: "u2", timeout: 30) }
    try await Task.sleep(for: .milliseconds(200))                    // 讓前兩個進 runner
    #expect(await r.calls.count == 2)
    let t3 = Task { try await p.complete(system: "s", user: "u3", timeout: 30) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await r.calls.count == 2)                                // 第 3 個排隊、不 spawn
    await r.setBlocking(false)
    await r.open()                                                    // 放行 → slot 釋出 → 第 3 個 spawn
    _ = try await t3.value
    #expect(await r.calls.count == 3)
    _ = try? await t1.value; _ = try? await t2.value
}

@Test func queuedCallExpiredNeverSpawns() async throws {
    let r = FakeRunner()
    await r.setBlocking(true)
    let p = makeProvider(r)
    let t1 = Task { try await p.complete(system: "s", user: "u1", timeout: 30) }
    let t2 = Task { try await p.complete(system: "s", user: "u2", timeout: 30) }
    try await Task.sleep(for: .milliseconds(200))
    let t3 = Task { try await p.complete(system: "s", user: "u3", timeout: 0.05) }  // 排隊中就會逾期
    try await Task.sleep(for: .milliseconds(300))                    // 遠超 t3 deadline
    await r.setBlocking(false)
    await r.open()                                                    // slot 釋出
    await #expect(throws: ProcessRunnerError.timedOut) { _ = try await t3.value }
    _ = try? await t1.value; _ = try? await t2.value
    #expect(await r.calls.count == 2)                                // t3 永不 spawn（無幽靈呼叫）
}

@Test func runnerReceivesRemainingBudgetNotConfiguredValue() async throws {
    let r = FakeRunner()
    _ = try await makeProvider(r).complete(system: "s", user: "u", timeout: 10)
    let got = await r.calls[0].timeout
    #expect(got > 9 && got <= 10)                                    // 無排隊：剩餘 ≈ 全額（不是 [1,120] clamp 後的值）
}
