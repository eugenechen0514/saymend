import Foundation
import Testing
@testable import SaymendCore

/// Live runner 真 process 測試（spec §4.3）：假 runner 證不了 process 真被終止／pipe 真被排空。
private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("saymend-prt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private actor ExitWaitSpy {
    private var outcomes: [LiveProcessRunner.ExitWaitOutcome]
    private var limits: [Duration] = []

    init(outcomes: [LiveProcessRunner.ExitWaitOutcome]) { self.outcomes = outcomes }

    func next(limit: Duration) -> LiveProcessRunner.ExitWaitOutcome {
        limits.append(limit)
        return outcomes.isEmpty ? .timedOut : outcomes.removeFirst()
    }

    func snapshot() -> [Duration] { limits }
}

@Test func liveExitEventWaitReturnsWhenHandlerNeverFires() async {
    // deterministic 模擬 callback delivery 壞掉：waiter 只 suspension，不會像 waitUntilExit()
    // 永久佔住 executor thread；呼叫端仍須在自己的上限內返回。
    let signal = LiveProcessRunner.ExitSignal()
    let start = ContinuousClock.now
    let outcome = await LiveProcessRunner.awaitExit(limit: .milliseconds(50), signal: signal)
    #expect(outcome == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test func liveTerminationHandlerPublishesStatusWithoutWaitUntilExit() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exit 7"]
    let signal = LiveProcessRunner.installTerminationHandler(on: process)
    try process.run()

    let outcome = await LiveProcessRunner.awaitExit(limit: .seconds(1), signal: signal)
    #expect(outcome == .exited(.init(status: 7)))
}

@Test func liveWaitOrKillRoutesNormalAndTimeoutPathsThroughExitHook() async {
    // 第一個 outcome 走正常結束；後三個依序走 execution timeout、TERM grace timeout、
    // SIGKILL 後收到 exit event。用未 launch 的 Process 避免 spy 測試真的送 signal。
    let spy = ExitWaitSpy(outcomes: [
        .exited(.init(status: 0)),
        .timedOut, .timedOut, .exited(.init(status: SIGKILL)),
    ])
    let wait: LiveProcessRunner.ExitWait = { limit, _ in await spy.next(limit: limit) }

    let normal = await LiveProcessRunner.waitOrKill(
        Process(), exitSignal: .init(), timeout: 2, wait: wait)
    #expect(normal == .exited(.init(status: 0)))
    let callsAfterNormalExit = await spy.snapshot()
    #expect(callsAfterNormalExit == [.seconds(2)])

    let timeout = await LiveProcessRunner.waitOrKill(
        Process(), exitSignal: .init(), timeout: 2, wait: wait)
    #expect(timeout == .timedOut)
    let callsAfterBothPaths = await spy.snapshot()
    #expect(callsAfterBothPaths == [
        .seconds(2),
        .seconds(2), .milliseconds(500), .seconds(1),
    ])
}

@Test func livePipesDrainConcurrentlyWithoutDeadlock() async throws {
    // stdout 與 stderr 各 1.2MB；未並行排空會塞滿 64KB pipe 而死鎖（→ 被 30s timeout 殺掉、測試失敗而非卡死）
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let script = "dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\\0' 'a'; " +
                 "dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\\0' 'b' 1>&2"
    let out = try await LiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", script],
                                                stdin: "", workingDirectory: dir, timeout: 30)
    #expect(out.utf8.count == 1_228_800)
    #expect(out.allSatisfy { $0 == "a" })
}

@Test func liveTimeoutKillsProcessAndLeavesNoOrphan() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    // 唯一時長（每次執行不同）＋ pgrep -fx 精確全 argv 匹配：
    // -f 子字串匹配會咬中任何 argv 恰含該字串的無關 process（實測連 leader 的
    // maestri ask 提醒訊息都中——自指涉 heisenbug）；-fx 需整條 argv 完全相等、
    // 唯一時長再關掉「平行執行恰好同 argv」的殘餘窗口。
    let duration = "87.\(UInt32.random(in: 100_000...999_999))"
    let start = ContinuousClock.now
    await #expect(throws: ProcessRunnerError.timedOut) {
        _ = try await LiveProcessRunner().run(executable: "/bin/sleep", arguments: [duration],
                                              stdin: "", workingDirectory: dir, timeout: 0.2)
    }
    #expect(ContinuousClock.now - start < .seconds(5))            // 不等 87 秒
    // 無殘留：pgrep -fx 查無該唯一 argv（無匹配時 exit 1 → nonZeroExit）
    do {
        _ = try await LiveProcessRunner().run(executable: "/usr/bin/pgrep",
                                              arguments: ["-fx", "/bin/sleep \(duration)"],
                                              stdin: "", workingDirectory: dir, timeout: 5)
        Issue.record("sleep \(duration) 應已被終止，pgrep 不該找到")
    } catch let e as ProcessRunnerError {
        guard case .nonZeroExit = e else { Issue.record("預期 nonZeroExit，得到 \(e)"); return }
    }
}

@Test func liveNonZeroExitCarriesStderrSummary() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    do {
        _ = try await LiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "echo boom 1>&2; exit 3"],
                                              stdin: "", workingDirectory: dir, timeout: 10)
        Issue.record("應該 throw")
    } catch let e as ProcessRunnerError {
        guard case .nonZeroExit(let code, let summary) = e else { Issue.record("預期 nonZeroExit"); return }
        #expect(code == 3)
        #expect(summary.contains("boom"))
    }
}

@Test func liveRunsAreReentrant() async throws {
    // 並行 3 次、各自獨立 process/pipe（runner 不得持有共享 process 狀態）
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let outs = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<3 {
            group.addTask {
                try await LiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "sleep 0.1; echo ok-$$"],
                                                  stdin: "", workingDirectory: dir, timeout: 10)
            }
        }
        var r: [String] = []; for try await o in group { r.append(o.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r
    }
    #expect(outs.count == 3)
    #expect(Set(outs).count == 3)                                  // 三個不同 pid → 三個不同 process
}

@Test func liveHonorsWorkingDirectory() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let out = try await LiveProcessRunner().run(executable: "/bin/pwd", arguments: [],
                                                stdin: "", workingDirectory: dir, timeout: 10)
    let got = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
    #expect(got == dir.resolvingSymlinksInPath())                  // macOS /tmp → /private/tmp，兩邊都 resolve
    #expect(got.resolvingSymlinksInPath() != URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath())
}

@Test func liveStdinReachesChild() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let out = try await LiveProcessRunner().run(executable: "/bin/cat", arguments: [],
                                                stdin: "hello-stdin", workingDirectory: dir, timeout: 10)
    #expect(out == "hello-stdin")
}

@Test func liveRejectsNonPositiveOrNonFiniteBudget() async throws {
    // runner 邊界防禦（spec §5）：budget ≤0 或非有限＝已逾期，不 spawn 直接 timedOut
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: ProcessRunnerError.timedOut) {
        _ = try await LiveProcessRunner().run(executable: "/bin/echo", arguments: ["x"],
                                              stdin: "", workingDirectory: dir, timeout: 0)
    }
    await #expect(throws: ProcessRunnerError.timedOut) {
        _ = try await LiveProcessRunner().run(executable: "/bin/echo", arguments: ["x"],
                                              stdin: "", workingDirectory: dir, timeout: .nan)
    }
}
