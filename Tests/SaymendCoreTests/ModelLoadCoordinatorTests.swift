import Foundation
import Testing
@testable import SaymendCore

/// 載入次數計數器（actor 保證計數不競爭）
private actor Counter {
    private(set) var v = 0
    func inc() { v += 1 }
    func incGet() -> Int { v += 1; return v }
}

@Suite struct ModelLoadCoordinatorTests {
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
