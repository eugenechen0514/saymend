import AppKit
import ApplicationServices
import SwiftUI
import SpeeckinkCore

@main
struct SpeeckinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Speeckink", systemImage: "mic.fill") {
            MenuContent(delegate: delegate)
        }
        Settings {
            SettingsView(settings: delegate.settings, vocab: delegate.vocabStore, history: delegate.historyStore)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Text(delegate.statusLine)
        Divider()
        Menu("輸出語系（本次聽寫）") {
            Button("跟隨設定：\(delegate.settings.outputLanguage.displayName)") {
                delegate.settings.sessionLanguageOverride = nil
            }
            Divider()
            ForEach(OutputLanguage.allCases, id: \.self) { lang in
                Button(lang.displayName) {
                    delegate.settings.sessionLanguageOverride = lang
                }
            }
        }
        SettingsLink { Text("設定…") }
        Button("測試插入（2 秒後打進聚焦欄位）") { delegate.debugInsert() }
        Button("測試替換（插入後 1 秒潤飾替換）") { delegate.debugReplace() }
        Divider()
        Button("結束 Speeckink") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    @Published var statusLine = "待機"

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
            .appendingPathComponent("Speeckink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    let vocabStore = FileVocabStore(fileURL: AppDelegate.supportDir.appendingPathComponent("vocab.json"))
    let profileStore = FileAppProfileStore(fileURL: AppDelegate.supportDir.appendingPathComponent("profiles.json"))
    let historyStore = try? GRDBHistoryStore.onDisk(directory: AppDelegate.supportDir)
    private let ocrReader = OCRContextReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 輔助功能權限：沒有就跳系統提示（熱鍵與鍵入都靠它）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        historyStore?.purge(olderThanDays: settings.historyRetentionDays)   // 啟動時清過期（規格 §4.9）

        let axInserter = AXInserter()
        let axReader = AXFieldReader(profiles: profileStore)
        let coordinator = InsertionCoordinator(keystroke: keystroke, paste: PasteInserter(),
                                               rangeReplacer: axInserter)
        let provider = OpenAICompatProvider(configProvider: { [settings] in settings.openAIConfig() })
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
        let asrEngine = SpeechAnalyzerEngine()
        asrEngine.contextualStrings = { [vocabStore, profileStore] in
            if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               profileStore.profile(for: bundle).vocabEnabled == false {
                return []
            }
            return vocabStore.all().map(\.phrase)
        }

        // 語系解析（M4 設計裁決 4）：session 覆蓋 > profile 固定 > 全域。
        // 標 @MainActor：closure 讀 profileStore／settings 並碰 NSWorkspace 前景 App，
        // IntentService 會在 MainActor 上呼叫（避免與設定 CRUD／能力回填的資料競爭）。
        let resolveLanguage: @MainActor () -> OutputLanguage = { [settings, profileStore] in
            if let override = settings.sessionLanguageOverride { return override }
            if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               let fixed = profileStore.profile(for: bundle).fixedLanguage {
                return fixed
            }
            return settings.outputLanguage
        }

        // prompt 4-6 層來源（每次 LLM 呼叫時讀取，設定即時生效）。
        // 標 @MainActor：closure 讀 vocabStore／profileStore／settings 並碰 NSWorkspace 前景 App，
        // IntentService 會在 MainActor 上呼叫（避免與設定 CRUD／能力回填的資料競爭）。
        let promptSources: @MainActor () -> PromptLayerSources = { [settings, profileStore, vocabStore] in
            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let profile = bundle.map { profileStore.profile(for: $0) }
            return PromptLayerSources(
                styleOverride: settings.styleRulesOverride,
                customPrompt: settings.customSystemPrompt.isEmpty ? nil : settings.customSystemPrompt,
                appPrompt: profile?.extraPrompt,
                vocab: (profile?.vocabEnabled ?? true) ? vocabStore.all() : [])
        }

        let intentService = IntentService(
            provider: provider,
            language: resolveLanguage,
            traditionalize: traditionalize,
            sources: promptSources
        )
        feedbackCoordinator = FeedbackCoordinator(overlay: overlay, hud: hud, profiles: profileStore)
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
            contextOCR: { [ocrReader] in await ocrReader.captureText() }
        )
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
        switch controller.phase {
        case .idle:
            statusLine = controller.isLingering ? "可修正（延續窗）" : "待機"
        case .listening(.hold): statusLine = "聽寫中（按住）"
        case .listening(.locked): statusLine = "聽寫中（鎖定）"
        }
    }

    /// 除錯用：2 秒內切到任一文字欄位，驗證鍵入路徑
    func debugInsert() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            try? keystroke.insert("Speeckink 鍵入測試 OK。")
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
}
