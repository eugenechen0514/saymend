import Foundation
import Testing
@testable import SaymendCore

/// 每個測試自己一份 UserDefaults suite，互不污染也不碰使用者的實際設定
private func makeDefaults() -> (UserDefaults, () -> Void) {
    let name = "io.saymend.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    return (d, { d.removePersistentDomain(forName: name) })
}

@Suite struct ModelLoadHistoryTests {

    @Test func recordsAndReadsBackTotalAndStages() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        let url = URL(filePath: "/models/large-v3_turbo")
        h.record(CompletedLoad(total: 631.34, stages: [.textDecoder: 104.21, .audioEncoder: 526.64]),
                 for: url)
        let got = h.last(for: url)
        #expect(got?.total == 631.34)
        #expect(got?.stages[.textDecoder] == 104.21)
        #expect(got?.stages[.audioEncoder] == 526.64)
    }

    /// 沒有紀錄就是 nil。UI 靠這個決定「（上次 8:47）」要不要顯示——
    /// 回一個 0 會讓第一次載入就顯示「上次 0:00」，那是編造出來的。
    @Test func noRecordYieldsNil() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        #expect(ModelLoadHistory(defaults: d).last(for: URL(filePath: "/models/never-loaded")) == nil)
    }

    @Test func differentModelsDoNotCollide() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        h.record(CompletedLoad(total: 123, stages: [:]), for: URL(filePath: "/models/small"))
        h.record(CompletedLoad(total: 631, stages: [:]), for: URL(filePath: "/models/large"))
        #expect(h.last(for: URL(filePath: "/models/small"))?.total == 123)
        #expect(h.last(for: URL(filePath: "/models/large"))?.total == 631)
    }

    /// **不同根目錄下的同名模型不得互蓋。** 用 `lastPathComponent` 當 key 會讓
    /// `/a/openai_whisper-small` 與 `/b/openai_whisper-small` 共用一筆紀錄，
    /// 於是慢機器上量到的耗時被拿去當快機器的參照。
    @Test func sameFolderNameUnderDifferentRootsAreDistinct() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        h.record(CompletedLoad(total: 10, stages: [:]), for: URL(filePath: "/a/openai_whisper-small"))
        h.record(CompletedLoad(total: 20, stages: [:]), for: URL(filePath: "/b/openai_whisper-small"))
        #expect(h.last(for: URL(filePath: "/a/openai_whisper-small"))?.total == 10)
    }

    /// **同一顆模型的不同寫法要落在同一筆。** 掃描器給的是 `…/model/`（尾斜線），
    /// 設定經 UserDefaults 來回一趟變成 `…/model`——與 `ModelLoadCoordinator` 的快取 key
    /// 是同一個坑（見 `ModelPathKey`）。分成兩筆的後果是永遠讀不到上次的耗時。
    @Test func trailingSlashSharesOneRecord() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        h.record(CompletedLoad(total: 42, stages: [:]), for: URL(filePath: "/models/m/"))
        #expect(h.last(for: URL(filePath: "/models/m"))?.total == 42)
    }

    /// 毀損的資料回 nil，不當機——這是使用者的 UserDefaults，什麼都可能被寫進去。
    @Test func corruptStorageYieldsNilInsteadOfCrashing() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        d.set(Data("這不是 JSON".utf8), forKey: ModelLoadHistory.defaultsKey)
        let h = ModelLoadHistory(defaults: d)
        #expect(h.last(for: URL(filePath: "/models/m")) == nil)
        // 且要能從毀損狀態復原：寫得進去、讀得回來
        h.record(CompletedLoad(total: 7, stages: [:]), for: URL(filePath: "/models/m"))
        #expect(h.last(for: URL(filePath: "/models/m"))?.total == 7)
    }

    /// 未來版本若新增階段，舊版讀到不認得的階段名要略過而不是整筆丟掉。
    @Test func unknownStageNamesAreSkippedNotFatal() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let json = #"{"/models/m":{"total":9.0,"stages":{"textDecoder":1.5,"futureStage":2.5}}}"#
        d.set(Data(json.utf8), forKey: ModelLoadHistory.defaultsKey)
        let got = ModelLoadHistory(defaults: d).last(for: URL(filePath: "/models/m"))
        #expect(got?.total == 9.0)
        #expect(got?.stages == [.textDecoder: 1.5])
    }

    /// 重新載入同一顆模型要覆寫，不是累積——參照永遠取最近一次。
    @Test func recordingAgainOverwrites() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        let url = URL(filePath: "/models/m")
        h.record(CompletedLoad(total: 100, stages: [.textDecoder: 50]), for: url)
        h.record(CompletedLoad(total: 200, stages: [:]), for: url)
        #expect(h.last(for: url)?.total == 200)
        #expect(h.last(for: url)?.stages.isEmpty == true)
    }
}
