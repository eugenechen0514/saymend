import CoreGraphics
import Foundation

/// 熱鍵選項（規格 §3.1；修飾鍵需走 CGEventTap）
public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case rightCommand
    case rightOption
    case rightControl

    public var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    public var flagMask: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: return "右 Command"
        case .rightOption: return "右 Option"
        case .rightControl: return "右 Control"
        }
    }
}

/// App 設定（規格 §4.9）。一般值進 UserDefaults；API key 進 SecretStore。
///
/// `@unchecked Sendable`（三件事誠實揭露，勿以「stored 全 let」誤讀）：
/// ① `defaults`（UserDefaults）與 `secrets`（SecretStore）皆為 `let`、底層 thread-safe。
/// ② `sessionLanguageOverride`／`sessionCoreModeID` 是兩個純記憶體 stored `var`，MainActor-by-convention
///    （非編譯器強制）；本標記**不**為其提供跨執行緒安全，僅約定由 MainActor 存取，標記前後風險不變。
/// ③ 本標記只是把既有 de facto 契約顯式化：M1 起 `OpenAICompatProvider.complete()` 已在背景 executor
///    呼叫 `configProvider()`（即 defaults/secrets-backed 存取早已跨執行緒），非新開風險。
public final class AppSettings: @unchecked Sendable {
    public static let apiKeyKey = "openaiCompatAPIKey"
    public static let whisperAPIKeyKey = "whisperAPIKey"   // 與 LLM key 分離：可能是不同服務

    private enum K {
        static let hotkey = "hotkey"
        static let outputLanguage = "outputLanguage"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let asrLocale = "asrLocaleIdentifier"
        static let customSystemPrompt = "customSystemPrompt"
        static let styleRulesOverride = "styleRulesOverride"
        static let historyEnabled = "historyEnabled"
        static let historyRetentionDays = "historyRetentionDays"
        static let ocrContextEnabled = "ocrContextEnabled"
        static let defaultCoreModeID = "defaultCoreModeID"
        static let providerKind = "providerKind"
        static let cliPathOverride = "claudeCLIPathOverride"
        static let cliModel = "claudeCLIModel"
        static let oaiPolishTimeout = "oaiPolishTimeout"
        static let oaiEditTimeout = "oaiEditTimeout"
        static let cliPolishTimeout = "cliPolishTimeout"
        static let cliEditTimeout = "cliEditTimeout"
        static let asrEngineKind = "asrEngineKind"
        static let whisperBaseURL = "whisperBaseURLString"
        static let whisperModel = "whisperModel"
        static let whisperTimeout = "whisperTimeout"
        static let whisperLocalModelPath = "whisperLocalModelPath"
        static let whisperLocalScanRoots = "whisperLocalScanRoots"
        static let whisperModelWaitTimeout = "whisperModelWaitTimeout"
        // 串流參數（issue #15）。key 名一旦改動，既有使用者調好的值就等同被清空，
        // `WhisperStreamingSettingsTests` 以字面值釘住這幾個名字。
        static let streamRequiredSegments = "whisperStreamRequiredSegments"
        static let streamSilenceThreshold = "whisperStreamSilenceThreshold"
        static let streamUseVAD = "whisperStreamUseVAD"
        static let streamEnergyWindow = "whisperStreamEnergyWindow"
        static let streamCompressionCheckWindow = "whisperStreamCompressionCheckWindow"
        static let streamLogProbThreshold = "whisperStreamLogProbThreshold"
        static let streamCompressionRatioThreshold = "whisperStreamCompressionRatioThreshold"

        /// 「還原預設」移除的 key 集合。少列一個就會出現「按了還原但那一項沒回去」的鬼打牆。
        static let allStreamKeys = [
            streamRequiredSegments, streamSilenceThreshold, streamUseVAD, streamEnergyWindow,
            streamCompressionCheckWindow, streamLogProbThreshold, streamCompressionRatioThreshold,
        ]
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var hotkey: HotkeyChoice {
        get { defaults.string(forKey: K.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: K.hotkey) }
    }

