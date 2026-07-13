import Foundation

/// 詞彙表條目（規格 §4.8）：詞彙＋選填常見誤轉寫清單。
public struct VocabEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var phrase: String
    public var mishearings: [String]

    public init(id: UUID = UUID(), phrase: String, mishearings: [String] = []) {
        self.id = id
        self.phrase = phrase
        self.mishearings = mishearings
    }
}

/// 詞彙表存取（注入兩處：LLM prompt 第 6 層＝永遠；ASR contextual strings＝引擎支援才餵）
public protocol VocabStore: AnyObject {
    func all() -> [VocabEntry]
    func upsert(_ entry: VocabEntry)
    func delete(id: UUID)
    /// 匯入 JSON（[VocabEntry] 格式）；phrase 相同＝覆蓋。回傳匯入筆數。
    func importJSON(_ data: Data) throws -> Int
    func exportJSON() throws -> Data
}

/// JSON 檔實作。原子寫入；檔案不存在或損毀＝空表（詞彙表非關鍵資料，寧可清空不炸）。
public final class FileVocabStore: VocabStore {
    private let fileURL: URL
    private var entries: [VocabEntry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VocabEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    public func all() -> [VocabEntry] { entries }

    public func upsert(_ entry: VocabEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    public func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func importJSON(_ data: Data) throws -> Int {
        let incoming = try JSONDecoder().decode([VocabEntry].self, from: data)
        for entry in incoming {
            // phrase 為業務主鍵：同詞覆蓋（不看 id，匯入檔可能來自別台機器）
            entries.removeAll { $0.phrase == entry.phrase }
            entries.append(entry)
        }
        save()
        return incoming.count
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
