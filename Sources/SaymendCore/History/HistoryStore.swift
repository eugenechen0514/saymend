import Foundation
import GRDB

/// 聽寫歷史（規格 §4.9）：每 session 一筆＋每 utterance 一筆 exchange。
/// 收斂裁決（M4 設計裁決 7）：不存 LLM 完整 prompt（含前後文/OCR，隱私面大）；
/// raw＋outcome 已足回查除錯。secure session 從不開帳，天然不留史。
public struct HistorySessionRecord: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "history_session"
    public var id: String
    public var startedAt: Date
    public var appBundleID: String?
    public var appName: String?
    public var targetKind: String        // "tail" | "selection"
    public var finalText: String?

    public init(id: String, startedAt: Date, appBundleID: String?, appName: String?,
                targetKind: String, finalText: String?) {
        self.id = id
        self.startedAt = startedAt
        self.appBundleID = appBundleID
        self.appName = appName
        self.targetKind = targetKind
        self.finalText = finalText
    }
}

public struct HistoryExchangeRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "history_exchange"
    public var id: Int64?
    public var sessionID: String
    public var at: Date
    public var utteranceRaw: String
    public var outcomeKind: String       // "newContent" | "editedSession" | "undo" | "degraded" | "insertFailed" | "insertSkipped"
    public var outcomeText: String?

    public init(id: Int64? = nil, sessionID: String, at: Date, utteranceRaw: String,
                outcomeKind: String, outcomeText: String?) {
        self.id = id
        self.sessionID = sessionID
        self.at = at
        self.utteranceRaw = utteranceRaw
        self.outcomeKind = outcomeKind
        self.outcomeText = outcomeText
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public protocol HistoryRecording: AnyObject {
    func beginSession(_ record: HistorySessionRecord)
    func recordExchange(_ record: HistoryExchangeRecord)
    func finishSession(id: String, finalText: String?)
    func recentSessions(limit: Int) -> [HistorySessionRecord]
    func exchanges(sessionID: String) -> [HistoryExchangeRecord]
    func purge(olderThanDays: Int)
    func deleteAll()
}

/// GRDB SQLite 實作。寫入全部 try?（歷史是輔助功能，失敗不得影響聽寫主流程）。
public final class GRDBHistoryStore: HistoryRecording {
    private let dbQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) throws {
        dbQueue = databaseQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
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
        try migrator.migrate(dbQueue)
    }

    /// App 用：`~/Library/Application Support/Saymend/history.sqlite`
    public static func onDisk(directory: URL) throws -> GRDBHistoryStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: directory.appendingPathComponent("history.sqlite").path)
        return try GRDBHistoryStore(databaseQueue: dbQueue)
    }

    // 聽寫路徑的寫入一律 asyncWrite（終審 finding）：呼叫端是 @MainActor 的
    // DictationController，同步 write 會把磁碟 I/O 押在主執行緒上——DB 鎖住/爭用時聽寫會頓。
    // 歷史是輔助功能且本就 try? 吞錯，失敗靜默即可；GRDB 的 asyncWrite 保證同佇列序列化，
    // begin→exchange→finish 的順序不變。

    public func beginSession(_ record: HistorySessionRecord) {
        dbQueue.asyncWrite({ try record.insert($0) }, completion: { _, _ in })
    }

    public func recordExchange(_ record: HistoryExchangeRecord) {
        dbQueue.asyncWrite({ try record.insert($0) }, completion: { _, _ in })
    }

    public func finishSession(id: String, finalText: String?) {
        dbQueue.asyncWrite({ db in
            try db.execute(sql: "UPDATE history_session SET finalText = ? WHERE id = ?",
                           arguments: [finalText, id])
        }, completion: { _, _ in })
    }

    public func recentSessions(limit: Int) -> [HistorySessionRecord] {
        (try? dbQueue.read { db in
            try HistorySessionRecord
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    public func exchanges(sessionID: String) -> [HistoryExchangeRecord] {
        (try? dbQueue.read { db in
            try HistoryExchangeRecord
                .filter(Column("sessionID") == sessionID)
                .order(Column("at"))
                .fetchAll(db)
        }) ?? []
    }

    public func purge(olderThanDays days: Int) {
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86400)
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history_session WHERE startedAt < ?", arguments: [cutoff])
        }   // exchange 由 FK cascade 連帶清
    }

    public func deleteAll() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history_session")
        }
    }
}

public extension IntentOutcome {
    /// 歷史記錄用的種類字串與文字（規格 §4.9）
    var historyKind: String {
        switch self {
        case .newContent: return "newContent"
        case .editedSession: return "editedSession"
        case .undo: return "undo"
        case .degraded: return "degraded"
        }
    }
    var historyText: String? {
        switch self {
        case .newContent(let t), .editedSession(let t): return t
        case .degraded(let reason): return reason
        case .undo: return nil
        }
    }
}
