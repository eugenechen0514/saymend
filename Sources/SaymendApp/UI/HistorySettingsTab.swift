import AppKit
import SwiftUI
import SaymendCore

/// History 分頁「複製最終文字」的文案（issue #42）：剪貼簿裡還是上次聽寫救援的內容時，複製前先確認。
/// 「還在剪貼簿」只代表自救援後沒被別的內容取代——我們不知道使用者貼過沒有（貼上不會動剪貼簿）。
enum HistoryClipboardText {
    static let copyButton = "複製最終文字"
    static let overwriteRescueTitle = "剪貼簿裡還是上次聽寫救援的內容"
    static let overwriteRescueMessage = "那段文字自救援後還沒被別的內容取代。若你已經貼過了，可以放心覆蓋。"
    static let overwrite = "覆蓋"
    static let cancel = "取消"
}

/// 聽寫歷史瀏覽（規格 §4.9：供回查、複製、除錯）。
struct HistorySettingsTab: View {
    let store: (any HistoryRecording)?
    let settings: AppSettings
    let clipboard: ClipboardChannel
    @State private var sessions: [HistorySessionRecord] = []
    @State private var selection: String?
    @State private var enabled: Bool
    @State private var retentionDays: Int

    init(store: (any HistoryRecording)?, settings: AppSettings, clipboard: ClipboardChannel = .general) {
        self.store = store
        self.settings = settings
        self.clipboard = clipboard
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
                    HistoryCopyButton(text: sessions.first { $0.id == selected }?.finalText ?? "",
                                      clipboard: clipboard)
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

    /// 診斷數字的一行摘要。兩個數字都取涵蓋片段的**最壞值**（見 `TranscriptQuality`）。
    /// 片段數列出來是為了看得見涵蓋範圍，但它**不是量測次數**——同一趟解碼切出的片段
    /// 共用同一組數字，所以兩筆診斷數字一樣往往只代表它們出自同一趟解碼。
    static func qualityLine(_ d: ASRDiagnosticRecord) -> String {
        String(format: "對數機率 %.2f · 壓縮比 %.2f · %d 段",
               d.minAvgLogprob, d.maxCompressionRatio, d.segmentCount)
    }
}

/// 「複製最終文字」（issue #42）：走 ClipboardChannel；剪貼簿裡還是上次救援的內容時先確認再覆蓋。
struct HistoryCopyButton: View {
    let text: String
    let clipboard: ClipboardChannel
    /// 等待使用者確認覆蓋救援內容；true 時顯示確認 alert。
    @State private var confirmingOverwrite = false

    var body: some View {
        Button(HistoryClipboardText.copyButton) {
            // 「（未定稿）」的 session 沒有最終文字：空字串不寫，更不能拿它洗掉救援。
            guard !text.isEmpty else { return }
            // 按下當下才查，不用快照：分頁開著時背景聽寫可能剛落了一份救援。
            // 先收尾在途 paste 再判斷——救援可能正被它暫時擠開，直接看會漏判、跳過確認就覆寫。
            if clipboard.rescueInClipboardBeforeWriting() != nil {
                confirmingOverwrite = true
            } else {
                clipboard.copyForUser(text)
            }
        }
        .disabled(text.isEmpty)
        .alert(HistoryClipboardText.overwriteRescueTitle, isPresented: $confirmingOverwrite) {
            Button(HistoryClipboardText.overwrite, role: .destructive) { clipboard.copyForUser(text) }
            Button(HistoryClipboardText.cancel, role: .cancel) {}
        } message: {
            Text(HistoryClipboardText.overwriteRescueMessage)
        }
    }
}
