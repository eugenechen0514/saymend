import Foundation
import Testing
@testable import SaymendCore

private func freshSettings() -> (AppSettings, UserDefaults) {
    let suite = "test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return (AppSettings(defaults: d, secrets: InMemorySecretStore()), d)
}

@Test func defaultsAreSane() {
    let (s, _) = freshSettings()
    #expect(s.hotkey == .rightCommand)
    #expect(s.outputLanguage == .followSpeech)
    #expect(s.llmBaseURLString == "https://api.openai.com/v1")
    #expect(s.asrLocaleIdentifier == "zh-TW")
}

@Test func settingsRoundTripThroughDefaults() {
    let (s, _) = freshSettings()
    s.hotkey = .rightOption
    s.outputLanguage = .zhTW
    s.llmModel = "llama3"
    #expect(s.hotkey == .rightOption)
    #expect(s.outputLanguage == .zhTW)
    #expect(s.llmModel == "llama3")
}

@Test func apiKeyGoesToSecretStoreOnly() {
    let (s, d) = freshSettings()
    s.llmAPIKey = "sk-secret"
    #expect(s.llmAPIKey == "sk-secret")
    // UserDefaults 裡不得出現 key 內容
    for (_, v) in d.dictionaryRepresentation() {
        if let str = v as? String { #expect(!str.contains("sk-secret")) }
    }
    s.llmAPIKey = nil
    #expect(s.llmAPIKey == nil)
}

@Test func openAIConfigBuiltFromSettings() {
    let (s, _) = freshSettings()
    s.llmBaseURLString = "http://localhost:11434/v1"
    s.llmModel = "qwen3"
    s.llmAPIKey = "k"
    let c = s.openAIConfig()
    #expect(c.baseURL.absoluteString == "http://localhost:11434/v1")
    #expect(c.model == "qwen3")
    #expect(c.apiKey == "k")
}

@Test func hotkeyKeyCodes() {
    #expect(HotkeyChoice.rightCommand.keyCode == 54)
    #expect(HotkeyChoice.rightOption.keyCode == 61)
    #expect(HotkeyChoice.rightControl.keyCode == 62)
}

@Test(
    "真 Keychain 整合測試（預設跳過；SPEECKINK_KEYCHAIN_TESTS=1 才啟用，避免 headless 環境卡解鎖對話框）",
    .enabled(if: ProcessInfo.processInfo.environment["SPEECKINK_KEYCHAIN_TESTS"] == "1")
)
func keychainStoreRoundTrip() throws {
    // 整合測試：使用真 Keychain（login keychain），跑完清掉
    let store = KeychainStore(service: "io.saymend.tests")
    try store.set("v1", forKey: "t")
    #expect(try store.get(forKey: "t") == "v1")
    try store.set("v2", forKey: "t") // 更新路徑
    #expect(try store.get(forKey: "t") == "v2")
    try store.delete(forKey: "t")
    #expect(try store.get(forKey: "t") == nil)
}

@Test func m4SettingsRoundTripWithDefaults() {
    let suite = "test-\(UUID().uuidString)"
    let s = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(s.customSystemPrompt == "")
    #expect(s.styleRulesOverride == nil)
    #expect(s.historyEnabled)
    #expect(s.historyRetentionDays == 30)
    #expect(!s.ocrContextEnabled)          // OCR 預設關（opt-in）
    s.customSystemPrompt = "簽名 --E"
    s.styleRulesOverride = "半形標點"
    s.historyEnabled = false
    s.historyRetentionDays = 7
    s.ocrContextEnabled = true
    let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(reloaded.customSystemPrompt == "簽名 --E")
    #expect(reloaded.styleRulesOverride == "半形標點")
    #expect(!reloaded.historyEnabled)
    #expect(reloaded.historyRetentionDays == 7)
    #expect(reloaded.ocrContextEnabled)    // 開啟後持久化
}

/// issue #46：Esc 退字的兩個設定。key 字面值是 persistence 契約，測試釘死。
@Test func escapeRetractionSettingsDefaultAndPersist() {
    let (s, d) = freshSettings()
    #expect(s.escapeRetractsPolishedText)       // 預設開：取消＝「這次不算」，連已潤飾的一起退
    #expect(!s.escapeRetractsFrozenSession)     // 預設關：凍結後不再改寫欄位的契約優先

    s.escapeRetractsPolishedText = false
    s.escapeRetractsFrozenSession = true
    #expect(d.object(forKey: "escapeRetractsPolishedText") as? Bool == false)
    #expect(d.object(forKey: "escapeRetractsFrozenSession") as? Bool == true)
    let reloaded = AppSettings(defaults: d, secrets: InMemorySecretStore())
    #expect(!reloaded.escapeRetractsPolishedText)
    #expect(reloaded.escapeRetractsFrozenSession)
}

/// 型別錯誤回落各自的預設，而不是 `bool(forKey:)` 的一律 false、也不是把數字 1 當 true。
@Test func escapeRetractionSettingsFallBackToDefaultsOnWrongTypes() {
    let (s, d) = freshSettings()
    d.set("false", forKey: "escapeRetractsPolishedText")
    d.set(1, forKey: "escapeRetractsFrozenSession")
    #expect(s.escapeRetractsPolishedText)
    #expect(!s.escapeRetractsFrozenSession)
}

/// issue #37 的保險絲。key 字面值是 persistence 契約（使用者是用 `defaults write` 操作它的，
/// 改名等同把使用者關掉的閘門偷偷打開），測試釘死字面值。
@Test func rawAppendGateSwitchDefaultsToEnabledAndPersists() {
    let (s, d) = freshSettings()
    #expect(s.rawAppendGateEnabled, "預設開：閘門本身是 #37 的修復，保險絲只是出口")

    s.rawAppendGateEnabled = false
    #expect(d.object(forKey: "rawAppendGateEnabled") as? Bool == false)
    let reloaded = AppSettings(defaults: d, secrets: InMemorySecretStore())
    #expect(!reloaded.rawAppendGateEnabled)
}

/// 型別錯誤回落預設（開）：`defaults write ... -int 0` 之類的誤操作不得被當成「使用者明確關掉閘門」。
/// 這條釘的是 `readBool`（核對 `CFBooleanGetTypeID`）而不是 `object(forKey:) as? Bool`——
/// 後者會讓 NSNumber 0 橋接成 false，等於一個打錯的指令就把 #37 的閘門關掉。
///
/// **測試點刻意用 Int 0 而不是 Int 1**：本設定預設為 true，`as? Bool` 對 NSNumber 1 也回 true，
/// 兩條實作在那個輸入上結果相同、分辨不出來。0 才是會咬人的那一格。
@Test func rawAppendGateSwitchFallsBackToDefaultOnWrongType() {
    let (s, d) = freshSettings()
    d.set(0, forKey: "rawAppendGateEnabled")
    #expect(s.rawAppendGateEnabled, "Int 0 不是 Bool：回落預設 true，不得被當成關閉")
    d.set(1, forKey: "rawAppendGateEnabled")
    #expect(s.rawAppendGateEnabled, "Int 1 同樣不是 Bool（此處與預設同值，僅記錄意圖）")
    d.set("false", forKey: "rawAppendGateEnabled")
    #expect(s.rawAppendGateEnabled, "字串也不是 Bool：回落預設 true")
}

@Test func sessionLanguageOverrideIsTransient() {
    let suite = "test-\(UUID().uuidString)"
    let s = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    s.sessionLanguageOverride = .english
    let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(reloaded.sessionLanguageOverride == nil)   // 不持久化
}

@Test func sessionCoreModeIDDoesNotPersist() {
    let suite = "test-\(UUID().uuidString)"
    let s = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    s.sessionCoreModeID = PromptAssembler.assistantMode.id
    let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(reloaded.sessionCoreModeID == nil)
}

@Test func defaultCoreModeIDPersists() {
    let suite = "test-\(UUID().uuidString)"
    let s = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    s.defaultCoreModeID = PromptAssembler.verbatimTranscriptMode.id
    let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(reloaded.defaultCoreModeID == PromptAssembler.verbatimTranscriptMode.id)
}

// MARK: - Provider 選擇與 per-provider timeout（spec §5/§6）

@Test func providerKindDefaultsToOpenAICompatAndPersists() {
    let (s, _) = freshSettings()
    #expect(s.providerKind == .openAICompat)          // 升級後零行為變化
    s.providerKind = .claudeCLI
    #expect(s.providerKind == .claudeCLI)
}

@Test func claudeCLIConfigDefaults() {
    let (s, _) = freshSettings()
    let c = s.claudeCLIConfig()
    #expect(c.cliPathOverride == nil)
    #expect(c.model == "sonnet")   // spike 定案：haiku 真實長 prompt 圍欄 44-56%、sonnet 0/16
    s.claudeCLIPathOverride = "/opt/x/claude"
    s.claudeCLIModel = "sonnet"
    #expect(s.claudeCLIConfig() == ClaudeCLIConfig(cliPathOverride: "/opt/x/claude", model: "sonnet"))
}

@Test func timeoutDefaultsPerProvider() {
    let (s, _) = freshSettings()
    #expect(s.providerTimeouts(for: .openAICompat) == (3.0, 6.0))
    #expect(s.providerTimeouts(for: .claudeCLI) == (20.0, 20.0))   // spike 定案：並行 14.6s 逼近 15s，提高到 20
}

@Test func timeoutReadClampsInvalidPersistedValues() {
    let (s, _) = freshSettings()
    s.cliPolishTimeout = 30
    #expect(s.cliPolishTimeout == 30)                 // 合法值原樣
    s.cliPolishTimeout = 0                            // 超界（<1）→ 回預設
    #expect(s.cliPolishTimeout == 20.0)
    s.cliPolishTimeout = 200                          // 超界（>120）→ 回預設
    #expect(s.cliPolishTimeout == 20.0)
    s.cliPolishTimeout = .nan                         // 非有限 → 回預設
    #expect(s.cliPolishTimeout == 20.0)
    s.oaiEditTimeout = -5
    #expect(s.oaiEditTimeout == 6.0)
}

// MARK: - ASR 引擎選擇與 Whisper 遠端設定（M8 spec §3.4）

@Test func asrEngineKindDefaultsToSpeechAnalyzer() {
    let s = AppSettings(defaults: UserDefaults(suiteName: "t-\(UUID().uuidString)")!,
                        secrets: InMemorySecretStore())
    #expect(s.asrEngineKind == .speechAnalyzer)   // 既有使用者零行為變化
}

@Test func whisperSettingsRoundTripWithDefaults() {
    let s = AppSettings(defaults: UserDefaults(suiteName: "t-\(UUID().uuidString)")!,
                        secrets: InMemorySecretStore())
    #expect(s.whisperBaseURLString == "")
    #expect(s.whisperModel == "whisper-1")
    #expect(s.whisperTimeout == 120)
    s.asrEngineKind = .whisperRemote
    s.whisperBaseURLString = "http://localhost:8000/v1"
    s.whisperModel = "large-v3"
    s.whisperTimeout = 90
    #expect(s.asrEngineKind == .whisperRemote)
    #expect(s.whisperModel == "large-v3")
    #expect(s.whisperTimeout == 90)
}

@Test func whisperTimeoutRejectsOutOfRangeStoredValues() {
    let d = UserDefaults(suiteName: "t-\(UUID().uuidString)")!
    let s = AppSettings(defaults: d, secrets: InMemorySecretStore())
    d.set(9999.0, forKey: "whisperTimeout")
    #expect(s.whisperTimeout == 120)             // 超出 [1,120] → 回預設
    d.set(Double.nan, forKey: "whisperTimeout")
    #expect(s.whisperTimeout == 120)             // NaN → 回預設
}

@Test func whisperAPIKeyUsesSeparateSecretFromLLMKey() {
    let s = AppSettings(defaults: UserDefaults(suiteName: "t-\(UUID().uuidString)")!,
                        secrets: InMemorySecretStore())
    s.llmAPIKey = "llm-key"
    s.whisperAPIKey = "whisper-key"
    #expect(s.llmAPIKey == "llm-key")            // 兩者互不覆蓋（可能是不同服務）
    #expect(s.whisperAPIKey == "whisper-key")
}

@Test func whisperConfigReturnsNilWhenBaseURLEmpty() {
    let s = AppSettings(defaults: UserDefaults(suiteName: "t-\(UUID().uuidString)")!,
                        secrets: InMemorySecretStore())
    #expect(s.whisperConfig() == nil)            // 空字串＝未設定
    s.whisperBaseURLString = "http://localhost:8000/v1"
    #expect(s.whisperConfig()?.model == "whisper-1")
}

/// scheme 防線是載重而非形式檢查：URL(string:) 對這些輸入照樣回傳「合法」URL，
/// scheme 分別是 "localhost"／"file"／"ftp"。少打 http:// 是常見手誤，
/// 沒有這道檢查就會被當成有效設定，接著送出一個毫無意義的請求。
@Test func whisperConfigRejectsNonHTTPSchemes() {
    let s = AppSettings(defaults: UserDefaults(suiteName: "t-\(UUID().uuidString)")!,
                        secrets: InMemorySecretStore())
    for raw in ["localhost:8000/v1", "file:///etc/passwd", "ftp://x/y"] {
        s.whisperBaseURLString = raw
        #expect(s.whisperConfig() == nil, "非 http(s) scheme 必須拒絕：\(raw)")
    }
    for raw in ["http://localhost:8000/v1", "https://api.example.com/v1"] {
        s.whisperBaseURLString = raw
        #expect(s.whisperConfig() != nil, "http(s) 不得被誤殺：\(raw)")   // 反向誤殺防線
    }
}
