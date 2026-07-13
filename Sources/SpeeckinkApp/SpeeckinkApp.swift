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
            SettingsView(settings: delegate.settings)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Text(delegate.statusLine)
        Divider()
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
    private var hotkeyMonitor: HotkeyMonitor!
    private var tickTask: Task<Void, Never>?
    private let audio = AudioCapture()
    private let keystroke = KeystrokeInserter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 輔助功能權限：沒有就跳系統提示（熱鍵與鍵入都靠它）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let coordinator = InsertionCoordinator(keystroke: keystroke, paste: PasteInserter())
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
        let intentService = IntentService(
            provider: provider,
            language: { [settings] in settings.outputLanguage },
            traditionalize: traditionalize
        )
        controller = DictationController(
            audio: audio,
            asr: SpeechAnalyzerEngine(),
            coordinator: coordinator,
            intent: intentService,
            hud: hud,
            settings: settings
        )
        audio.levelHandler = { [weak self] level in self?.hud.updateLevel(level) }

        hotkeyMonitor = HotkeyMonitor(
            hotkey: { [settings] in settings.hotkey },
            isCapturing: { [weak self] in
                guard let self else { return false }
                return self.controller.phase != .idle
            }
        )
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
        case .idle: statusLine = "待機"
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
