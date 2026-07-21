import Foundation
import Testing
@testable import SaymendCore

/// 可注入假件的偵測管線測試（spec §4.1 三關：可執行 → 版本 probe → 快取）
private func makeDetector(executables: Set<String>,
                          mtimes: [String: Date] = [:],
                          versions: [String: String]) -> (ClaudeCLIDetector, ProbeCounter) {
    let counter = ProbeCounter()
    let d = ClaudeCLIDetector(
        isExecutableFile: { executables.contains($0) },
        modificationDate: { mtimes[$0] ?? Date(timeIntervalSince1970: 1000) },
        versionProbe: { path in
            await counter.bump()
            return versions[path]
        })
    return (d, counter)
}

actor ProbeCounter { private(set) var count = 0; func bump() { count += 1 } }

@Test func detectorPrefersFirstExecutableCandidate() async {
    let first = ClaudeCLIDetector.expand(ClaudeCLIDetector.candidates[0])
    let (d, _) = makeDetector(executables: [first], versions: [first: "2.1.216 (Claude Code)"])
    #expect(await d.detect(override: nil) == .found(path: first, version: "2.1.216"))
}

@Test func detectorSkipsNonExecutableAndFallsThrough() async {
    // 第一候選不可執行 → 用第二候選
    let second = ClaudeCLIDetector.expand(ClaudeCLIDetector.candidates[1])
    let (d, _) = makeDetector(executables: [second], versions: [second: "3.0.1 (Claude Code)"])
    #expect(await d.detect(override: nil) == .found(path: second, version: "3.0.1"))
}

@Test func detectorNotFoundWhenNothingExecutable() async {
    let (d, _) = makeDetector(executables: [], versions: [:])
    #expect(await d.detect(override: nil) == .notFound)
}

@Test func detectorOverrideWinsAndDoesNotFallBack() async {
    // override 壞掉＝notFound（不落回候選——靜默 fallback 會隱藏誤設）
    let cand = ClaudeCLIDetector.expand(ClaudeCLIDetector.candidates[0])
    let (d, _) = makeDetector(executables: [cand], versions: [cand: "2.1.216 (Claude Code)"])
    #expect(await d.detect(override: "/broken/claude") == .notFound)
    #expect(await d.detect(override: cand) == .found(path: cand, version: "2.1.216"))
}

@Test func detectorRejectsTooOldOrUnparseableVersion() async {
    let p = "/x/claude"
    let (old, _) = makeDetector(executables: [p], versions: [p: "2.0.9 (Claude Code)"])
    guard case .incompatible(path: p, reason: _) = await old.detect(override: p) else {
        Issue.record("過舊版本應 incompatible"); return
    }
    let (bad, _) = makeDetector(executables: [p], versions: [p: "not a version"])
    guard case .incompatible = await bad.detect(override: p) else {
        Issue.record("無法解析應 incompatible"); return
    }
    let (dead, _) = makeDetector(executables: [p], versions: [:])   // probe 失敗（nil）
    guard case .incompatible = await dead.detect(override: p) else {
        Issue.record("probe 失敗應 incompatible"); return
    }
}

@Test func detectorCachesByPathAndMtime() async {
    let p = "/x/claude"
    let t0 = Date(timeIntervalSince1970: 100)
    let (d, counter) = makeDetector(executables: [p], mtimes: [p: t0], versions: [p: "2.1.216 (Claude Code)"])
    _ = await d.detect(override: p)
    _ = await d.detect(override: p)
    #expect(await counter.count == 1)                 // 同 (path, mtime) 只 probe 一次
}

@Test func detectorVersionParsing() {
    #expect(ClaudeCLIDetector.parseVersion("2.1.216 (Claude Code)")! == (2, 1, 216))
    #expect(ClaudeCLIDetector.parseVersion("10.0.0") != nil)
    #expect(ClaudeCLIDetector.parseVersion("hello") == nil)
}

@Test func detectorReprobesWhenMtimeChanges() async {
    // 版本更新＝symlink 目標 mtime 變 → 快取必須失效重 probe
    let p = "/x/claude"
    let holder = MtimeHolder(Date(timeIntervalSince1970: 100))
    let counter = ProbeCounter()
    let d = ClaudeCLIDetector(
        isExecutableFile: { $0 == p },
        modificationDate: { _ in holder.value },
        versionProbe: { _ in await counter.bump(); return "2.1.216 (Claude Code)" })
    _ = await d.detect(override: p)
    holder.value = Date(timeIntervalSince1970: 200)
    _ = await d.detect(override: p)
    #expect(await counter.count == 2)                 // mtime 變 → 重 probe
}

final class MtimeHolder: @unchecked Sendable {
    var value: Date
    init(_ d: Date) { value = d }
}