    public var outputLanguage: OutputLanguage {
        get { defaults.string(forKey: K.outputLanguage).flatMap(OutputLanguage.init(rawValue:)) ?? .followSpeech }
        set { defaults.set(newValue.rawValue, forKey: K.outputLanguage) }
    }

    public var llmBaseURLString: String {
        get { defaults.string(forKey: K.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: K.llmBaseURL) }
    }

    public var llmModel: String {
        get { defaults.string(forKey: K.llmModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: K.llmModel) }
    }

    public var asrLocaleIdentifier: String {
        get { defaults.string(forKey: K.asrLocale) ?? "zh-TW" }
        set { defaults.set(newValue, forKey: K.asrLocale) }
    }

    // MARK: - ASR 引擎（M8 spec §3.4）

    public var asrEngineKind: ASREngineKind {
        get { defaults.string(forKey: K.asrEngineKind).flatMap(ASREngineKind.init(rawValue:)) ?? .speechAnalyzer }
        set { defaults.set(newValue.rawValue, forKey: K.asrEngineKind) }
    }

    public var whisperBaseURLString: String {
        get { defaults.string(forKey: K.whisperBaseURL) ?? "" }
        set { defaults.set(newValue, forKey: K.whisperBaseURL) }
    }

    public var whisperModel: String {
        get { defaults.string(forKey: K.whisperModel) ?? "whisper-1" }
        set { defaults.set(newValue, forKey: K.whisperModel) }
    }

    public var whisperAPIKey: String? {
        get { try? secrets.get(forKey: Self.whisperAPIKeyKey) }
        set {
            if let v = newValue, !v.isEmpty {
                try? secrets.set(v, forKey: Self.whisperAPIKeyKey)
            } else {
                try? secrets.delete(forKey: Self.whisperAPIKeyKey)
            }
        }
    }

    /// 預設取 timeoutRange 上限：滿 10 分鐘錄音約 19MB，60s 內完成上傳＋辨識並不保險（spec §6.2）
    public var whisperTimeout: TimeInterval {
        get { readTimeout(K.whisperTimeout, default: 120) }
        set { defaults.set(newValue, forKey: K.whisperTimeout) }
    }

    /// base URL 未設定或非法時回 nil——呼叫端據此 fail-closed（spec §4.7）
    public func whisperConfig() -> WhisperRemoteConfig? {
        let raw = whisperBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return WhisperRemoteConfig(baseURL: url, apiKey: whisperAPIKey,
                                   model: whisperModel, timeout: whisperTimeout)
    }

    // MARK: - 本機 WhisperKit（M9 spec §5）

    public var whisperLocalModelPath: URL? {
        get { defaults.string(forKey: K.whisperLocalModelPath).map { URL(filePath: $0) } }
        set { defaults.set(newValue?.path, forKey: K.whisperLocalModelPath) }
    }

    public var whisperLocalScanRoots: [URL] {
        get { (defaults.array(forKey: K.whisperLocalScanRoots) as? [String] ?? []).map { URL(filePath: $0) } }
        set { defaults.set(newValue.map(\.path), forKey: K.whisperLocalScanRoots) }
    }

    /// 永回非 optional：selectedModelPath 為 nil 時交引擎映射「未選擇本機模型」（契約單一）
    public func whisperLocalConfig() -> WhisperLocalConfig {
        WhisperLocalConfig(selectedModelPath: whisperLocalModelPath,
                           extraScanRoots: whisperLocalScanRoots,
                           modelWaitTimeout: whisperModelWaitTimeout)
    }

