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
                Text("自訂規則不得牴觸核心規則（只整理不回答、JSON 格式契約）；牴觸時以核心規則為準。")
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
