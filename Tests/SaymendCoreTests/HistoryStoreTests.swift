import Foundation
import GRDB
import Testing
@testable import SaymendCore

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

    // MARK: - 辨識品質診斷（issue #10）

    @Test func asrDiagnosticRoundTripsAndOrdersByTime() throws {
        let store = try makeStore()
        store.beginSession(.init(id: "s", startedAt: Date(timeIntervalSince1970: 1000),
                                 appBundleID: nil, appName: nil, targetKind: "tail", finalText: nil))
        store.recordASRDiagnostic(.init(sessionID: "s", at: Date(timeIntervalSince1970: 1002),
                                        finalizedText: "後說的", minAvgLogprob: -0.20,
                                        maxCompressionRatio: 1.10, segmentCount: 1))
        store.recordASRDiagnostic(.init(sessionID: "s", at: Date(timeIntervalSince1970: 1001),
                                        finalizedText: "先說的", minAvgLogprob: -0.85,
                                        maxCompressionRatio: 2.40, segmentCount: 3))
        let rows = store.asrDiagnostics(sessionID: "s")
        #expect(rows.map(\.finalizedText) == ["先說的", "後說的"])
        #expect(rows[0].minAvgLogprob == -0.85)
        #expect(rows[0].maxCompressionRatio == 2.40)
        #expect(rows[0].segmentCount == 3)
    }

    /// 診斷只是輔助資料，生命週期必須完全跟著 session——
    /// 不能出現「歷史清掉了，但使用者說過的話還留在診斷表裡」。
    @Test func purgeAndDeleteAllAlsoWipeDiagnostics() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        store.beginSession(.init(id: "old", startedAt: old, appBundleID: nil, appName: nil,
                                 targetKind: "tail", finalText: nil))
        store.recordASRDiagnostic(.init(sessionID: "old", at: old, finalizedText: "舊的話",
                                        minAvgLogprob: -0.5, maxCompressionRatio: 1.2, segmentCount: 1))
        store.beginSession(.init(id: "new", startedAt: Date(), appBundleID: nil, appName: nil,
                                 targetKind: "tail", finalText: nil))
        store.recordASRDiagnostic(.init(sessionID: "new", at: Date(), finalizedText: "新的話",
                                        minAvgLogprob: -0.4, maxCompressionRatio: 1.1, segmentCount: 1))
        store.purge(olderThanDays: 30)
        #expect(store.asrDiagnostics(sessionID: "old").isEmpty)      // FK cascade
        #expect(store.asrDiagnostics(sessionID: "new").count == 1)
        store.deleteAll()
        #expect(store.asrDiagnostics(sessionID: "new").isEmpty)
    }

    /// v1 時期建立的資料庫要能就地升級：使用者的既有歷史不得因為加一張診斷表而重建或消失
    @Test func existingV1DatabaseMigratesInPlace() throws {
        let dbQueue = try DatabaseQueue()
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1") { db in
            try db.create(table: "history_session") { t in
                t.primaryKey("id", .text)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("targetKind", .text).notNull()
                t.column("finalText", .text)
            }
            try db.create(table: "history_exchange") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionID", .text).notNull().indexed()
                    .references("history_session", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("utteranceRaw", .text).notNull()
                t.column("outcomeKind", .text).notNull()
                t.column("outcomeText", .text)
            }
        }
        try v1.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO history_session (id, startedAt, targetKind) VALUES ('舊', '2026-01-01 00:00:00.000', 'tail')
                """)
        }
        let store = try GRDBHistoryStore(databaseQueue: dbQueue)   // v2 就地補上診斷表
        #expect(store.recentSessions(limit: 10).map(\.id) == ["舊"])
        store.recordASRDiagnostic(.init(sessionID: "舊", at: Date(timeIntervalSince1970: 0),
                                        finalizedText: "升級後才記的",
                                        minAvgLogprob: -0.3, maxCompressionRatio: 1.5, segmentCount: 1))
        #expect(store.asrDiagnostics(sessionID: "舊").count == 1)
    }
}
