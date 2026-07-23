import SwiftUI
import SaymendCore

/// 設定殼：TabView 分頁（一般／核心模式／詞彙表／Prompt／歷史／隱私）。
/// vocab／history／coreModes 由 App 注入（nil＝預覽態，分頁自行停用）。
struct SettingsView: View {
    let settings: AppSettings
    let vocab: (any VocabStore)?
    let history: (any HistoryRecording)?
    let coreModes: (any CoreModeStore)?
    let detector: ClaudeCLIDetector?
    let tester: ProviderTester?

    init(settings: AppSettings,
         vocab: (any VocabStore)? = nil,
         history: (any HistoryRecording)? = nil,
         coreModes: (any CoreModeStore)? = nil,
         detector: ClaudeCLIDetector? = nil,
         tester: ProviderTester? = nil) {
        self.settings = settings
        self.vocab = vocab
        self.history = history
        self.coreModes = coreModes
        self.detector = detector
        self.tester = tester
    }

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, detector: detector, tester: tester)
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
    let detector: ClaudeCLIDetector?
    let tester: ProviderTester?

    @State private var hotkey: HotkeyChoice
    @State private var language: OutputLanguage
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    // Provider 選擇（spec §7）
    @State private var providerKind: ProviderKind
    @State private var cliModel: String
    @State private var cliPathOverride: String
    @State private var oaiPolish: Double
    @State private var oaiEdit: Double
    @State private var cliPolish: Double
    @State private var cliEdit: Double
    @State private var detection: ClaudeCLIDetection?
    // Provider 連通性測試（M7 §5）
    @State private var testTask: Task<Void, Never>?
    @State private var testReport: ProviderTestReport?
    @State private var testCancelled = false

    init(settings: AppSettings, detector: ClaudeCLIDetector? = nil, tester: ProviderTester? = nil) {
        self.settings = settings
        self.detector = detector
        self.tester = tester
        _hotkey = State(initialValue: settings.hotkey)
        _language = State(initialValue: settings.outputLanguage)
        _baseURL = State(initialValue: settings.llmBaseURLString)
        _model = State(initialValue: settings.llmModel)
        _apiKey = State(initialValue: settings.llmAPIKey ?? "")
        _providerKind = State(initialValue: settings.providerKind)
        _cliModel = State(initialValue: settings.claudeCLIModel)
        _cliPathOverride = State(initialValue: settings.claudeCLIPathOverride ?? "")
        _oaiPolish = State(initialValue: settings.oaiPolishTimeout)
        _oaiEdit = State(initialValue: settings.oaiEditTimeout)
        _cliPolish = State(initialValue: settings.cliPolishTimeout)
        _cliEdit = State(initialValue: settings.cliEditTimeout)
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
            Section("LLM Provider") {
                Picker("Provider", selection: $providerKind) {
                    Text("OpenAI 相容").tag(ProviderKind.openAICompat)
                    Text("Claude CLI").tag(ProviderKind.claudeCLI)
                }
                .pickerStyle(.segmented)
            }
            if providerKind == .openAICompat {
                Section("OpenAI 相容") {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                    TextField("模型", text: $model, prompt: Text("gpt-4o-mini"))
                    SecureField("API Key（存於 Keychain）", text: $apiKey)
                    Text("本地模型（Ollama／LM Studio）也走這裡：填 http://localhost:11434/v1 之類的端點即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    timeoutControls(polish: $oaiPolish, edit: $oaiEdit,
                                    defaults: (3, 6))
                    providerTestControls
                }
            } else {
                Section("Claude CLI") {
                    detectionStatusRow
                    TextField("CLI 路徑（留空＝自動偵測）", text: $cliPathOverride)
                    TextField("模型", text: $cliModel, prompt: Text("sonnet"))
                    Text("沿用本機 claude CLI 的既有登入，毋需 API Key。聽寫內容以隔離模式呼叫：不寫入 Claude Code session、不觸發 hooks、不載入 CLAUDE.md。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    timeoutControls(polish: $cliPolish, edit: $cliEdit,
                                    defaults: (20, 20))
                    providerTestControls
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .task(id: cliPathOverride + providerKind.rawValue) {
            guard providerKind == .claudeCLI, let detector else { return }
            detection = await detector.detect(override: cliPathOverride.isEmpty ? nil : cliPathOverride)
        }
        .onChange(of: hotkey) { _, v in settings.hotkey = v }
        .onChange(of: language) { _, v in settings.outputLanguage = v }
        .onChange(of: baseURL) { _, v in settings.llmBaseURLString = v }
        .onChange(of: model) { _, v in settings.llmModel = v }
        .onChange(of: apiKey) { _, v in settings.llmAPIKey = v.isEmpty ? nil : v }
        .onChange(of: providerKind) { _, v in
            settings.providerKind = v
            testTask?.cancel()
            testTask = nil
            testReport = nil
            testCancelled = false
        }
        .onChange(of: cliModel) { _, v in settings.claudeCLIModel = v }
        .onChange(of: cliPathOverride) { _, v in settings.claudeCLIPathOverride = v.isEmpty ? nil : v }
        .onChange(of: oaiPolish) { _, v in settings.oaiPolishTimeout = v }
        .onChange(of: oaiEdit) { _, v in settings.oaiEditTimeout = v }
        .onChange(of: cliPolish) { _, v in settings.cliPolishTimeout = v }
        .onChange(of: cliEdit) { _, v in settings.cliEditTimeout = v }
    }

    /// 偵測狀態列（spec §7）：綠勾＋路徑／紅字原因。此為靜態偵測，非 #4 的連通性測試。
    @ViewBuilder private var detectionStatusRow: some View {
        switch detection {
        case .found(let path, let version):
            Label("已偵測：\(path)（v\(version)）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .incompatible(_, let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
        case .notFound:
            Label("未偵測到 claude CLI，請安裝或手動指定路徑", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case nil:
            Label("偵測中…", systemImage: "hourglass").font(.caption)
        }
    }

    /// Provider 測試（M7 §5.3）：執行中按鈕變「取消」（120s 上限配慢 provider 需脫困出口）。
    /// 取消＝放棄等待（fire-and-forget）：在途呼叫自然結束後結果被 isCancelled 守衛丟棄。
    @ViewBuilder private var providerTestControls: some View {
        HStack {
            Button(testTask == nil ? "測試連線" : "取消") {
                if let task = testTask {
                    task.cancel()
                    testTask = nil
                    testReport = nil
                    testCancelled = true
                } else {
                    runProviderTest()
                }
            }
            .disabled(tester == nil)
            if testTask != nil { ProgressView().controlSize(.small) }
            if testCancelled { Text("已取消").font(.caption).foregroundStyle(.secondary) }
        }
        if let r = testReport {
            testResultRows(r)
        }
    }

    private func runProviderTest() {
        guard let tester else { return }
        testReport = nil
        testCancelled = false
        let kind = providerKind
        let polish = kind == .openAICompat ? oaiPolish : cliPolish   // 比對基準＝該 provider 自己的 polishTimeout
        testTask = Task {
            let report = await tester.run(kind: kind, polishTimeout: polish)
            if Task.isCancelled { return }                            // 已放棄：結果丟棄
            await MainActor.run {
                testReport = report
                testTask = nil
            }
        }
    }

    /// 三判定逐行顯示（M7 §5.2）
    @ViewBuilder private func testResultRows(_ r: ProviderTestReport) -> some View {
        switch r.verdict {
        case .failed(let reason):
            Label("連通 ✗（\(reason)）", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case .badEnvelope(let reason):
            Label("連通 ✓", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
            latencyRow(r)
            Label("信封 ✗（\(reason)）——此 provider 的回應無法被解析，實際聽寫會全數降級",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case .ok:
            Label("連通 ✓", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
            latencyRow(r)
            Label("信封 ✓", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        }
    }

    @ViewBuilder private func latencyRow(_ r: ProviderTestReport) -> some View {
        if let latency = r.latency {
            let text = String(format: "延遲 %.1f 秒", latency)
            if r.exceedsPolishTimeout {
                Label("\(text)——超過潤飾逾時，實際聽寫會每次逾時降級",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else {
                Label(text, systemImage: "timer").font(.caption)
            }
        }
    }

    /// timeout 控制（spec §5/§7）：Stepper 天然限制在 [1,120]（UI 防線）＋恢復預設。
    @ViewBuilder private func timeoutControls(polish: Binding<Double>, edit: Binding<Double>,
                                              defaults: (Double, Double)) -> some View {
        Stepper(value: polish, in: AppSettings.timeoutRange, step: 1) {
            Text("逾時・潤飾：\(Int(polish.wrappedValue)) 秒")
        }
        Stepper(value: edit, in: AppSettings.timeoutRange, step: 1) {
            Text("逾時・修正：\(Int(edit.wrappedValue)) 秒")
        }
        Button("恢復預設逾時") {
            polish.wrappedValue = defaults.0
            edit.wrappedValue = defaults.1
        }
    }
}
