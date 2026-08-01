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

    // MARK: - 載入狀態與卸載（M9 追加：首次 ANE 編譯很久，UI 要能如實顯示與釋放）

    @Test func stateIsLoadedAfterLoad() async throws {
        let co = ModelLoadCoordinator<String> { $0.lastPathComponent }
        let u = URL(filePath: "/m/a")
        #expect(await co.state(for: u) == .idle)
        _ = try await co.model(for: u)
        #expect(await co.state(for: u) == .loaded)
    }

    @Test func stateIsLoadingWhileInFlight() async throws {
        let entered = Gate(), release = Gate()
        let co = ModelLoadCoordinator<String> { u in
            await entered.open(); await release.wait(); return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")
        let t = Task { try await co.model(for: u) }
        await entered.wait()
        #expect(await co.state(for: u) == .loading)
        await release.open()
        _ = try await t.value
        #expect(await co.state(for: u) == .loaded)
    }

    @Test func unloadReleasesModelAndReloadsOnDemand() async throws {
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in await ct.inc(); return u.lastPathComponent }
        let u = URL(filePath: "/m/a")
        _ = try await co.model(for: u)
        await co.unload()
        #expect(await co.state(for: u) == .idle)
        _ = try await co.model(for: u)                 // 已釋放＝下次要重載
        #expect(await ct.v == 2)
    }

    /// unload 當下的 in-flight 載入完成後，不得把模型又塞回 current（epoch 防呆）
    @Test func unloadDuringInFlightPreventsCacheWriteBack() async throws {
        let entered = Gate(), release = Gate()
        let co = ModelLoadCoordinator<String> { u in
            await entered.open(); await release.wait(); return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")
        let t = Task { try await co.model(for: u) }
        await entered.wait()
        await co.unload()
        await release.open()
        _ = try? await t.value
        #expect(await co.state(for: u) == .idle)
    }

    /// unload 不得破壞序列化不變式：卸載當下仍在跑的載入與新載入不可並發（峰值仍為 1）
    @Test func unloadKeepsSerialization() async throws {
        let pc = PeakCounter()
        let entered = Gate(), release = Gate()
        let co = ModelLoadCoordinator<String> { u in
            await pc.enter()
            if u.lastPathComponent == "a" { await entered.open(); await release.wait() }
            await pc.leave()
            return u.lastPathComponent
        }
        let ta = Task { try await co.model(for: URL(filePath: "/m/a")) }
        await entered.wait()
        await co.unload()
        let tb = Task { try await co.model(for: URL(filePath: "/m/b")) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        await release.open()
        _ = try? await ta.value
        _ = try? await tb.value
        #expect(await pc.peak == 1)
    }

    /// **目錄 URL 與同一路徑的非目錄 URL 是同一個模型，不得各載一份。**
    ///
    /// 掃描器給的是目錄 URL（帶尾斜線），設定經 UserDefaults 來回一趟會變成不帶斜線的，
    /// 而**尾斜線的差異 `resolvingSymlinksInPath()` 與 `standardizedFileURL` 都消不掉**。
    /// 兩種形式同時出現在系統裡時，同一個模型會被當成兩個 key ——large-v3-turbo 各 3.2GB。
    @Test func directoryURLAndPlainPathShareOneCacheKey() async throws {
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in await ct.inc(); return u.lastPathComponent }
        _ = try await co.model(for: URL(filePath: "/m/large", directoryHint: .isDirectory))   // 掃描器形式
        _ = try await co.model(for: URL(filePath: "/m/large"))                                // 設定讀回的形式
        let loads = await ct.v
        #expect(loads == 1, "同一個資料夾被載了兩次（掃描器形式與設定讀回形式各一份）")
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

    /// **卸載之後還是載不起來——使用者唯一的自救動作失效。**
    ///
    /// 實機症狀（2026-07-28）：App 閒置 20 小時、0% CPU、所有執行緒停在 run loop、
    /// 記憶體峰值 148MB（486MB 的模型從未進記憶體），設定頁卻一直顯示「載入中…」，
    /// 按「卸載」再按「載入」也回不來。
    ///
    /// 機制：一次永不返回、也不理會取消的載入會讓排隊鏈尾永遠不完成。`unload()`
    /// 刻意不清 `chainTail`（為了守住「同時最多一個 loader」的記憶體上界），
    /// 於是**後續每一次載入都排在一個死掉的前置者後面**，永遠等不到自己上場。
    ///
    /// 記憶體上界與可復原性衝突時，可復原性優先：掛住的那次載入根本沒把模型載進來、
    /// 佔不到記憶體，而代價是整個離線引擎永久失效、且沒有任何出口。
    @Test func unloadRecoversFromALoaderThatNeverReturns() async {
        let neverOpens = Gate()
        let hang = URL(filePath: "/m/hang")
        let ok = URL(filePath: "/m/ok")
        // 寬限期縮短才測得動；正式預設是 60 秒，由 unloadKeepsSerialization 走預設值把關
        let co = ModelLoadCoordinator<String>(queueGrace: .milliseconds(200)) { u in
            if u.lastPathComponent == "hang" { await neverOpens.wait() }   // 永不返回、不理會取消
            return u.lastPathComponent
        }

        let stuck = Task { _ = try? await co.model(for: hang) }
        while await co.state(for: hang) != .loading { await Task.yield() }

        await co.unload()
        #expect(await co.state(for: hang) == .idle)     // 卸載確實清掉了 in-flight 記錄

        // 使用者接著按「載入」——這一次必須真的載得起來
        let retry = Task { _ = try? await co.model(for: ok) }
        var loaded = false
        for _ in 0..<150 {                              // 有界等待 1.5 秒；不能 await 那個永不返回的 Task
            if await co.state(for: ok) == .loaded { loaded = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(loaded, "卸載後的載入排在死掉的前置者後面——使用者再也載不起來")

        // 收尾：放行掛住的載入，否則 Gate 裡的 continuation 會在解構時被判定洩漏
        await neverOpens.open()
        _ = await stuck.value
        _ = await retry.value
    }
}
