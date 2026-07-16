import SwiftUI
import SpeeckinkCore

struct CoreModeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CoreModeDraft
    let isReadOnly: Bool
    let onSave: (String, String) throws -> Void

    init(name: String, systemRules: String, isReadOnly: Bool,
         onSave: @escaping (String, String) throws -> Void) {
        _draft = State(initialValue: CoreModeDraft(name: name, systemRules: systemRules))
        self.isReadOnly = isReadOnly
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isReadOnly ? "檢視內建模式" : "編輯模式").font(.headline)

            Form {
                TextField("模式名稱", text: $draft.name)
                    .disabled(isReadOnly)
                TextEditor(text: $draft.systemRules)
                    .frame(minHeight: 220)
                    .font(.body.monospaced())
                    .disabled(isReadOnly)
            }

            // 規格 §4.4：內建檢視必須顯示可調範圍與不可動邊界，且不得宣稱完全防 prompt injection
            Text("核心模式可調整回答、逐字或改寫策略；JSON 格式、intent 列舉與上下文反注入規則由 Speeckink 固定，無法修改。")
                .font(.caption).foregroundStyle(.secondary)

            if let err = draft.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button(isReadOnly ? "關閉" : "取消") { dismiss() }
                if !isReadOnly {
                    Button("儲存") {
                        do {
                            try onSave(draft.name, draft.systemRules)
                            draft.markSaved()
                        } catch let e as CoreModeStoreError {
                            draft.applyStoreError(e)     // 錯誤留在 sheet 上，不關閉
                        } catch {
                            draft.applyStoreError(.persistenceFailed)
                        }
                    }
                    .disabled(!draft.canSave)
                }
            }
        }
        .padding()
        .frame(width: 540, height: 440)
        .onChange(of: draft.shouldDismiss) { _, done in
            if done { dismiss() }               // 只有成功才關
        }
    }
}
