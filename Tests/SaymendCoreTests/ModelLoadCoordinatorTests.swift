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

/// 可控時鐘：測試自己決定「現在」，不睡真實時間
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: @Sendable () -> Date { { self.lock.lock(); defer { self.lock.unlock() }; return self.t } }
    func set(_ d: Date) { lock.lock(); t = d; lock.unlock() }
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
        let aEntered = Gate(), releaseALoader = Gate(), releaseAWriteBack = Gate()
        let a = URL(filePath: "/m/a"), b = URL(filePath: "/m/b")
        let co = ModelLoadCoordinator<String>(testHooks: .init(beforeCacheWrite: { u in
            if u == a { await releaseAWriteBack.wait() }
        })) { u in
            await ct.inc()
            if u == a {
                await aEntered.open(); await releaseALoader.wait()
            }
            return u.lastPathComponent
        }
        let ta = Task { try await co.model(for: a) }
        let aStart = await awaitBounded(limit: .seconds(1)) { await aEntered.wait() }
        guard aStart == .completed else {
            Issue.record("a loader 未在 1 秒內進入")
            await releaseALoader.open(); await releaseAWriteBack.open(); ta.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await ta.result }
            return
        }
        let tb = Task { try await co.model(for: b) }
        // `.loading` 就是既有的 enqueue seam：model(for:) 連續寫完 inFlight／chainTail 後，
        // 才在 task.value 首次 suspension；actor 能回答 state 時，b 必已完整排進鏈上。
        let deadline = ContinuousClock.now + .seconds(1)
        var bReachedCoordinator = false
        while ContinuousClock.now < deadline {
            let state = await co.state(for: b)
            if state.isLoading {
                if await ct.v > 1 { Issue.record("b loader 在 a 完成前就開始，破壞不同-key 序列化") }
                bReachedCoordinator = true
                break
            }
            if state == .loaded {
                // predecessor 被拿掉時，b 會在仍卡住的 a 前面載完；這就是本測試要擋的舊風險。
                Issue.record("b 越過尚未完成的 a，提前成為 current")
                bReachedCoordinator = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard bReachedCoordinator else {
            Issue.record("等 b enqueue 逾時（1 秒）")
            // timeout 只負責讓測試紅；所有 Gate／Task 仍要清場，不能留下 SwiftPM build lock。
            await releaseALoader.open(); await releaseAWriteBack.open()
            ta.cancel(); tb.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await ta.result }
            _ = await awaitBounded(limit: .seconds(1)) { _ = await tb.result }
            return
        }
        await releaseALoader.open()                            // a loader 完成，chainTail 可放行 b
        let bCompletion = await awaitBounded(limit: .seconds(1)) { _ = await tb.result }
        guard bCompletion == .completed else {
            Issue.record("b loader 放行後 1 秒內未完成 cache write-back")
            await releaseAWriteBack.open()
            ta.cancel(); tb.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await ta.result }
            _ = await awaitBounded(limit: .seconds(1)) { _ = await tb.result }
            return
        }
        _ = try await tb.value                                 // b 先完成 cache write-back
        await releaseAWriteBack.open()                         // 再讓 stale a 嘗試 write-back
        let aCompletion = await awaitBounded(limit: .seconds(1)) { _ = await ta.result }
        guard aCompletion == .completed else {
            Issue.record("a write-back gate 放行後 1 秒內未返回")
            ta.cancel(); return
        }
        _ = try await ta.value
        _ = try await co.model(for: b)                         // current 應仍為 b，不得重載
        let loadCount = await ct.v
        #expect(loadCount == 2)
    }

    /// 即使沒有 overlapping loader，較晚 request 也必須取代既有 current；不能變成先完成者永久勝出。
    @Test func laterRequestReplacesEarlierCurrent() async throws {
        let ct = Counter()
        let co = ModelLoadCoordinator<String> { u in await ct.inc(); return u.lastPathComponent }
        let a = URL(filePath: "/m/a"), b = URL(filePath: "/m/b")
        _ = try await co.model(for: a)
        _ = try await co.model(for: b)
        _ = try await co.model(for: b)
        let loadCount = await ct.v
        #expect(loadCount == 2)
    }

    /// 同-key joiner 尚未恢復時，creator 也要原子完成 current／inFlight transition。
    /// 否則兩者之間會短暫同為 nil，第三個 request 便重開一份 3GB loader。
    @Test func sharedFlightCompletionBecomesCacheAtomically() async throws {
        let loads = Counter()
        let entered = Gate(), releaseLoader = Gate(), joined = Gate()
        let releaseJoiner = Gate(), creatorReturned = Gate()
        let u = URL(filePath: "/m/a")
        let co = ModelLoadCoordinator<String>(testHooks: .init(didJoinFlight: { key in
            if key == u { await joined.open(); await releaseJoiner.wait() }
        })) { key in
            await loads.inc(); await entered.open(); await releaseLoader.wait()
            return key.lastPathComponent
        }

        let creator = Task {
            let model = try await co.model(for: u); await creatorReturned.open(); return model
        }
        let enteredOutcome = await awaitBounded(limit: .seconds(1)) { await entered.wait() }
        guard enteredOutcome == .completed else {
            Issue.record("creator loader 未在 1 秒內進入")
            await releaseLoader.open(); creator.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await creator.result }
            return
        }
        let joiner = Task { try await co.model(for: u) }
        let joinOutcome = await awaitBounded(limit: .seconds(1)) { await joined.wait() }
        guard joinOutcome == .completed else {
            Issue.record("第二個 request 未在 1 秒內 join shared flight")
            await releaseLoader.open(); await releaseJoiner.open()
            creator.cancel(); joiner.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await creator.result }
            _ = await awaitBounded(limit: .seconds(1)) { _ = await joiner.result }
            return
        }

        await releaseLoader.open()
        let completion = await awaitBounded(limit: .seconds(1)) { await creatorReturned.wait() }
        guard completion == .completed else {
            Issue.record("creator 未能原子完成 shared flight 的 cache transition")
            await releaseJoiner.open(); creator.cancel(); joiner.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await creator.result }
            _ = await awaitBounded(limit: .seconds(1)) { _ = await joiner.result }
            return
        }
        _ = try await co.model(for: u)             // joiner 仍卡在 hook；此時必須已是 cache hit
        #expect(await loads.v == 1)
        #expect(await co.state(for: u) == .loaded)

        await releaseJoiner.open()
        _ = try await creator.value; _ = try await joiner.value
    }

    /// A/B 持續交替時，每個已完成 flight 都要先被採用；cache hit 不得讓 in-flight 結果飢餓。
    @Test func alternatingDifferentKeyTrafficStillAdoptsEveryCompletedFlight() async throws {
        let rounds = 20
        let loads = Counter()
        let entered = (0..<rounds).map { _ in Gate() }
        let releases = (0..<rounds).map { _ in Gate() }
        let a = URL(filePath: "/m/a"), b = URL(filePath: "/m/b")
        let co = ModelLoadCoordinator<String> { key in
            let ordinal = await loads.incGet()
            if ordinal > 1 {
                let round = ordinal - 2
                guard round < rounds else { return key.lastPathComponent }
                await entered[round].open(); await releases[round].wait()
            }
            return key.lastPathComponent
        }

        _ = try await co.model(for: a)
        var currentKey = a
        for round in 0..<rounds {
            let target = currentKey == a ? b : a
            let loading = Task { try await co.model(for: target) }
            let didEnter = await awaitBounded(limit: .seconds(1)) { await entered[round].wait() }
            guard didEnter == .completed else {
                Issue.record("第 \(round + 1) 個交替 loader 未在 1 秒內進入")
                for gate in releases { await gate.open() }
                loading.cancel()
                _ = await awaitBounded(limit: .seconds(1)) { _ = await loading.result }
                return
            }
            _ = try await co.model(for: currentKey)     // 較晚 cache access 沒有 supersede 權
            await releases[round].open()
            _ = try await loading.value
            guard await co.state(for: target) == .loaded else {
                Issue.record("第 \(round + 1) 個已完成 loader 未被採用")
                return
            }
            currentKey = target
        }
        #expect(await loads.v == rounds + 1)
    }

    /// 已取消的舊 cache access 必須 fail fast，不能影響正在載入的新選擇。
    @Test func cancelledCacheHitCannotSupersedeInFlightSelection() async throws {
        let loads = Counter(), bEntered = Gate(), releaseB = Gate(), invokeCancelled = Gate()
        let a = URL(filePath: "/m/a"), b = URL(filePath: "/m/b")
        let co = ModelLoadCoordinator<String> { key in
            await loads.inc()
            if key == b { await bEntered.open(); await releaseB.wait() }
            return key.lastPathComponent
        }
        _ = try await co.model(for: a)                           // current = a
        let loadingB = Task { try await co.model(for: b) }
        let entered = await awaitBounded(limit: .seconds(1)) { await bEntered.wait() }
        guard entered == .completed else {
            Issue.record("b loader 未在 1 秒內進入")
            await releaseB.open(); loadingB.cancel()
            _ = await awaitBounded(limit: .seconds(1)) { _ = await loadingB.result }
            return
        }

        let obsoleteA = Task { () -> Bool in
            await invokeCancelled.wait()
            do {
                _ = try await co.model(for: a)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        obsoleteA.cancel()
        await invokeCancelled.open()                             // 確認 cancel 在 actor call 前發生
        #expect(await obsoleteA.value, "已取消 caller 應擲 CancellationError")

        await releaseB.open()
        _ = try await loadingB.value
        #expect(await co.state(for: b) == .loaded)
        _ = try await co.model(for: b)
        #expect(await loads.v == 2)
    }

    /// issue #35：Settings 的 selection intent 尚未進 coordinator；外層 preload cancel 不會撤銷已建 flight。
    @Test func appStyleSelectionBackToCachedModelKeepsItCurrent() async {
        await withKnownIssue("issue #35：選回 cached A 尚無 desired-key seam") {
            let loads = Counter(), bEntered = Gate(), releaseB = Gate()
            let a = URL(filePath: "/m/a"), b = URL(filePath: "/m/b")
            let co = ModelLoadCoordinator<String> { key in
                await loads.inc()
                if key == b { await bEntered.open(); await releaseB.wait() }
                return key.lastPathComponent
            }

            _ = try? await co.model(for: a)                     // current = A
            let obsoleteB = Task { await co.preload(b) }        // App 的舊 preload wrapper
            let entered = await awaitBounded(limit: .seconds(1)) { await bEntered.wait() }
            guard entered == .completed else {
                Issue.record("B loader 未在 1 秒內進入")
                await releaseB.open(); obsoleteB.cancel()
                _ = await awaitBounded(limit: .seconds(1)) { _ = await obsoleteB.result }
                return
            }
            obsoleteB.cancel()                                  // flight 已建立後才 cancel wrapper
            await co.preload(a)                                 // 新 selection A 恰好 cache hit
            await releaseB.open()
            _ = await obsoleteB.value

            #expect(await co.state(for: a) == .loaded)
            #expect(await co.state(for: b) == .idle)
            _ = try? await co.model(for: a)
            #expect(await loads.v == 2)
        }
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
        #expect(await co.state(for: u).isLoading)
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
        while !(await co.state(for: hang).isLoading) { await Task.yield() }

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

    /// 載入中的狀態要帶得出「這一趟是什麼時候開始的」——設定頁靠它算已經過時間，
    /// 而那是 issue #17 裡唯一不依賴 log 字串解析的資訊來源（字串解析壞掉時碼表仍要能走）。
    @Test func loadingStateCarriesStartTime() async {
        let start = Date(timeIntervalSince1970: 5000)
        let gate = Gate()
        let co = ModelLoadCoordinator<String>(now: { start }) { u in
            await gate.wait()
            return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")
        let loading = Task { _ = try? await co.model(for: u) }
        while await co.state(for: u) == .idle { await Task.yield() }

        #expect(await co.state(for: u) == .loading(since: start))
        await gate.open()
        _ = await loading.value
        #expect(await co.state(for: u) == .loaded)
    }

    /// 卸載後若同一個 key 已有新的載入接手，舊載入收工時不得把新的那筆 in-flight 記錄刪掉。
    ///
    /// 這條守衛現在位於 `finishFlight`／`clearFlight` 的 task identity 檢查；少了它，
    /// 舊 flight 完成時會清掉 unload 後接手的 successor。
    /// 誤刪的後果：狀態謊報 `.idle`，設定頁的「載入」按鈕重新亮起，使用者按下去就再開一份 3.2GB。
    @Test func aFinishingLoadDoesNotEraseItsSuccessorAfterUnload() async {
        let u = URL(filePath: "/m/a")
        let gate1 = Gate(), gate2 = Gate()
        let round = Counter()
        let co = ModelLoadCoordinator<String>(queueGrace: .milliseconds(50)) { _ in
            if await round.incGet() == 1 { await gate1.wait() } else { await gate2.wait() }
            return "m"
        }

        let first = Task { _ = try? await co.model(for: u) }
        while !(await co.state(for: u).isLoading) { await Task.yield() }

        await co.unload()                       // 清掉 in-flight 記錄，但 first 仍在跑
        let second = Task { _ = try? await co.model(for: u) }
        while !(await co.state(for: u).isLoading) { await Task.yield() }

        await gate1.open()                      // 舊的收工
        _ = await first.value
        #expect(await co.state(for: u).isLoading, "新的載入仍在途，狀態不得回到 idle")

        await gate2.open()
        _ = await second.value
    }

    /// 起始時刻要在載入**開始**那一刻定住，不是每次查詢才取現在。
    ///
    /// 取現在的話兩者在固定時鐘下看起來一樣，但實機上經過時間會永遠是 0 秒——
    /// 畫面等於沒有碼表，而本票的整個前提就是使用者看不出它在不在動。
    @Test func startTimeIsFrozenAtLoadStartNotReadAtQueryTime() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let gate = Gate()
        let co = ModelLoadCoordinator<String>(now: clock.now) { u in
            await gate.wait()
            return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")
        let loading = Task { _ = try? await co.model(for: u) }
        while await co.state(for: u) == .idle { await Task.yield() }

        clock.set(Date(timeIntervalSince1970: 1600))     // 載入中，時鐘走了 10 分鐘
        #expect(await co.state(for: u) == .loading(since: Date(timeIntervalSince1970: 1000)))

        await gate.open()
        _ = await loading.value
    }

    /// 第二趟載入要拿到新的起始時刻，不是留著上一趟的。
    /// 沿用舊時戳的話，卸載後重載會在畫面上瞬間顯示成「已經載了十分鐘」。
    @Test func reloadAfterUnloadGetsAFreshStartTime() async {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 9000)
        let clock = MutableClock(t1)
        let gate1 = Gate(), gate2 = Gate()
        let round = Counter()
        let co = ModelLoadCoordinator<String>(now: clock.now) { u in
            if await round.incGet() == 1 { await gate1.wait() } else { await gate2.wait() }
            return u.lastPathComponent
        }
        let u = URL(filePath: "/m/a")

        let first = Task { _ = try? await co.model(for: u) }
        while await co.state(for: u) == .idle { await Task.yield() }
        #expect(await co.state(for: u) == .loading(since: t1))
        await gate1.open()
        _ = await first.value

        await co.unload()
        clock.set(t2)
        let second = Task { _ = try? await co.model(for: u) }
        while await co.state(for: u) == .idle { await Task.yield() }
        #expect(await co.state(for: u) == .loading(since: t2))
        await gate2.open()
        _ = await second.value
    }

}
