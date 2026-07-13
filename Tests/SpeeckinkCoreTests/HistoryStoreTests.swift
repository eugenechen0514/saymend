import Foundation
import GRDB
import Testing
@testable import SpeeckinkCore

@Suite struct HistoryStoreTests {
    private func makeStore() throws -> GRDBHistoryStore {
        try GRDBHistoryStore(databaseQueue: DatabaseQueue())   // in-memory
    }

    @Test func sessionLifecycleRoundTrip() throws {
        let store = try makeStore()
        let id = UUID().uuidString
        store.beginSession(.init(id: id, startedAt: Date(timeIntervalSince1970: 1000),
                                 appBundleID: "com.apple.TextEdit", appName: "TextEdit",
                                 targetKind: "tail", finalText: nil))
        store.recordExchange(.init(sessionID: id, at: Date(timeIntervalSince1970: 1001),
                                   utteranceRaw: "呃你好", outcomeKind: "newContent", outcomeText: "你好。"))
        store.finishSession(id: id, finalText: "你好。")
        let sessions = store.recentSessions(limit: 10)
        #expect(sessions.count == 1)
        #expect(sessions[0].finalText == "你好。")
        #expect(sessions[0].appName == "TextEdit")
        let ex = store.exchanges(sessionID: id)
        #expect(ex.count == 1)
        #expect(ex[0].utteranceRaw == "呃你好")
        #expect(ex[0].outcomeKind == "newContent")
    }

    @Test func recentSessionsOrdersNewestFirstAndLimits() throws {
        let store = try makeStore()
        for i in 0..<5 {
            store.beginSession(.init(id: "s\(i)", startedAt: Date(timeIntervalSince1970: Double(i)),
                                     appBundleID: nil, appName: nil, targetKind: "tail", finalText: nil))
        }
        let recent = store.recentSessions(limit: 3)
        #expect(recent.map(\.id) == ["s4", "s3", "s2"])
    }

    @Test func purgeRemovesOldSessionsAndTheirExchanges() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        store.beginSession(.init(id: "old", startedAt: old, appBundleID: nil, appName: nil,
                                 targetKind: "tail", finalText: nil))
        store.recordExchange(.init(sessionID: "old", at: old, utteranceRaw: "舊",
                                   outcomeKind: "newContent", outcomeText: "舊。"))
        store.beginSession(.init(id: "new", startedAt: Date(), appBundleID: nil, appName: nil,
                                 targetKind: "tail", finalText: nil))
        store.purge(olderThanDays: 30)
        #expect(store.recentSessions(limit: 10).map(\.id) == ["new"])
        #expect(store.exchanges(sessionID: "old").isEmpty)   // 連帶清 exchange
    }

    @Test func deleteAllWipesEverything() throws {
        let store = try makeStore()
        store.beginSession(.init(id: "x", startedAt: Date(), appBundleID: nil, appName: nil,
                                 targetKind: "selection", finalText: nil))
        store.deleteAll()
        #expect(store.recentSessions(limit: 10).isEmpty)
    }
}
