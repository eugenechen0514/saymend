import SwiftUI
import SpeeckinkCore

struct CoreModeSettingsTab: View {
    let store: (any CoreModeStore)?          // nil ＝ 預覽態（比照 VocabSettingsTab 慣例）

    @State private var userModes: [CoreMode] = []
    @State private var editing: CoreMode?
    @State private var viewingBuiltin: CoreMode?
    @State private var isCreatingNew = false
    @State private var listError: String?

    var body: some View {
        Form {
            Section("內建") {
                ForEach(PromptAssembler.builtinCoreModes) { m in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(m.name).bold()
                            Text(m.systemRules.prefix(50) + "…")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("檢視") { viewingBuiltin = m }
                    }
                }
            }
            Section("我的模式") {
                if userModes.isEmpty {
                    Text("尚無自建模式").foregroundStyle(.secondary)
                }
                ForEach(userModes) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("編輯") { editing = m }
                        Button("刪除") { delete(m) }
                    }
                }
                Button("新增模式") { isCreatingNew = true }
                    .disabled(store == nil)
                if let e = listError {
                    Text(e).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .disabled(store == nil)
        .onAppear { reload() }
        .sheet(item: $viewingBuiltin) { m in
            CoreModeEditorSheet(name: m.name, systemRules: m.systemRules,
                                isReadOnly: true, onSave: { _, _ in })
        }
        .sheet(item: $editing) { m in
            CoreModeEditorSheet(name: m.name, systemRules: m.systemRules, isReadOnly: false) { n, r in
                guard let store else { throw CoreModeStoreError.persistenceFailed }
                var updated = m
                updated.name = n
                updated.systemRules = r
                updated.updatedAt = Date()
                try store.update(updated)
                reload()
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            // 新增：預載「純聽寫整理」規則作起手範本，但名稱留空、新 UUID、isBuiltin = false
            CoreModeEditorSheet(name: "",
                                systemRules: PromptAssembler.pureDictationMode.systemRules,
                                isReadOnly: false) { n, r in
                guard let store else { throw CoreModeStoreError.persistenceFailed }
                try store.add(CoreMode(name: n, systemRules: r))
                reload()
            }
        }
    }

    private func reload() {
        listError = nil
        userModes = store?.allUserModes() ?? []
    }

    private func delete(_ m: CoreMode) {
        guard let store else { return }
        do {
            try store.delete(id: m.id)
            reload()
        } catch let e as CoreModeStoreError {
            listError = CoreModeDraft.describe(e)      // 刪除失敗必須顯示，不可 try?
        } catch {
            listError = CoreModeDraft.describe(.persistenceFailed)
        }
    }
}
