import AppKit
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
    /// 本機模型預載／卸載／狀態查詢（M9 §6）：由 App 注入 AppDelegate 對應方法；預設 no-op 供預覽態。
    let whisperLocalPreload: () -> Void
    let whisperLocalUnload: () -> Void
    let whisperLocalState: @MainActor () async -> ModelLoadState

    init(settings: AppSettings,
         vocab: (any VocabStore)? = nil,
         history: (any HistoryRecording)? = nil,
         coreModes: (any CoreModeStore)? = nil,
         detector: ClaudeCLIDetector? = nil,
         tester: ProviderTester? = nil,
         whisperLocalPreload: @escaping () -> Void = {},
         whisperLocalUnload: @escaping () -> Void = {},
         whisperLocalState: @escaping @MainActor () async -> ModelLoadState = { .idle }) {
        self.settings = settings
        self.vocab = vocab
        self.history = history
        self.coreModes = coreModes
        self.detector = detector
        self.tester = tester
        self.whisperLocalPreload = whisperLocalPreload
        self.whisperLocalUnload = whisperLocalUnload
        self.whisperLocalState = whisperLocalState
    }

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, detector: detector, tester: tester,
                               whisperLocalPreload: whisperLocalPreload,
                               whisperLocalUnload: whisperLocalUnload,
                               whisperLocalState: whisperLocalState)
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
    let whisperLocalPreload: () -> Void
    let whisperLocalUnload: () -> Void
    let whisperLocalState: @MainActor () async -> ModelLoadState

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
    // ASR 引擎（M8 spec §6.2）
    @State private var asrEngineKind: ASREngineKind
    @State private var whisperBaseURL: String
    @State private var whisperModel: String
    @State private var whisperAPIKey: String
    @State private var whisperTimeout: Double
    // 本機 WhisperKit（M9 §5）
    @State private var whisperLocalModelPath: URL?
    @State private var discoveredModels: [DiscoveredModel] = []
    @State private var scanTask: Task<Void, Never>?
    @State private var localModelState: ModelLoadState = .idle
    // Provider 連通性測試（M7 §5）
    @State private var testTask: Task<Void, Never>?
    @State private var testReport: ProviderTestReport?
    @State private var testCancelled = false

    init(settings: AppSettings, detector: ClaudeCLIDetector? = nil, tester: ProviderTester? = nil,
         whisperLocalPreload: @escaping () -> Void = {},
         whisperLocalUnload: @escaping () -> Void = {},
         whisperLocalState: @escaping @MainActor () async -> ModelLoadState = { .idle }) {
        self.settings = settings
        self.detector = detector
        self.tester = tester
        self.whisperLocalPreload = whisperLocalPreload
        self.whisperLocalUnload = whisperLocalUnload
        self.whisperLocalState = whisperLocalState
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
        _asrEngineKind = State(initialValue: settings.asrEngineKind)
        _whisperBaseURL = State(initialValue: settings.whisperBaseURLString)
        _whisperModel = State(initialValue: settings.whisperModel)
        _whisperAPIKey = State(initialValue: settings.whisperAPIKey ?? "")
        _whisperTimeout = State(initialValue: settings.whisperTimeout)
        _whisperLocalModelPath = State(initialValue: settings.whisperLocalModelPath)
    }

    /// M8 新增的 5 條設定寫回單獨掛在 body：全部串在同一條 modifier 鏈上會讓
    /// SwiftUI 型別檢查器超時（錯誤指向鏈中任一子運算式，非新程式碼本身有問題）。
    var body: some View {
        generalForm
            .onChange(of: asrEngineKind) { _, v in
                settings.asrEngineKind = v
                if v == .whisperLocal { whisperLocalPreload() }   // 切到本機即預載選定模型
            }
            .onChange(of: whisperBaseURL) { _, v in settings.whisperBaseURLString = v }
            .onChange(of: whisperModel) { _, v in settings.whisperModel = v }
            .onChange(of: whisperAPIKey) { _, v in settings.whisperAPIKey = v.isEmpty ? nil : v }
            .onChange(of: whisperTimeout) { _, v in settings.whisperTimeout = v }
            .onChange(of: whisperLocalModelPath) { _, v in
                settings.whisperLocalModelPath = v                // 先寫 settings 再預載，預載才讀得到新模型
                whisperLocalPreload()
            }
    }

    private var generalForm: some View {
        Form {
            Section("聽寫") {
                Picker("聽寫熱鍵", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("輸出語系", selection: $language) {
                    ForEach(OutputLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            asrEngineSection
            whisperLocalSection
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
                    SecureField("API Key（存於 Keychain；本地端點可留空）", text: $apiKey)
                    if apiKey.isEmpty, EndpointKeyRequirement.requiresAPIKey(baseURL: baseURL) {
                        // 沒有這條，使用者只會看到 2.5 秒即消的「未潤飾（HTTP 401）」，看不出是自己沒填 Key
                        Label("未設定 API Key，潤飾將被端點拒絕（HTTP 401）", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
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

    /// 語音辨識引擎單選與 Whisper 遠端設定（M8 spec §6.2）。
    /// 抽成獨立屬性而非直接寫在 Form 內：全部展開會讓 SwiftUI 型別檢查器超時
    /// （「unable to type-check this expression in reasonable time」），
    /// 比照本檔既有的 detectionStatusRow／providerTestControls 作法。
    @ViewBuilder private var asrEngineSection: some View {
        Section("語音辨識引擎") {
            Picker("引擎", selection: $asrEngineKind) {
                ForEach(ASREngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        if asrEngineKind == .whisperRemote {
            Section("Whisper 遠端") {
                TextField("Base URL", text: $whisperBaseURL,
                          prompt: Text("http://localhost:8000/v1"))
                if whisperBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("未設定端點，聽寫將無法辨識", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                TextField("模型", text: $whisperModel, prompt: Text("whisper-1"))
                SecureField("API Key（存於 Keychain；本地端點可留空）", text: $whisperAPIKey)
                Stepper(value: $whisperTimeout, in: AppSettings.timeoutRange, step: 5) {
                    Text("逾時：\(Int(whisperTimeout)) 秒")
                }
                Text("整段錄音在放開熱鍵後一次上傳辨識，講話中不會即時出字。長錄音需要較長逾時；10 分鐘錄音約 19MB，上限亦為 10 分鐘。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("聽寫音訊會上傳至此端點——詳見「隱私」分頁。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 本機 WhisperKit 模型選擇（M9 §4/§5）。抽獨立 @ViewBuilder 的理由同 asrEngineSection。
    @ViewBuilder private var whisperLocalSection: some View {
        if asrEngineKind == .whisperLocal {
            Section("本機 WhisperKit") {
                whisperLocalModelPicker
                whisperLocalSelectionControls
                whisperLocalLoadControls
                Button("選擇資料夾…") { chooseScanRoot() }
                // 誠實化（REV #2）：音訊與模型確實留在本機，但 tokenizer 由 WhisperKit 向 HF 取，
                // 冷快取的機器首次仍會連一次網——不能一句「離線可用」帶過。
                Text("音訊不出機器、模型在本機。若本機尚無此模型的 tokenizer 快取，首次使用會向 Hugging Face 取一次 tokenizer，之後即可離線。")
                    .font(.caption).foregroundStyle(.secondary)
                whisperLocalIncompatibleRows
            }
            .task { await enterWhisperLocalSection() }
        }
    }

    /// 模型載入狀態列＋手動載入／卸載（M9：首次 ANE 編譯可達數分鐘，讓使用者能事先載好、也能放掉記憶體）
    @ViewBuilder private var whisperLocalLoadControls: some View {
        LabeledContent("模型狀態", value: Self.stateText(localModelState))
        HStack {
            Button("載入") { whisperLocalPreload(); refreshLocalModelState() }
                .disabled(whisperLocalModelPath == nil || localModelState != .idle)
            // 載入中也可按：large 首次 ANE 編譯要數分鐘，使用者得有中斷的出口
            Button("卸載") { whisperLocalUnload(); refreshLocalModelState() }
                .disabled(localModelState == .idle)
            if localModelState == .loading { ProgressView().controlSize(.small) }
        }
    }

    private static func stateText(_ s: ModelLoadState) -> String {
        switch s {
        case .idle:    return "未載入"
        case .loading: return "載入中…（首次較久）"
        case .loaded:  return "已載入"
        }
    }

    /// 進入區塊：掃一次模型，之後每秒回報載入狀態。
    /// 標 @MainActor：`.task` 的 closure 是 @Sendable、不繼承 MainActor，寫 @State 必須自己標（記取 NEW-1）。
    @MainActor private func enterWhisperLocalSection() async {
        if asrEngineKind == .whisperLocal { rescanLocalModels() }
        while !Task.isCancelled {
            localModelState = await whisperLocalState()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 按下載入／卸載後立刻反映一次，不必等下一輪輪詢
    private func refreshLocalModelState() {
        Task { @MainActor in localModelState = await whisperLocalState() }
    }

    /// 可用模型下拉；掃不到只給文字引導（不做下載按鈕，M9 §2）
    @ViewBuilder private var whisperLocalModelPicker: some View {
        if usableModels.isEmpty {
            Label("找不到可用的 WhisperKit 模型", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
            Text("請把 WhisperKit CoreML 模型（例如 openai_whisper-large-v3_turbo）放到 ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/，或用下方「選擇資料夾…」指定既有模型所在的目錄。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("模型", selection: $whisperLocalModelPath) {
                Text("未選擇").tag(URL?.none)
                ForEach(usableModels, id: \.id) { m in
                    Text(Self.modelLabel(m)).tag(URL?.some(m.path))
                }
            }
        }
    }

    /// 清除選擇（REV #9）：不論掃描結果是否為空都給得出口；選定模型已不在掃描結果時明說，
    /// 但**不自動清除**——使用者的外接碟可能只是暫時沒插。
    @ViewBuilder private var whisperLocalSelectionControls: some View {
        if let selected = whisperLocalModelPath {
            if !usableModels.contains(where: { $0.path == selected }) {
                Label("先前選定的模型目前不在掃描結果中：\(selected.lastPathComponent)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            Button("清除選擇") { whisperLocalModelPath = nil }
        }
    }

    /// 掃到但不可用者：灰字列出並附原因（MLX safetensors、Parakeet/CTC、檔案不齊等）
    @ViewBuilder private var whisperLocalIncompatibleRows: some View {
        if !incompatibleModels.isEmpty {
            Text("以下項目不可用：").font(.caption).foregroundStyle(.secondary)
            ForEach(incompatibleModels, id: \.id) { m in
                Text("\(m.displayName)——\(Self.incompatibleReason(m.kind))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var usableModels: [DiscoveredModel] {
        discoveredModels.filter { $0.kind == .whisperKitUsable }
    }
    private var incompatibleModels: [DiscoveredModel] {
        discoveredModels.filter { $0.kind != .whisperKitUsable }
    }

    /// 掃描搬到背景（REV #4）：dirSize 會遞迴走完整個模型目錄，留在 MainActor 上會凍住設定視窗。
    /// 重掃時取消前一次，避免慢掃描的舊結果蓋掉新結果。
    private func rescanLocalModels() {
        scanTask?.cancel()
        let roots = WhisperKitModelScanner.defaultRoots + settings.whisperLocalScanRoots
        // 外層標 @MainActor：Swift 6 的 Task 不繼承 MainActor，少了它就是在背景執行緒寫 @State。
        scanTask = Task { @MainActor in
            let found = await Task.detached(priority: .utility) {
                WhisperKitModelScanner().scan(roots: roots)
            }.value
            guard !Task.isCancelled else { return }
            discoveredModels = found
        }
    }

    /// 模型列標籤：本機已有 tokenizer＝真離線；沒有則明示首次需連網（REV #2）
    private static func modelLabel(_ m: DiscoveredModel) -> String {
        let base = "\(m.displayName)（\(sizeText(m.sizeBytes))）"
        return m.tokenizerCached ? base : base + "（首次需連網取 tokenizer）"
    }

    /// 「選擇資料夾…」：選到的目錄加入掃描根後重掃（選到模型目錄本身或其父目錄都可，M9 §4）
    private func chooseScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "加入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 正規化後才比對與存檔：尾斜線／`.`／symlink 變體都是同一個根，不該重複累積
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        var roots = settings.whisperLocalScanRoots
        if !roots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == root }) {
            roots.append(root)
        }
        settings.whisperLocalScanRoots = roots
        rescanLocalModels()
    }

    private static func sizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private static func incompatibleReason(_ kind: DiscoveredModelKind) -> String {
        switch kind {
        case .whisperKitUsable: return ""
        case .coreMLNonWhisper(let reason): return reason
        case .mlxSafetensors: return "MLX safetensors 格式，WhisperKit 不支援"
        case .unknown: return "無法辨識（模型檔不齊或格式不明）"
        }
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
