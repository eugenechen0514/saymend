import SwiftUI
import SaymendCore

/// 設定頁「遠端」的文字（測試也讀這裡，確保安全說明真的出現在畫面上）。
enum RemoteSettingsText {
    static let securityTitle = "安全性"
    /// 必須明講的界線（docs/remote.md「安全性」）
    static let securityWarning = "連線開著時，遠端主機上以同一個帳號執行的任何程式（以及那台主機的 root）都能叫這台 Mac 聽寫並拿到文字，也能讓這台 Mac 朗讀文字。只連你信任的主機，不要用多人共用的帳號。"
    static let securityDetails = [
        "不存密碼、不存金鑰：一律呼叫系統的 ssh，用你自己的 ~/.ssh/config、ssh-agent 與金鑰。Saymend 不會詢問密碼，終端機要能免密碼 ssh 登入才連得上。",
        "遠端發起的聽寫，浮條會顯示主機名稱；按 Esc 可以取消。",
        "只接受固定的請求：saymend 的 status、dictate、stop、cancel、events、--version（參數有白名單）與 say 朗讀，不替遠端執行其他指令。",
        "本機與遠端的 socket 都只有你的帳號能連（權限 0600、資料夾 0700）；遠端不開任何 TCP port。紀錄只有指令名稱、字數與結束碼，不含你說的話或朗讀的內容。",
        "關掉開關或結束 Saymend 時，SSH 連線會收掉，進行中的遠端聽寫取消、麥克風關閉。",
    ]
    static let requirements = "遠端主機需要 python3（3.8 以上），sshd 允許轉發（預設允許）。"
    static let setupHint = "在那台機器的 Claude Code 執行一次（設定會留著）："
    static let copyLines = "複製這兩行"
    static let empty = "還沒有主機。"
    static let add = "新增主機…"
    static let unavailable = "控制介面沒有啟動，無法提供遠端連線（另一個 Saymend 可能正在使用 control.sock）。"
}

/// 遠端分頁（docs/remote.md）：主機清單與每台主機的連線開關、狀態、測試、移除。
struct RemoteSettingsTab: View {
    let manager: RemoteBridgeManager?
    let clipboard: ClipboardChannel
    @State private var showingAdd = false

