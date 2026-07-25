import Foundation
import Testing
@testable import SaymendCore

/// 載入次數計數器（actor 保證計數不競爭）
private actor Counter {
    private(set) var v = 0
    func inc() { v += 1 }
    func incGet() -> Int { v += 1; return v }
}

/// 量測 loader 的並發峰值
private actor PeakCounter {
    private(set) var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

/// 一次性閘門：open 前 wait 會掛住
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        guard !opened else { return }
        opened = true
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite struct ModelLoadCoordinatorTests {
    /// REV #1：不同 key 的載入必須序列化——否則兩個 3GB 模型同時載入，峰值記憶體無上界
    @Test func differentKeysLoadSerially() async throws {
        let pc = PeakCounter()
        let co = ModelLoadCoordinator<String> { u in
            await pc.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await pc.leave()
            return u.lastPathComponent
        }
        async let a = co.model(for: URL(filePath: "/m/a"))
        async let b = co.model(for: URL(filePath: "/m/b"))
        _ = try await (a, b)
        #expect(await pc.peak == 1)
    }

    /// REV #1：最後發起的載入才是 current——慢的過期 preload 完成後不得覆寫較新的選擇
    @Test func laterLoadWinsTheCache() async throws {
        let ct = Counter()
        let entered = Gate(), release = Gate()
        let co = ModelLoadCoordinator<String> { u in
            await ct.inc()
            if u.lastPathComponent == "a" { await entered.open(); await release.wait() }
            return u.lastPathComponent
        }
        let ta = Task { try await co.model(for: URL(filePath: "/m/a")) }
        await entered.wait()                                   // a 已進 loader 且卡住
        let tb = Task { try await co.model(for: URL(filePath: "/m/b")) }
        // 給 b 足夠時間進 coordinator。序列化前 b 會在此期間「插隊載完」並成為 current，
        // 接著 a 才慢慢完成並把 current 蓋回 a（正是本測試要擋的過期覆寫）；序列化後 b 只會排隊。
        // 不能改等「b 的 loader 進入」當同步點——序列化後那要等 a 先完成，會死結。
        try? await Task.sleep(nanoseconds: 60_000_000)
        await release.open()
        _ = try await ta.value
        _ = try await tb.value
        _ = try await co.model(for: URL(filePath: "/m/b"))      // b 後完成＝current，不得重載
        #expect(await ct.v == 2)
    }

    /// REV #8：symlink 與實體路徑是同一個模型，不得各載一份
    @Test func symlinkedPathSharesCacheKey() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mlc-\(UUID().uuidString)")
        let real = base.appending(path: "model")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appending(path: "link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in await ct.inc(); return u.lastPathComponent }
        _ = try await co.model(for: real)
        _ = try await co.model(for: link)
        #expect(await ct.v == 1)
    }

    @Test func sameKeyLoadsOnce() async throws {
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in
            await ct.inc()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return u.lastPathComponent
        }
        let u = URL(filePath: "/m/tiny")
        async let a = co.model(for: u)
        async let b = co.model(for: u)
        let (ra, rb) = try await (a, b)
        #expect(ra == "tiny" && rb == "tiny")
        #expect(await ct.v == 1)
    }

    @Test func correctModelPerKey() async throws {
        let co = ModelLoadCoordinator<String> { $0.lastPathComponent }
        #expect(try await co.model(for: URL(filePath: "/m/large")) == "large")
        #expect(try await co.model(for: URL(filePath: "/m/small")) == "small")
    }

    @Test func boundedCacheEvictsOld() async throws {
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in
            await ct.inc()
            return u.lastPathComponent
        }
        _ = try await co.model(for: URL(filePath: "/m/a"))   // 載 a（cache=a）
        _ = try await co.model(for: URL(filePath: "/m/b"))   // 載 b（淘汰 a）
        _ = try await co.model(for: URL(filePath: "/m/a"))   // a 已被淘汰 → 再載
        #expect(await ct.v == 3)
    }

    @Test func failureNotPoisoned() async throws {
        let ct = Counter()
        // 第一次擲錯，之後成功
        let co = ModelLoadCoordinator<String> { u in
            let n = await ct.incGet()
            if n == 1 { throw NSError(domain: "x", code: 1) }
            return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")
        await #expect(throws: (any Error).self) { _ = try await co.model(for: u) }   // 首次失敗
        let r = try await co.model(for: u)                                           // 重載成功
        #expect(r == "a")
        #expect(await ct.v == 2)
    }
}
