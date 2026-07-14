import AppKit
import SwiftUI
import SpeeckinkCore

/// 聽寫歷史瀏覽（規格 §4.9：供回查、複製、除錯）。
struct HistorySettingsTab: View {
    let store: (any HistoryRecording)?
    let settings: AppSettings
    @State private var sessions: [HistorySessionRecord] = []
    @State private var selection: String?
    @State private var enabled: Bool
    @State private var retentionDays: Int

    init(store: (any HistoryRecording)?, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _enabled = State(initialValue: settings.historyEnabled)
        _retentionDays = State(initialValue: settings.historyRetentionDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("記錄聽寫歷史", isOn: $enabled)
                Stepper("保留 \(retentionDays) 天", value: $retentionDays, in: 1...365)
                Spacer()
                Button("全部清除") {
                    store?.deleteAll()
                    reload()
                }
            }
            Table(sessions, selection: $selection) {
                TableColumn("時間") { s in Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("App") { s in Text(s.appName ?? "—") }
                TableColumn("最終文字") { s in Text(s.finalText ?? "（未定稿）").lineLimit(1) }
            }
            if let selected = selection {
                let exchanges = store?.exchanges(sessionID: selected) ?? []
                List(exchanges, id: \.id) { ex in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🎙 \(ex.utteranceRaw)").font(.caption)
                        Text("→ [\(ex.outcomeKind)] \(ex.outcomeText ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 120)
                HStack {
                    Button("複製最終文字") {
                        let text = sessions.first { $0.id == selected }?.finalText ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        .padding()
        .disabled(store == nil)
        .onAppear { reload() }
        .onChange(of: enabled) { _, v in settings.historyEnabled = v }
        .onChange(of: retentionDays) { _, v in
            settings.historyRetentionDays = v
            store?.purge(olderThanDays: v)
        }
    }

    private func reload() { sessions = store?.recentSessions(limit: 100) ?? [] }
}
