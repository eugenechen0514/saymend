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

    /// 沒有紀錄就是 nil。UI 靠這個決定「（最久 8:47）」要不要顯示——
    /// 回一個 0 會讓第一次載入就顯示「最久 0:00」，那是編造出來的。
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
    /// 是同一個坑（見 `ModelPathKey`）。分成兩筆的後果是永遠讀不到耗時參照。
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

    /// **暖載入不得蓋掉冷載入的紀錄。**
    ///
    /// 這條來自實機驗收（2026-08-23）：tiny 冷載入 16.88 秒，之後每次暖載入只要 0.5 秒。
    /// 原本的設計是「覆寫，參照取最近一次」，於是歷史被 0.56 蓋掉。下次 ANE 快取被回收而
    /// 重新冷編譯時，示警門檻變成 `0.56 × 3 = 1.7 秒`——一趟完全合法的 17 秒冷載入會從
    /// 第 2 秒起一路示警。暖載入污染冷載入的參照，正是本票最想避免的誤殺。
    @Test func warmLoadDoesNotOverwriteAColdOne() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        let url = URL(filePath: "/models/tiny")
        h.record(CompletedLoad(total: 16.88, stages: [.audioEncoder: 14.71, .textDecoder: 1.71]),
                 for: url)                                            // 冷
        h.record(CompletedLoad(total: 0.56, stages: [.audioEncoder: 0.06, .textDecoder: 0.07]),
                 for: url)                                            // 暖
        #expect(h.last(for: url)?.total == 16.88)
        #expect(h.last(for: url)?.stages[.audioEncoder] == 14.71)
        #expect(h.last(for: url)?.stages[.textDecoder] == 1.71)
    }

    /// 更慢的一趟要墊高紀錄——參照回答的是「這台機器上可能要多久」，
    /// 而那個問題的答案是看過的最壞情況。
    @Test func aSlowerLoadRaisesTheRecord() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        let url = URL(filePath: "/models/m")
        h.record(CompletedLoad(total: 543, stages: [.audioEncoder: 400]), for: url)
        h.record(CompletedLoad(total: 1297, stages: [.audioEncoder: 1100]), for: url)
        #expect(h.last(for: url)?.total == 1297)
        #expect(h.last(for: url)?.stages[.audioEncoder] == 1100)
    }

    /// 逐**項**取最大值：某一趟少報了某個階段，不得把既有的那一格清掉。
    /// 特徵擷取器就是這種情況——它那則訊息不帶耗時，永遠不會出現在新紀錄裡。
    @Test func aStageMissingFromTheNewRunKeepsItsOldValue() {
        let (d, cleanup) = makeDefaults(); defer { cleanup() }
        let h = ModelLoadHistory(defaults: d)
        let url = URL(filePath: "/models/m")
        h.record(CompletedLoad(total: 10, stages: [.textDecoder: 5, .tokenizer: 1]), for: url)
        h.record(CompletedLoad(total: 20, stages: [.textDecoder: 3]), for: url)
        #expect(h.last(for: url)?.total == 20)
        #expect(h.last(for: url)?.stages[.textDecoder] == 5)      // 舊的比較大，留著
        #expect(h.last(for: url)?.stages[.tokenizer] == 1)        // 新的沒報，不得被清掉
    }
}
