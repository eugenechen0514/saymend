import SwiftUI
import SaymendCore

/// 全域自訂 system prompt＋輸出風格覆寫（規格 §4.4 第 3/4 層）。
/// 組裝後的 system prompt 唯讀可檢視（規格：置頂且不可編輯，使用者內容不得覆蓋）。
struct PromptSettingsTab: View {
    let settings: AppSettings
    let coreModes: (any CoreModeStore)?
    @State private var customPrompt: String
    @State private var styleOverride: String
    @State private var showCoreRules = false

    init(settings: AppSettings, coreModes: (any CoreModeStore)? = nil) {
        self.settings = settings
        self.coreModes = coreModes
        _customPrompt = State(initialValue: settings.customSystemPrompt)
        _styleOverride = State(initialValue: settings.styleRulesOverride ?? "")
    }

    /// 預覽用的有效模式。`appModeID` 傳 nil：預覽時 frontmost app 就是 Saymend
    /// 自己，拿它去查 per-app 綁定沒有意義；故預覽呈現「不含 per-app 綁定」的情境。
    private var previewMode: CoreMode {
        CoreModeResolver().resolve(
            sessionModeID: settings.sessionCoreModeID,
            appModeID: nil,
            defaultModeID: settings.defaultCoreModeID,
            availableModes: PromptAssembler.builtinCoreModes + (coreModes?.allUserModes() ?? []))
    }

    var body: some View {
        Form {
            Section("全域自訂規則（prompt 第 4 層）") {
                TextEditor(text: $customPrompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                Text("這是你本人的設定，會確實套用——可要求後綴、簽名、特定措辭或格式。唯一限制：不會改變意圖判定（接續輸入／修改指令／復原）與 JSON 輸出格式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("輸出風格（prompt 第 3 層；留空＝內建預設）") {
                TextEditor(text: $styleOverride)
                    .font(.body.monospaced())
                    .frame(minHeight: 72)
                Button("恢復內建預設") { styleOverride = "" }
            }
            Section {
                DisclosureGroup("檢視組裝後的 system prompt（唯讀）", isExpanded: $showCoreRules) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目前模式：\(previewMode.name)　（不含 per-app 綁定；實際送出時會套用目標 App 的綁定）")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Text(PromptAssembler(language: settings.outputLanguage,
                                                 mode: previewMode).systemPrompt())
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: customPrompt) { _, v in settings.customSystemPrompt = v }
        .onChange(of: styleOverride) { _, v in settings.styleRulesOverride = v.isEmpty ? nil : v }
    }
}
