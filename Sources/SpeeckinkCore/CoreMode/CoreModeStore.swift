import Foundation

public protocol CoreModeStore: AnyObject {
    func allUserModes() -> [CoreMode]
    func add(_ mode: CoreMode) throws
    func update(_ mode: CoreMode) throws
    func delete(id: String) throws
}

public enum CoreModeStoreError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case emptySystemRules
    case invalidID
    case duplicateID
    case builtinMutationForbidden
    case systemRulesTooLong
    case rewriteSemanticViolation(reasons: [String])
    case forbiddenUnicode
    case contractMarkerCollision
    case modeNotFound
    case persistenceFailed
}

private struct CoreModeFile: Codable {
    let version: Int
    var userModes: [CoreMode]
}

public final class FileCoreModeStore: CoreModeStore {
    private let fileURL: URL
    private var userModes: [CoreMode]
    private let builtinIDs: Set<String>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.builtinIDs = Set(PromptAssembler.builtinCoreModes.map(\.id))
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            self.userModes = []
            return
        }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            // 0-byte 視為初始空（**不是 corrupt**）
            self.userModes = []
            return
        }
        guard let decoded = try? JSONDecoder.iso8601.decode(CoreModeFile.self, from: data),
              decoded.version == 1 else {
            Self.backupCorrupt(fileURL)
            self.userModes = []
            return
        }
        // 逐筆 validator；任一失敗備份並降級
        var validated: [CoreMode] = []
        for mode in decoded.userModes {
            if (try? Self.validate(mode, isNew: false, builtinIDs: builtinIDs)) != nil {
                validated.append(mode)
            } else {
                Self.backupCorrupt(fileURL)
                validated = []
                break
            }
        }
        self.userModes = validated
    }

    public func allUserModes() -> [CoreMode] { userModes }

    public func add(_ mode: CoreMode) throws {
        try Self.validate(mode, isNew: true, builtinIDs: builtinIDs)
        guard !userModes.contains(where: { $0.id == mode.id }) else {
            throw CoreModeStoreError.duplicateID
        }
        var normalized = mode
        normalized.systemRules = try Self.validateSystemRules(mode.systemRules)
        userModes.append(normalized)
        do { try persist() } catch { rollbackAdd(mode.id); throw error }
    }

    public func update(_ mode: CoreMode) throws {
        guard !builtinIDs.contains(mode.id) else {
            throw CoreModeStoreError.builtinMutationForbidden
        }
        try Self.validate(mode, isNew: false, builtinIDs: builtinIDs)
        guard let i = userModes.firstIndex(where: { $0.id == mode.id }) else {
            throw CoreModeStoreError.modeNotFound
        }
        let original = userModes[i]
        var normalized = mode
        normalized.systemRules = try Self.validateSystemRules(mode.systemRules)
        userModes[i] = normalized
        do { try persist() } catch { rollbackUpdate(original); throw error }
    }

    public func delete(id: String) throws {
        guard !builtinIDs.contains(id) else {
            throw CoreModeStoreError.builtinMutationForbidden
        }
        let before = userModes.count
        userModes.removeAll { $0.id == id }
        guard userModes.count < before else { throw CoreModeStoreError.modeNotFound }
        do { try persist() } catch { /* 記憶體已刪；disk 失敗下次啟動重新計算可恢復；不可回丟已刪資料給使用者 */ throw CoreModeStoreError.persistenceFailed }
    }

    // MARK: - Validation
    static let systemRulesMaxChars = 8_000
    static let nameMaxChars = 80

    /// 控制字元黑名單排除 \t\n\r——這三個是合法的多行格式字元，systemRules 本來就是
    /// 多行文字（內建模式與『新增模式』預載的範本都含真實換行）；不排除的話任何多行
    /// 規則都會被誤判為 forbiddenUnicode，Task 11 手動驗證時發現連預載範本都存不了。
    ///
    /// SPEC §3.3 明文只列「允許 \t 與 \n」，此處額外允許 \r（0x0D）：
    /// §3.3 的措辭是「禁止字元集合至少包含」＝下限而非上限，未禁止擴張允許清單。
    /// \r 是行分隔符（Windows CRLF 貼上），非隱形注入字元，威脅性質與 zero-width／bidi 不同；
    /// 拒絕它會讓貼上的多行規則失敗。與 EnvelopeParser 的 allowedWhitespace 保持一致，
    /// 避免兩處字元規則分歧——本 bug（bb5d687）正是兩處分歧造成的。
    private static let forbiddenScalars: Set<Unicode.Scalar> = {
        var s: Set<Unicode.Scalar> = []
        let allowedWhitespace: Set<UInt32> = [0x09, 0x0A, 0x0D]  // \t \n \r
        for u: UInt32 in 0x0000...0x001F where !allowedWhitespace.contains(u) {
            if let sc = Unicode.Scalar(u) { s.insert(sc) }
        }
        for u: UInt32 in 0x007F...0x009F { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        s.insert(Unicode.Scalar(0x200B)!); s.insert(Unicode.Scalar(0x200C)!)
        s.insert(Unicode.Scalar(0x200D)!); s.insert(Unicode.Scalar(0x2060)!); s.insert(Unicode.Scalar(0xFEFF)!)
        s.insert(Unicode.Scalar(0x061C)!); s.insert(Unicode.Scalar(0x200E)!); s.insert(Unicode.Scalar(0x200F)!)
        for u: UInt32 in 0x202A...0x202E { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        for u: UInt32 in 0x2066...0x2069 { if let sc = Unicode.Scalar(u) { s.insert(sc) } }
        return s
    }()

    static func containsForbiddenScalar(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: { forbiddenScalars.contains($0) })
    }

    /// **UI 與 store 共用的唯一 validator**（非拋出版，供編輯器即時驗證）。
    /// App 層**不可**重寫另一份驗證邏輯，也不可自行呼叫 RewriteSemanticDetector——
    /// 一律走這個入口，確保 UI 顯示的錯誤與 store 實際拒絕的理由完全一致。
    /// 回 nil ＝ 通過。錯誤優先序與 store 的 throw 順序相同。
    public static func validateDraft(name: String, systemRules: String) -> CoreModeStoreError? {
        // ── name：NFC → trim → 空 → 長度 → Unicode → marker → 覆寫語義
        let nameTrim = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if nameTrim.isEmpty { return .emptyName }
        if nameTrim.count > nameMaxChars { return .nameTooLong }
        if containsForbiddenScalar(nameTrim) { return .forbiddenUnicode }
        if nameTrim.contains(contractMarkerStart) || nameTrim.contains(contractMarkerEnd) {
            return .contractMarkerCollision
        }
        let nameReasons = RewriteSemanticDetector.detect(in: nameTrim)
        if !nameReasons.isEmpty { return .rewriteSemanticViolation(reasons: nameReasons) }

        // ── systemRules：走統一入口（§3.3 固定順序）
        do { _ = try validateSystemRules(systemRules) } catch let e as CoreModeStoreError {
            return e
        } catch {
            return .persistenceFailed
        }
        return nil
    }

    static let contractMarkerStart = "==== MACHINE CONTRACT START ===="
    static let contractMarkerEnd = "==== MACHINE CONTRACT END ===="

    static func validate(_ mode: CoreMode, isNew: Bool, builtinIDs: Set<String>) throws {
        if mode.isBuiltin { throw CoreModeStoreError.builtinMutationForbidden }
        if builtinIDs.contains(mode.id) { throw CoreModeStoreError.builtinMutationForbidden }
        guard UUID(uuidString: mode.id) != nil else { throw CoreModeStoreError.invalidID }
        // name + systemRules 一律走 validateDraft（UI 與 store 同一份規則）
        if let e = validateDraft(name: mode.name, systemRules: mode.systemRules) { throw e }
    }

    /// 統一 systemRules 入口：NFC → forbidden → marker → rewrite → 長度
    public static func validateSystemRules(_ raw: String) throws -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoreModeStoreError.emptySystemRules }
        if containsForbiddenScalar(trimmed) { throw CoreModeStoreError.forbiddenUnicode }
        if trimmed.contains(contractMarkerStart) || trimmed.contains(contractMarkerEnd) {
            throw CoreModeStoreError.contractMarkerCollision
        }
        let reasons = RewriteSemanticDetector.detect(in: trimmed)
        guard reasons.isEmpty else {
            throw CoreModeStoreError.rewriteSemanticViolation(reasons: reasons)
        }
        guard trimmed.count <= systemRulesMaxChars else {
            throw CoreModeStoreError.systemRulesTooLong
        }
        return normalized
    }

    // MARK: - Persist
    private func persist() throws {
        let payload = CoreModeFile(version: 1, userModes: userModes)
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CoreModeStoreError.persistenceFailed
        }
    }

    private func rollbackAdd(_ id: String) {
        userModes.removeAll { $0.id == id }
    }

    private func rollbackUpdate(_ original: CoreMode) {
        if let i = userModes.firstIndex(where: { $0.id == original.id }) {
            userModes[i] = original
        }
    }

    static func backupCorrupt(_ fileURL: URL) {
        let ts = corruptTimestamp()
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(ts)")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    static func corruptTimestamp() -> String {
        // UTC yyyyMMdd'T'HHmmssSSS'Z' — 冒號絕對不可出現
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
