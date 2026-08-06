import AppKit
import SwiftUI
import SaymendCore

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
                let diagnostics = store?.asrDiagnostics(sessionID: selected) ?? []
                // 兩份資料的錨點不同（話語閉合後 vs 定稿當下），故並排而非合併——
                // 硬湊成一列會在其中一邊缺列時對錯行，那正是回查時最容易看走眼的地方。
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("話語與結果").font(.caption).foregroundStyle(.secondary)
                        List(exchanges, id: \.id) { ex in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("🎙 \(ex.utteranceRaw)").font(.caption)
                                Text("→ [\(ex.outcomeKind)] \(ex.outcomeText ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    // issue #10：辨識器對每段定稿文字的自評。幻覺輸出與正常語句的對數機率
                    // 若分得開，調門檻就比維護一份永遠追不完的字串黑名單乾淨。
                    VStack(alignment: .leading, spacing: 2) {
                        Text("辨識品質（僅本機引擎）").font(.caption).foregroundStyle(.secondary)
                        List(diagnostics, id: \.id) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.finalizedText).font(.caption).lineLimit(1)
                                Text(Self.qualityLine(d))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
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

    /// 診斷數字的一行摘要。兩個數字都取涵蓋片段的**最壞值**（見 `TranscriptQuality`），
    /// 片段數列出來，是為了讓「極值來自一個片段還是二十個」在回查時看得見。
    static func qualityLine(_ d: ASRDiagnosticRecord) -> String {
        String(format: "對數機率 %.2f · 壓縮比 %.2f · %d 段",
               d.minAvgLogprob, d.maxCompressionRatio, d.segmentCount)
    }
}
