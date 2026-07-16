import SwiftUI
import SpeeckinkCore

/// 設定殼：TabView 分頁（一般／核心模式／詞彙表／Prompt／歷史／隱私）。
/// vocab／history／coreModes 由 App 注入（nil＝預覽態，分頁自行停用）。
struct SettingsView: View {
    let settings: AppSettings
    let vocab: (any VocabStore)?
    let history: (any HistoryRecording)?
    let coreModes: (any CoreModeStore)?

    init(settings: AppSettings,
         vocab: (any VocabStore)? = nil,
         history: (any HistoryRecording)? = nil,
         coreModes: (any CoreModeStore)? = nil) {
        self.settings = settings
        self.vocab = vocab
        self.history = history
        self.coreModes = coreModes
    }

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("一般", systemImage: "gearshape") }
            CoreModeSettingsTab(store: coreModes)
                .tabItem { Label("核心模式", systemImage: "square.stack.3d.up") }
            VocabSettingsTab(store: vocab)
                .tabItem { Label("詞彙表", systemImage: "character.book.closed") }
            PromptSettingsTab(settings: settings, coreModes: coreModes)
                .tabItem { Label("Prompt", systemImage: "text.badge.checkmark") }
            HistorySettingsTab(store: history, settings: settings)
                .tabItem { Label("歷史", systemImage: "clock.arrow.circlepath") }
            PrivacySettingsTab(settings: settings)
                .tabItem { Label("隱私", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 460)
        .padding()
    }
}

/// 基本設定（規格 §8 M1：熱鍵／API key／語系）＋ LLM 端點。
/// AppSettings 非 ObservableObject，故以 @State 快照＋onChange 寫回。
struct GeneralSettingsTab: View {
    let settings: AppSettings

    @State private var hotkey: HotkeyChoice
    @State private var language: OutputLanguage
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String

    init(settings: AppSettings) {
        self.settings = settings
        _hotkey = State(initialValue: settings.hotkey)
        _language = State(initialValue: settings.outputLanguage)
        _baseURL = State(initialValue: settings.llmBaseURLString)
        _model = State(initialValue: settings.llmModel)
        _apiKey = State(initialValue: settings.llmAPIKey ?? "")
    }

    var body: some View {
        Form {
            Section("聽寫") {
                Picker("聽寫熱鍵", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("輸出語系", selection: $language) {
                    ForEach(OutputLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("LLM（OpenAI Compatible）") {
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                TextField("模型", text: $model, prompt: Text("gpt-4o-mini"))
                SecureField("API Key（存於 Keychain）", text: $apiKey)
                Text("本地模型（Ollama／LM Studio）也走這裡：填 http://localhost:11434/v1 之類的端點即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onChange(of: hotkey) { _, v in settings.hotkey = v }
        .onChange(of: language) { _, v in settings.outputLanguage = v }
        .onChange(of: baseURL) { _, v in settings.llmBaseURLString = v }
        .onChange(of: model) { _, v in settings.llmModel = v }
        .onChange(of: apiKey) { _, v in settings.llmAPIKey = v.isEmpty ? nil : v }
    }
}
