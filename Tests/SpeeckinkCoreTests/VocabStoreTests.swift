import Foundation
import Testing
@testable import SpeeckinkCore

@Suite struct VocabStoreTests {
    private func makeStore() -> (FileVocabStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        return (FileVocabStore(fileURL: url), url)
    }

    @Test func crudRoundTrip() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.all().isEmpty)
        let entry = VocabEntry(phrase: "openpets", mishearings: ["歐噴佩茲", "open pets"])
        store.upsert(entry)
        #expect(store.all() == [entry])
        var renamed = entry
        renamed.phrase = "OpenPets"
        store.upsert(renamed)                        // 同 id upsert＝更新
        #expect(store.all() == [renamed])
        store.delete(id: entry.id)
        #expect(store.all().isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.upsert(VocabEntry(phrase: "Speeckink", mishearings: []))
        let reloaded = FileVocabStore(fileURL: url)
        #expect(reloaded.all().map(\.phrase) == ["Speeckink"])
    }

    @Test func importMergesByPhraseAndReturnsCount() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.upsert(VocabEntry(phrase: "kubectl", mishearings: ["酷比控"]))
        let incoming = [VocabEntry(phrase: "kubectl", mishearings: ["Q控"]),
                        VocabEntry(phrase: "GRDB", mishearings: [])]
        let data = try JSONEncoder().encode(incoming)
        let count = try store.importJSON(data)
        #expect(count == 2)
        let phrases = store.all().map(\.phrase).sorted()
        #expect(phrases == ["GRDB", "kubectl"])       // phrase 相同＝覆蓋不重複
        #expect(store.all().first { $0.phrase == "kubectl" }?.mishearings == ["Q控"])
    }

    @Test func exportRoundTripsThroughImport() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.upsert(VocabEntry(phrase: "SwiftPM", mishearings: ["swift 屁M"]))
        let data = try store.exportJSON()
        let (store2, url2) = makeStore()
        defer { try? FileManager.default.removeItem(at: url2) }
        _ = try store2.importJSON(data)
        #expect(store2.all().map(\.phrase) == ["SwiftPM"])
    }

    @Test func corruptFileDegradesToEmpty() throws {
        let (_, url) = makeStore()
        try Data("不是 JSON".utf8).write(to: url)
        let store = FileVocabStore(fileURL: url)
        #expect(store.all().isEmpty)                  // 壞檔不炸：清空重來（詞彙表非關鍵資料）
    }
}