    /// 聽寫時等模型載入的上限（秒，issue #17）。
    ///
    /// **逾時只放棄這次聽寫，不中止載入**——ANE 載入是同步 XPC 等待，停不掉
    /// （見 `awaitBounded`）。載入會繼續在背景跑完，下一次聽寫就能用。
    ///
    /// 預設 15 秒的依據不是量測而是使用情境：使用者正按著熱鍵站在那裡，冷載入
    /// （實測 543～1297 秒）不可能在他還記得要講什麼的時間內完成；暖快取實測 2.26 秒。
    /// 讀取防線比照 `readInt`：超界或型別不符**回落預設而非夾到邊界**——邊界是使用者
    /// 從未選過的值。
    public var whisperModelWaitTimeout: TimeInterval {
        get {
            guard let v = defaults.object(forKey: K.whisperModelWaitTimeout) as? Double,
                  v.isFinite, Self.modelWaitTimeoutRange.contains(v) else { return 15 }
            return v
        }
        set { defaults.set(newValue, forKey: K.whisperModelWaitTimeout) }
    }

    /// 下限 5 秒：再短連暖快取（實測 2.26 秒）都可能來不及。
    /// 上限 600 秒：超過十分鐘還按著熱鍵等，已經不是「等一下」而是該去做別的事了。
    public static let modelWaitTimeoutRange: ClosedRange<Double> = 5...600

    // MARK: - 本機串流參數（issue #15）
    //
    // 讀取防線比照 `readTimeout`：缺失／型別不符／非有限／超出合理範圍一律**回落套件預設**，
    // 不夾到邊界值——邊界是使用者從未選過的值，套件預設才是已知良好的那個。
    // 設定與模型無關，換模型不影響（`streamingOptionsSurviveModelChange`）。

    public var streamRequiredSegments: Int {
        get {
            readInt(K.streamRequiredSegments,
                    default: WhisperStreamingOptions.packageDefault.requiredSegmentsForConfirmation,
                    in: WhisperStreamingOptions.requiredSegmentsRange)
        }
        set { defaults.set(newValue, forKey: K.streamRequiredSegments) }
    }

    public var streamSilenceThreshold: Double {
        get {
            readDouble(K.streamSilenceThreshold,
                       default: Double(WhisperStreamingOptions.packageDefault.silenceThreshold),
                       in: WhisperStreamingOptions.silenceThresholdRange)
        }
        set { defaults.set(newValue, forKey: K.streamSilenceThreshold) }
    }

    public var streamUseVAD: Bool {
        get { defaults.object(forKey: K.streamUseVAD) as? Bool ?? WhisperStreamingOptions.packageDefault.useVAD }
        set { defaults.set(newValue, forKey: K.streamUseVAD) }
    }

    public var streamRelativeEnergyWindow: Int {
        get {
            readInt(K.streamEnergyWindow,
                    default: WhisperStreamingOptions.packageDefault.relativeEnergyWindow,
                    in: WhisperStreamingOptions.relativeEnergyWindowRange)
        }
        set { defaults.set(newValue, forKey: K.streamEnergyWindow) }
    }

    public var streamCompressionCheckWindow: Int {
        get {
            readInt(K.streamCompressionCheckWindow,
                    default: WhisperStreamingOptions.packageDefault.compressionCheckWindow,
                    in: WhisperStreamingOptions.compressionCheckWindowRange)
        }
        set { defaults.set(newValue, forKey: K.streamCompressionCheckWindow) }
    }

    public var streamLogProbThreshold: Double {
        get {
            readDouble(K.streamLogProbThreshold,
                       default: Double(WhisperStreamingOptions.packageLogProbThreshold),
                       in: WhisperStreamingOptions.logProbThresholdRange)
        }
        set { defaults.set(newValue, forKey: K.streamLogProbThreshold) }
    }

    public var streamCompressionRatioThreshold: Double {
        get {
            readDouble(K.streamCompressionRatioThreshold,
                       default: Double(WhisperStreamingOptions.packageCompressionRatioThreshold),
                       in: WhisperStreamingOptions.compressionRatioThresholdRange)
        }
        set { defaults.set(newValue, forKey: K.streamCompressionRatioThreshold) }
    }

