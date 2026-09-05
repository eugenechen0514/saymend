import AppKit
import ApplicationServices
import SwiftUI
import SaymendCore

@main
struct SaymendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Saymend", systemImage: "mic.fill") {
            MenuContent(delegate: delegate)
        }
        Settings {
            SettingsView(settings: delegate.settings, vocab: delegate.vocabStore,
                        history: delegate.historyStore, coreModes: delegate.coreModeStore,
                        detector: delegate.claudeCLIDetector,
                        tester: delegate.providerTester,
                        whisperLocalPreload: delegate.preloadWhisperLocal,
                        whisperLocalUnload: delegate.unloadWhisperLocal,
                        whisperLocalState: { await delegate.whisperLocalState() },
                        whisperLocalProgress: { await delegate.whisperLocalProgress() },
                        whisperLocalLastLoad: { await delegate.whisperLocalLastLoad() })
        }
    }
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    @Published var statusLine = "待機"
    /// 核心模式狀態版本號：session/default/per-app 綁定改動時遞增。這些狀態存在
    /// AppSettings／FileAppProfileStore（皆非 ObservableObject），SwiftUI 無從得知
    /// 何時該重建選單。改模式的動作一律走 delegate 方法並 bump 此值，讓觀察 delegate
    /// 的 MenuBarExtra 內容在「使用者真的改了模式」時重建一次（而非靠 0.25s tick 狂重建
    /// ——那正是子選單閃退的成因），使勾勾反映最新的解析結果。
    @Published private(set) var coreModeMenuToken = 0

    private(set) var controller: DictationController!
    private let hud = HUDWindowController()
    private let overlay = OverlayWindowController()
    private var feedbackCoordinator: FeedbackCoordinator!
    private var hotkeyMonitor: HotkeyMonitor!
    private var tickTask: Task<Void, Never>?
    private let audio = AudioCapture()
    private let keystroke = KeystrokeInserter()

    // M4 持久層：Task 12/13 的設定 UI 分頁讀這些（詞彙表／profile／歷史）。
    // 一律屬性初始化、不放 didFinishLaunching：SwiftUI 的 Settings scene body 在啟動時
    // 就會求值（早於 didFinishLaunching），IUO 延遲初始化會讓 SettingsView 抓到 nil 快照、
    // 整頁停用（實機驗收 finding）。目錄由 App 注入，Core 只吃 URL。
    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saymend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    let vocabStore = FileVocabStore(fileURL: AppDelegate.supportDir.appendingPathComponent("vocab.json"))
    let profileStore = FileAppProfileStore(fileURL: AppDelegate.supportDir.appendingPathComponent("profiles.json"))
    let historyStore = try? GRDBHistoryStore.onDisk(directory: AppDelegate.supportDir)
    // M5 新增：一律屬性初始化、不放 didFinishLaunching——SwiftUI Settings scene body
    // 在啟動時即求值，早於 didFinishLaunching（M4 驗收踩過的坑，commit 13ad337）。
    let coreModeStore = FileCoreModeStore(fileURL: AppDelegate.supportDir.appendingPathComponent("core_modes.json"))
    let coreModeResolver = CoreModeResolver()
    private let ocrReader = OCRContextReader()
    /// ClaudeCLI 偵測器：設定 UI（Task 8）與 provider 共用同一實例＝共享 (path, mtime) 快取（spec §4.1）。
    let claudeCLIDetector = ClaudeCLIDetector.live()
    /// 測試按鈕用 tester（M7 §5）：與聽寫 provider 分實例（不搶 CLI slot），detector 共用（快取共享）
    lazy var providerTester: ProviderTester = {
        let oai = OpenAICompatProvider(configProvider: { [settings] in settings.openAIConfig() })
        let cli = ClaudeCLIProvider(
            configProvider: { [settings] in settings.claudeCLIConfig() },
            detect: { [claudeCLIDetector] override in await claudeCLIDetector.detect(override: override) })
        return ProviderTester(provider: ProviderRouter(openAICompat: oai, claudeCLI: cli))
    }()
    /// 本機 WhisperKit 引擎（M9 §6）：**必須是 AppDelegate 屬性**（非 didFinishLaunching 區域變數），
    /// SwiftUI 的 Settings scene body 才捕捉得到同一實例來預載。用 lazy var 讓它能捕捉 settings
    /// （屬性初始化器不可 reference 其他屬性）。
    lazy var whisperLocalEngine = WhisperKitEngine(
        transcriber: WhisperKitTranscriber(),
        configProvider: { [settings] in settings.whisperLocalConfig() },
        // 每次聽寫現讀（issue #15）：設定改完下一句就生效，不做啟動快照
        optionsProvider: { [settings] in settings.whisperStreamingOptions() })

    /// 前一次預載：換模型時取消它（best-effort）。連點多個模型時不讓過期的預載繼續佔載入排隊。
    private var whisperLocalPreloadTask: Task<Void, Never>?

    /// 背景預載目前選定的本機模型（切到本機引擎／換模型時呼叫），讓第一句不必等 3GB 載入。
    func preloadWhisperLocal() {
        whisperLocalPreloadTask?.cancel()
        whisperLocalPreloadTask = Task { [whisperLocalEngine] in await whisperLocalEngine.preload() }
    }

    /// 卸載本機模型，釋放記憶體（設定頁「卸載」）。先停掉在途預載，免得剛卸載又被載回來。
    func unloadWhisperLocal() {
        whisperLocalPreloadTask?.cancel()
        whisperLocalPreloadTask = nil
        Task { [whisperLocalEngine] in await whisperLocalEngine.unload() }
    }

    /// 設定頁輪詢用：目前選定模型的載入狀態。
    func whisperLocalState() async -> ModelLoadState {
        await whisperLocalEngine.state()
    }

    /// 設定頁輪詢用：這一趟載入的階段進度（issue #17）。給不出來就 nil，UI 退回純碼表。
    func whisperLocalProgress() async -> ModelLoadProgress? {
        await whisperLocalEngine.loadProgress()
    }

    /// 設定頁輪詢用：目前選定模型上次載入花了多久（issue #17）。
    func whisperLocalLastLoad() async -> CompletedLoad? {
        await whisperLocalEngine.lastLoad()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 輔助功能權限：沒有就跳系統提示（熱鍵與鍵入都靠它）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        historyStore?.purge(olderThanDays: settings.historyRetentionDays)   // 啟動時清過期（規格 §4.9）

        let axInserter = AXInserter()
        // 欄位 identity registry（issue #43）：reader 與 feedback 共用，同一元素同一 token
        let axRegistry = AXFieldRegistry()
        let axReader = AXFieldReader(profiles: profileStore, registry: axRegistry)
        let coordinator = InsertionCoordinator(keystroke: keystroke, paste: PasteInserter(),
                                               rangeReplacer: axInserter)
        let provider = OpenAICompatProvider(configProvider: { [settings] in settings.openAIConfig() })
        // ClaudeCLI（spec §4）：偵測器 UI 與 provider 共用（快取共享）；config 每次呼叫讀取即時生效
        let cliProvider = ClaudeCLIProvider(
            configProvider: { [settings] in settings.claudeCLIConfig() },
            detect: { [claudeCLIDetector] override in await claudeCLIDetector.detect(override: override) })
        let router = ProviderRouter(openAICompat: provider, claudeCLI: cliProvider)
        // 簡繁保險絲初始化失敗不得無聲吞掉（規格 §5.1）：一次性 HUD 通知後以無保險絲模式續行。
        // apply() 本身不會 throw，init 是唯一失敗點。
        let traditionalize: TraditionalizeGuard?
        do {
            traditionalize = try TraditionalizeGuard()
        } catch {
            traditionalize = nil
            hud.present(.notice("簡繁保險絲初始化失敗，zh-TW 輸出可能殘留簡體"))
        }
        // ASR 引擎帶詞彙偏置（規格 §4.8）。與 prompt 第 6 層同受 profile.vocabEnabled 節制
        // （規格 §4.4：特定 App 停用詞彙表以 profile 功能開關實現——兩路注入都要管，終審 finding）。
        let speechAnalyzerEngine = SpeechAnalyzerEngine()
        let whisperEngine = WhisperRemoteEngine(
            configProvider: { [settings] in settings.whisperConfig() })   // 每次呼叫讀取＝設定即時生效
        let asrEngine = ASREngineRouter(
            speechAnalyzer: speechAnalyzerEngine,
            whisperRemote: whisperEngine,
            whisperLocal: whisperLocalEngine,                             // AppDelegate lazy 屬性
            kindProvider: { [settings] in settings.asrEngineKind })       // start 時單一快照
        // 啟動即預載：本次啟動就選在本機引擎時，先把模型載進來
        if settings.asrEngineKind == .whisperLocal { preloadWhisperLocal() }
        // 偏置設在 router 上，由它轉發給當下選定的引擎（兩個引擎吃同一個詞彙表來源）
        asrEngine.contextualStrings = { [vocabStore, profileStore] in
            if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               profileStore.profile(for: bundle).vocabEnabled == false {
                return []
            }
            return vocabStore.all().map(\.phrase)
        }

        // prompt 輸入單一快照（規格 §3.5）：同一次呼叫內只讀一次 frontmostApplication 與 profile，
        // language / sources / mode 三者由同一個 bundle+profile 衍生——torn read 在構造上不可能發生。
        // 標 @MainActor：讀 vocabStore／profileStore／coreModeStore／settings 並碰 NSWorkspace 前景 App；
        // IntentService 會在單一 MainActor.run 內呼叫本 closure。
        let promptInputs: @MainActor () -> PromptInputs = {
            [settings, profileStore, vocabStore, coreModeStore, coreModeResolver] in
            // ① 只讀一次
            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let profile = bundle.map { profileStore.profile(for: $0) }

            // ② 語系解析（M4 設計裁決 4）：session 覆蓋 > profile 固定 > 全域
            let language: OutputLanguage = {
                if let override = settings.sessionLanguageOverride { return override }
                if let fixed = profile?.fixedLanguage { return fixed }
                return settings.outputLanguage
            }()

            // ③ prompt 3-6 層來源（M4 既有）
            let sources = PromptLayerSources(
                styleOverride: settings.styleRulesOverride,
                customPrompt: settings.customSystemPrompt.isEmpty ? nil : settings.customSystemPrompt,
                appPrompt: profile?.extraPrompt,
                vocab: (profile?.vocabEnabled ?? true) ? vocabStore.all() : [])

            // ④ 核心模式解析（M5 §3.1）：session > per-app > 全域 > 內建預設
            let mode = coreModeResolver.resolve(
                sessionModeID: settings.sessionCoreModeID,
                appModeID: profile?.coreModeID,
                defaultModeID: settings.defaultCoreModeID,
                availableModes: PromptAssembler.builtinCoreModes + coreModeStore.allUserModes())

            // ⑤ provider 選擇與 timeout（spec §5）：與 language/sources/mode 同一快照
            let kind = settings.providerKind
            let t = settings.providerTimeouts(for: kind)
            return PromptInputs(language: language, sources: sources, mode: mode,
                                providerKind: kind, polishTimeout: t.polish, editTimeout: t.edit)
        }
        let intentService = IntentService(
            provider: router,
            traditionalize: traditionalize,
            inputs: promptInputs,
            promptBudget: PromptBudget.productionDefault())   // Debug 可由 E2E env 注入；Release 恆為預設
        feedbackCoordinator = FeedbackCoordinator(overlay: overlay, hud: hud, profiles: profileStore,
                                                  registry: axRegistry)
        controller = DictationController(
            audio: audio,
            asr: asrEngine,
            coordinator: coordinator,
            intent: intentService,
            hud: hud,
            settings: settings,
            clipboardRescue: { text in
                // 鐵律最後手段：原文進剪貼簿
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            fieldReader: axReader,
            feedback: feedbackCoordinator,
            history: historyStore,
            contextOCR: { [ocrReader, settings] in
                // 設定開關為總閘（規格 §4.7）：關閉時連截圖都不嘗試。開啟後才進入既有降級序
                // （DictationController 僅在 AX 無前後文且非安全欄位時呼叫此 closure）。
                guard settings.ocrContextEnabled else { return nil }
                return await ocrReader.captureText()
            }
        )
        // 插入層備援診斷（issue #1）：主 inserter 失敗、備援救回時補一筆歷史事件。
        // 插入一律發生在 controller 的 MainActor 上，故直接轉呼叫。
        coordinator.onInserterFallback = { [weak self] kind in
            self?.controller.noteInserterFallback(kind)
        }

        audio.levelHandler = { [weak self] level in self?.hud.updateLevel(level) }

        hud.onUndoTap = { [weak self] in
            Task { @MainActor in self?.controller.undoRequested() }
        }

        hotkeyMonitor = HotkeyMonitor(
            hotkey: { [settings] in settings.hotkey },
            isCapturing: { [weak self] in
                guard let self else { return false }
                // isEngaged 涵蓋排空窗（finishing）：該窗內的手動打字也必須觸發凍結
                return self.controller.isEngaged
            }
        )
        // 落在自家 HUD 上的滑鼠點擊交給 HUD 復原按鈕，不算使用者活動（規格 §3.3 HUD 常駐復原）
        hotkeyMonitor.isEventOnOwnHUD = { [weak self] point in
            self?.hud.containsScreenPoint(point) ?? false
        }
        hotkeyMonitor.onPress = { [weak self] t in
            Task { @MainActor in
                self?.controller.hotkeyPressed(at: t)
                self?.refreshStatus()
            }
        }
        hotkeyMonitor.onRelease = { [weak self] t in
            Task { @MainActor in
                self?.controller.hotkeyReleased(at: t)
                self?.refreshStatus()
            }
        }
        hotkeyMonitor.onEscape = { [weak self] in
            Task { @MainActor in
                self?.controller.escapePressed()
                self?.refreshStatus()
            }
        }
        hotkeyMonitor.onUserActivity = { [weak self] t in
            Task { @MainActor in
                self?.controller.userActivityDetected(at: t)
                self?.refreshStatus()
            }
        }
        // 切換前景 App＝使用者活動（規格 §3.4 凍結觸發器）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                self?.controller.userActivityDetected(at: Date().timeIntervalSinceReferenceDate)
                // 切前景 App 會改變 per-app 的核心模式解析結果，選單勾勾必須跟著重算——
                // token 只被三個改模式的 delegate 方法 bump，這條事件也要 bump，否則
                // 切 App 後選單勾勾會 stale（不反映新前景 App 的綁定）。
                self?.coreModeMenuToken += 1
            }
        }
        do {
            try hotkeyMonitor.start()
        } catch {
            statusLine = "熱鍵啟動失敗：請到「系統設定 › 隱私權與安全性 › 輔助使用」授權後重啟"
        }

        // 0.25s tick：驅動斷句與逾時
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self?.controller.tick(at: Date().timeIntervalSinceReferenceDate)
                    self?.refreshStatus()
                }
            }
        }
    }

    private func refreshStatus() {
        let next: String
        switch controller.phase {
        case .idle:
            next = controller.isLingering ? "可修正（延續窗）" : "待機"
        case .listening(.hold): next = "聽寫中（按住）"
        case .listening(.locked): next = "聽寫中（鎖定）"
        }
        // 只在真的變動時才寫回：statusLine 是 @Published，每次賦值（即使值相同）都會觸發
        // objectWillChange。0.25s tick 每輪都呼叫本函式，若無條件賦值，閒置時每 250ms 就
        // 讓觀察 delegate 的 MenuBarExtra 內容重建一次，開著的子選單會被立刻關掉（閃退）。
        guard statusLine != next else { return }
        statusLine = next
    }

    /// 除錯用：2 秒內切到任一文字欄位，驗證鍵入路徑
    func debugInsert() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            try? keystroke.insert("Saymend 鍵入測試 OK。")
        }
    }

    /// 除錯用：驗證「插入 → 尾端退格替換」路徑（含 ZWJ emoji 的字位計數）
    func debugReplace() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let coordinator = InsertionCoordinator(keystroke: keystroke, paste: PasteInserter())
            try? coordinator.insertFinalized("呃測試👨‍👩‍👧‍👦文字")
            let snapshot = coordinator.snapshotAndBeginNext()
            try? await Task.sleep(for: .seconds(1))
            _ = try? coordinator.replaceTail(snapshot, with: "測試👨‍👩‍👧‍👦文字。")
        }
    }

    /// 選單列點選第一區＝設本次聽寫的 session 覆蓋（規格 §3.2）。
    @MainActor
    func selectSessionCoreMode(_ modeID: String?) {
        settings.sessionCoreModeID = modeID
        coreModeMenuToken += 1
    }

    /// 選單列「設為全域預設」（規格 §3.2）。nil ＝ 回內建預設。
    @MainActor
    func selectDefaultCoreMode(_ modeID: String?) {
        settings.defaultCoreModeID = modeID
        coreModeMenuToken += 1
    }

    /// 選單列「將目前 App 綁定為此模式」（規格 §4.3）：寫入 AppProfile.coreModeID。
    /// 無 frontmost bundle ID 時不動作（選單項於該情境停用）。
    @MainActor
    func bindFrontAppToMode(_ modeID: String?) {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var p = profileStore.profile(for: bundleID)
        p.coreModeID = modeID          // nil ＝「跟隨全域」解除綁定
        profileStore.update(p)
        coreModeMenuToken += 1
    }

    /// 選單列顯示用：目前實際生效的模式（走完整解析鏈，非只讀 raw setting）。
    @MainActor
    func currentActiveMode() -> CoreMode {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let profile = bundle.map { profileStore.profile(for: $0) }
        return coreModeResolver.resolve(
            sessionModeID: settings.sessionCoreModeID,
            appModeID: profile?.coreModeID,
            defaultModeID: settings.defaultCoreModeID,
            availableModes: PromptAssembler.builtinCoreModes + coreModeStore.allUserModes())
    }

    /// 選單列與設定分頁共用的可選模式清單。
    @MainActor
    func allSelectableModes() -> [CoreMode] {
        PromptAssembler.builtinCoreModes + coreModeStore.allUserModes()
    }

    /// 開啟設定視窗（規格 §4.3「管理模式…」）。
    /// macOS 14+ 與更早版本的 selector 名稱不同；分頁定位由 SwiftUI 記憶上次選取的 tab 提供，
    /// 無公開 API 可強制切到特定 tab——使用者首次需自行點「核心模式」分頁。
    /// （此為 SwiftUI Settings scene 的已知限制，記入 §8。）
    @MainActor
    func openCoreModeSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
