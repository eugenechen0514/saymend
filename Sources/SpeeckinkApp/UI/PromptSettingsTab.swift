import SwiftUI
import SpeeckinkCore

/// 全域自訂 system prompt＋輸出風格覆寫（規格 §4.4 第 3/4 層）。
/// 核心規則唯讀可檢視（規格：置頂且不可編輯，使用者內容不得覆蓋）。
struct PromptSettingsTab: View {
    let settings: AppSettings
    @State private var customPrompt: String
    @State private var styleOverride: String
    @State private var showCoreRules = false

    init(settings: AppSettings) {
        self.settings = settings
        _customPrompt = State(initialValue: settings.customSystemPrompt)
        _styleOverride = State(initialValue: settings.styleRulesOverride ?? "")
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
                DisclosureGroup("檢視內建核心規則（唯讀）", isExpanded: $showCoreRules) {
                    ScrollView {
                        Text(PromptAssembler(language: settings.outputLanguage).systemPrompt())
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: customPrompt) { _, v in settings.customSystemPrompt = v }
        .onChange(of: styleOverride) { _, v in settings.styleRulesOverride = v.isEmpty ? nil : v }
    }
}