    /// 串流辨識參數。**每次呼叫現讀**（不做啟動快照），故設定改完下一次聽寫就生效。
    public func whisperStreamingOptions() -> WhisperStreamingOptions {
        WhisperStreamingOptions(
            requiredSegmentsForConfirmation: streamRequiredSegments,
            silenceThreshold: Float(streamSilenceThreshold),
            useVAD: streamUseVAD,
            relativeEnergyWindow: streamRelativeEnergyWindow,
            compressionCheckWindow: streamCompressionCheckWindow,
            logProbThreshold: Float(streamLogProbThreshold),
            compressionRatioThreshold: Float(streamCompressionRatioThreshold))
    }

    /// 「還原預設」：移除 key 而非寫入一份預設值的複本，讓狀態回到與從未調過完全相同。
    public func resetStreamingOptions() {
        for key in K.allStreamKeys { defaults.removeObject(forKey: key) }
    }

    /// 整數版讀取防線。型別不符（舊版寫成字串、手改 plist）與超範圍都回預設。
    private func readInt(_ key: String, default def: Int, in range: ClosedRange<Int>) -> Int {
        guard let v = defaults.object(forKey: key) as? Int, range.contains(v) else { return def }
        return v
    }

    /// 浮點版讀取防線。
    ///
    /// **誠實說明**：`isFinite` 這一關在此是冗餘的——NaN 的所有比較都是 false，範圍檢查
    /// 本來就會擋下它；±Inf 也一樣超界。它擋得住的輸入，範圍檢查也擋得住，因此**測試無法
    /// 單獨驅動它**。保留是因為「不是數字」與「超出範圍」是兩種不同的損毀，各自寫明比
    /// 倚賴 NaN 比較語意的巧合來得清楚（`readTimeout` 亦同）。不得宣稱它有測試覆蓋。
    private func readDouble(_ key: String, default def: Double, in range: ClosedRange<Float>) -> Double {
        guard let v = defaults.object(forKey: key) as? Double, v.isFinite else { return def }
        guard v >= Double(range.lowerBound), v <= Double(range.upperBound) else { return def }
        return v
    }

    /// prompt 第 4 層：使用者全域自訂 system prompt（規格 §4.4；空字串＝未設定）
    public var customSystemPrompt: String {
        get { defaults.string(forKey: K.customSystemPrompt) ?? "" }
        set { defaults.set(newValue, forKey: K.customSystemPrompt) }
    }

    /// prompt 第 3 層覆寫：nil＝用內建預設（規格 §4.11「做成可編輯的輸出風格設定」）
    public var styleRulesOverride: String? {
        get {
            let v = defaults.string(forKey: K.styleRulesOverride)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: K.styleRulesOverride) }
    }

    /// 聽寫歷史開關（規格 §4.9；預設開，供回查除錯）
    public var historyEnabled: Bool {
        get { defaults.object(forKey: K.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: K.historyEnabled) }
    }

    /// OCR 螢幕語境備援開關（規格 §4.7）。預設關（opt-in）：螢幕擷取最具侵入性，
    /// 由使用者明確開啟才動用。開啟後仍受既有降級序節制——僅在 AX 讀不到前後文、
    /// 非安全欄位、且螢幕錄製權限已授權時才實際截圖。
    public var ocrContextEnabled: Bool {
        get { defaults.object(forKey: K.ocrContextEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: K.ocrContextEnabled) }
    }

    /// 歷史保留天數（規格 §4.9「可設保留天數」；啟動時清除過期）
    public var historyRetentionDays: Int {
        get {
            let v = defaults.integer(forKey: K.historyRetentionDays)
            return v > 0 ? v : 30
        }
        set { defaults.set(newValue, forKey: K.historyRetentionDays) }
    }

    /// per-session 臨時語系覆蓋（規格 §4.5 快速切換）。純記憶體：不持久化，
    /// session 封存時由 DictationController 清除。解析序：本值 > profile 固定語系 > outputLanguage。
    public var sessionLanguageOverride: OutputLanguage?