    var body: some View {
        if let manager {
            Form {
                Section(RemoteSettingsText.securityTitle) {
                    Text(RemoteSettingsText.securityWarning)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ForEach(RemoteSettingsText.securityDetails, id: \.self) { line in
                        Text("・" + line).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(RemoteSettingsText.requirements).font(.caption).foregroundStyle(.secondary)
                }
                Section("主機") {
                    if !manager.isControlAvailable {
                        Text(RemoteSettingsText.unavailable).font(.caption).foregroundStyle(.orange)
                    }
                    if manager.links.isEmpty {
                        Text(RemoteSettingsText.empty).foregroundStyle(.secondary)
                    }
                    ForEach(manager.links) { link in
                        RemoteHostRow(link: link, manager: manager, clipboard: clipboard)
                    }
                    Button(RemoteSettingsText.add) { showingAdd = true }
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $showingAdd) { AddRemoteHostSheet(manager: manager) }
        } else {
            Text(RemoteSettingsText.unavailable).foregroundStyle(.secondary)
        }
    }
}

/// 清單裡的一台主機。
struct RemoteHostRow: View {
    let link: RemoteLink
    let manager: RemoteBridgeManager
    let clipboard: ClipboardChannel
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.host.displayName).font(.headline)
                    Text(link.host.kind == .sshConfig ? "~/.ssh/config" : "手動設定")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("連線").font(.caption).foregroundStyle(.secondary)
                Toggle("連線", isOn: Binding(get: { link.isOn },
                                            set: { $0 ? link.connect() : link.disconnect() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(link.activity != nil)
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(link.activity ?? link.state.label)
                if link.activity == nil, let result = link.lastResult {
                    Text("｜\(result)").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let error = link.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lines = link.setupLines {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RemoteSettingsText.setupHint).font(.caption).foregroundStyle(.secondary)
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HistoryCopyButton(text: lines.joined(separator: "\n"), clipboard: clipboard,
                                      title: RemoteSettingsText.copyLines)
                        .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Toggle("app 啟動時自動連線", isOn: Binding(get: { link.host.autoConnect },
                                                   set: { manager.setAutoConnect(id: link.id, $0) }))
                .font(.caption)
            HStack {
                Button("測試") { Task { await link.test() } }
                    .disabled(link.activity != nil || link.state == .connecting || link.state == .reconnecting)
                Button("移除遠端的 client") { Task { await link.uninstallClient() } }
                    .disabled(link.activity != nil)
                Spacer()
                Button("移除主機", role: .destructive) { confirmingRemove = true }
                    .disabled(link.activity != nil)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .confirmationDialog("從清單移除 \(link.host.displayName)？", isPresented: $confirmingRemove) {
            Button("移除", role: .destructive) { manager.remove(id: link.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會從 Saymend 的清單移除；遠端的 client 要先用「移除遠端的 client」刪掉。")
        }
    }

    private var statusColor: Color {
        switch link.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return link.lastError == nil ? .gray : .orange
        }
    }
}

/// 新增主機：從 ~/.ssh/config 的 Host 挑（下拉選單，副標 user@hostname:port），或手動填。
struct AddRemoteHostSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sshConfig = "從 ~/.ssh/config"
        case manual = "手動輸入"
        var id: String { rawValue }
    }

    let manager: RemoteBridgeManager
    /// ~/.ssh/config 的主機（預設讀真的設定；畫面快照換成假資料）
    var loadEntries: (() async -> [SSHConfigEntry])?
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .sshConfig
    @State private var entries: [SSHConfigEntry] = []
    @State private var loading = true
    @State private var selected: SSHConfigEntry?
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var autoConnect = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增遠端主機").font(.headline)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .sshConfig:
                if loading {
                    ProgressView().controlSize(.small)
                } else if entries.isEmpty {
                    Text("~/.ssh/config 裡沒有可用的 Host（萬用字元的 Host 不列）。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(entries) { entry in
                            Button { selected = entry } label: {
                                Text(entry.alias)
                                if let subtitle = entry.subtitle { Text(subtitle) }
                            }
                        }
                    } label: {
                        Text(selected.map { e in e.subtitle.map { "\(e.alias)（\($0)）" } ?? e.alias } ?? "選擇主機")
                    }
                    Text("連線參數由 ssh 自己解析（ssh -G），Include 與 Match 都照你的設定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .manual:
                TextField("主機（名稱或 IP）", text: $host)
                TextField("port（留白＝依 ssh 設定，通常是 22）", text: $port)
                TextField("使用者（留白＝依 ssh 設定）", text: $user)
                Text("驗證一樣交給系統的 ssh（金鑰、ssh-agent）；Saymend 不存密碼。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("app 啟動時自動連線", isOn: $autoConnect)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("新增") { add() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
        .task {
            entries = await (loadEntries ?? { await manager.sshConfigEntries() })()
            selected = entries.first
            loading = false
        }
    }

    private func add() {
        let newHost: RemoteHost
        switch mode {
        case .sshConfig:
            guard let selected else { error = "請選一台主機"; return }
            newHost = RemoteHost(kind: .sshConfig, host: selected.alias, autoConnect: autoConnect)
        case .manual:
            let trimmedPort = port.trimmingCharacters(in: .whitespaces)
            var portValue: Int?
            if !trimmedPort.isEmpty {
                guard let p = Int(trimmedPort) else { error = "port 必須是數字"; return }
                portValue = p
            }
            let trimmedUser = user.trimmingCharacters(in: .whitespaces)
            newHost = RemoteHost(kind: .manual, host: host.trimmingCharacters(in: .whitespaces), port: portValue,
                                 user: trimmedUser.isEmpty ? nil : trimmedUser, autoConnect: autoConnect)
        }
        if let problem = manager.add(newHost) {
            error = problem
        } else {
            dismiss()
        }
    }
}
