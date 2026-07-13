import Foundation

/// Per-app profile（規格 §4.6 App Profile 快取＋§4.7 FrontAppInfo）。
/// 能力欄位 nil＝尚未探測；Bool＝探測或內建庫的已知結果。
public struct AppProfile: Codable, Equatable, Sendable {
    public var bundleID: String
    public var boundsForRangeCapable: Bool?
    public var axInsertCapable: Bool?
    public var fixedLanguage: OutputLanguage?
    /// prompt 第 5 層 per-app 追加（風格指令，如「口語、可用 emoji」）
    public var extraPrompt: String?
    public var vocabEnabled: Bool
    /// Cmd+C 選取讀取備援白名單（M3 互審裁決：不盲發，profile 明示才觸發）
    public var cmdCSelectionFallback: Bool

    public init(bundleID: String,
                boundsForRangeCapable: Bool? = nil,
                axInsertCapable: Bool? = nil,
                fixedLanguage: OutputLanguage? = nil,
                extraPrompt: String? = nil,
                vocabEnabled: Bool = true,
                cmdCSelectionFallback: Bool = false) {
        self.bundleID = bundleID
        self.boundsForRangeCapable = boundsForRangeCapable
        self.axInsertCapable = axInsertCapable
        self.fixedLanguage = fixedLanguage
        self.extraPrompt = extraPrompt
        self.vocabEnabled = vocabEnabled
        self.cmdCSelectionFallback = cmdCSelectionFallback
    }

    /// 內建常見 App 預設庫（規格 §4.6；隨手動測試矩陣回填）
    public static let builtinDefaults: [String: AppProfile] = [
        "com.tinyspeck.slackmacgap": AppProfile(
            bundleID: "com.tinyspeck.slackmacgap",
            boundsForRangeCapable: false,
            extraPrompt: "目標是 Slack 訊息：口語、簡潔，保留表情符號。",
            cmdCSelectionFallback: true),
        "com.google.Chrome": AppProfile(
            bundleID: "com.google.Chrome",
            boundsForRangeCapable: false,
            cmdCSelectionFallback: true),
        "com.microsoft.VSCode": AppProfile(
            bundleID: "com.microsoft.VSCode",
            boundsForRangeCapable: false,
            extraPrompt: "目標是程式編輯器：識別字與程式碼片段原樣保留，不加句號。",
            cmdCSelectionFallback: true),
        "com.apple.Terminal": AppProfile(
            bundleID: "com.apple.Terminal",
            extraPrompt: "目標是終端機：輸出指令原樣，不加標點、不加解釋。"),
        "com.apple.Notes": AppProfile(bundleID: "com.apple.Notes"),
        "com.apple.mail": AppProfile(
            bundleID: "com.apple.mail",
            extraPrompt: "目標是郵件：語氣正式完整。"),
        "com.apple.TextEdit": AppProfile(bundleID: "com.apple.TextEdit", boundsForRangeCapable: true),
        "com.apple.Stickies": AppProfile(bundleID: "com.apple.Stickies"),
    ]
}

public protocol AppProfileStore: AnyObject {
    /// 一定回傳可用 profile：使用者覆寫 > 內建預設庫 > 全空白新 profile
    func profile(for bundleID: String) -> AppProfile
    func update(_ profile: AppProfile)
}

/// JSON 檔實作（profile 資料量小，可手編；歷史才用 SQLite——M4 設計裁決 1）
public final class FileAppProfileStore: AppProfileStore {
    private let fileURL: URL
    private var overrides: [String: AppProfile]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: AppProfile].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    public func profile(for bundleID: String) -> AppProfile {
        overrides[bundleID]
            ?? AppProfile.builtinDefaults[bundleID]
            ?? AppProfile(bundleID: bundleID)
    }

    public func update(_ profile: AppProfile) {
        overrides[profile.bundleID] = profile
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