    /// 全域預設核心模式（規格 §3.2）。nil＝未設定，解析式落到內建預設。
    public var defaultCoreModeID: String? {
        get { defaults.string(forKey: K.defaultCoreModeID) }
        set {
            if let v = newValue { defaults.set(v, forKey: K.defaultCoreModeID) }
            else { defaults.removeObject(forKey: K.defaultCoreModeID) }
        }
    }

    /// per-session 臨時核心模式覆蓋（規格 §3.2）。純記憶體、不寫 UserDefaults。
    /// Session 封存時由 DictationController.archiveSession 清除。
    public var sessionCoreModeID: String?

    public var llmAPIKey: String? {
        get { try? secrets.get(forKey: Self.apiKeyKey) }
        set {
            if let v = newValue, !v.isEmpty {
                try? secrets.set(v, forKey: Self.apiKeyKey)
            } else {
                try? secrets.delete(forKey: Self.apiKeyKey)
            }
        }
    }

    public func openAIConfig() -> OpenAICompatConfig {
        let url = URL(string: llmBaseURLString) ?? URL(string: "https://api.openai.com/v1")!
        return OpenAICompatConfig(baseURL: url, apiKey: llmAPIKey, model: llmModel)
    }

    // MARK: - Provider 選擇與 per-provider timeout（spec §5/§6）

    /// 使用者設定值合法範圍（configured deadline；runner 收到的剩餘 budget 不在此限——spec §5）
    public static let timeoutRange: ClosedRange<TimeInterval> = 1...120

    public var providerKind: ProviderKind {
        get { defaults.string(forKey: K.providerKind).flatMap(ProviderKind.init(rawValue:)) ?? .openAICompat }
        set { defaults.set(newValue.rawValue, forKey: K.providerKind) }
    }

    public var claudeCLIPathOverride: String? {
        get {
            let v = defaults.string(forKey: K.cliPathOverride)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: K.cliPathOverride) }
    }

    public var claudeCLIModel: String {
        get { defaults.string(forKey: K.cliModel) ?? "sonnet" }   // spike 定案
        set { defaults.set(newValue, forKey: K.cliModel) }
    }

    /// 讀取防線（spec §5）：缺失／非數值／NaN／Inf／超出 [1,120] 一律回該 provider 預設值。
    private func readTimeout(_ key: String, default def: TimeInterval) -> TimeInterval {
        guard let v = defaults.object(forKey: key) as? Double, v.isFinite,
              Self.timeoutRange.contains(v) else { return def }
        return v
    }

    public var oaiPolishTimeout: TimeInterval {
        get { readTimeout(K.oaiPolishTimeout, default: 3.0) }
        set { defaults.set(newValue, forKey: K.oaiPolishTimeout) }
    }
    public var oaiEditTimeout: TimeInterval {
        get { readTimeout(K.oaiEditTimeout, default: 6.0) }
        set { defaults.set(newValue, forKey: K.oaiEditTimeout) }
    }
    public var cliPolishTimeout: TimeInterval {
        get { readTimeout(K.cliPolishTimeout, default: 20.0) }     // spike 定案（單句 ~5s、並行近序列 14.6s）
        set { defaults.set(newValue, forKey: K.cliPolishTimeout) }
    }
    public var cliEditTimeout: TimeInterval {
        get { readTimeout(K.cliEditTimeout, default: 20.0) }
        set { defaults.set(newValue, forKey: K.cliEditTimeout) }
    }

    public func providerTimeouts(for kind: ProviderKind) -> (polish: TimeInterval, edit: TimeInterval) {
        switch kind {
        case .openAICompat: return (oaiPolishTimeout, oaiEditTimeout)
        case .claudeCLI: return (cliPolishTimeout, cliEditTimeout)
        }
    }

    public func claudeCLIConfig() -> ClaudeCLIConfig {
        ClaudeCLIConfig(cliPathOverride: claudeCLIPathOverride, model: claudeCLIModel)
    }
}
