import SwiftUI
import AppKit
import SpeeckinkCore

/// 詞彙表 CRUD＋JSON 匯入匯出（規格 §4.8）。store 為 nil（理論上僅預覽）顯示停用態。
struct VocabSettingsTab: View {
    let store: (any VocabStore)?
    @State private var entries: [VocabEntry] = []
    @State private var selection: UUID?
    @State private var phrase = ""
    @State private var mishearings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(entries, selection: $selection) {
                TableColumn("詞彙", value: \.phrase)
                TableColumn("常見誤轉寫") { entry in
                    Text(entry.mishearings.joined(separator: "、"))
                }
            }
            HStack {
                TextField("詞彙（如 openpets）", text: $phrase)
                TextField("誤轉寫，頓號分隔（如 歐噴佩茲、open pets）", text: $mishearings)
                Button("新增／更新") {
                    guard let store, !phrase.isEmpty else { return }
                    let mis = mishearings.split(separator: "、").map(String.init).filter { !$0.isEmpty }
                    if let selected = selection, var existing = entries.first(where: { $0.id == selected }) {
                        existing.phrase = phrase
                        existing.mishearings = mis
                        store.upsert(existing)
                    } else {
                        store.upsert(VocabEntry(phrase: phrase, mishearings: mis))
                    }
                    reload()
                }
                Button("刪除") {
                    guard let store, let selected = selection else { return }
                    store.delete(id: selected)
                    selection = nil
                    reload()
                }
                .disabled(selection == nil)
            }
            HStack {
                Button("匯入 JSON…") { importJSON() }
                Button("匯出 JSON…") { exportJSON() }
                Spacer()
                Text("注入：LLM prompt（永遠）＋ASR 語音偏置（下個 session 生效）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .disabled(store == nil)
        .onAppear { reload() }
        .onChange(of: selection) { _, sel in
            if let sel, let e = entries.first(where: { $0.id == sel }) {
                phrase = e.phrase
                mishearings = e.mishearings.joined(separator: "、")
            }
        }
    }

    private func reload() { entries = store?.all() ?? [] }

    private func importJSON() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        _ = try? store.importJSON(data)
        reload()
    }

    private func exportJSON() {
        guard let store, let data = try? store.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "speeckink-vocab.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
