import Foundation
import Testing
@testable import SpeeckinkCore

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
    let store = KeychainStore(service: "io.speeckink.tests")
    try store.set("v1", forKey: "t")
    #expect(try store.get(forKey: "t") == "v1")
    try store.set("v2", forKey: "t") // 更新路徑
    #expect(try store.get(forKey: "t") == "v2")
    try store.delete(forKey: "t")
    #expect(try store.get(forKey: "t") == nil)
}
