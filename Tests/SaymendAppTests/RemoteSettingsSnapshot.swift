import AppKit
import Foundation
import SwiftUI
import Testing
import SaymendCore
@testable import SaymendApp

/// 設定頁「遠端」的畫面快照（預設跳過）：`SAYMEND_SNAPSHOT_DIR=<資料夾>` 才執行，把幾種狀態畫成 PNG 給人看。
/// 不比對像素——用來在沒辦法實機點 UI 時檢查版面與文字有沒有擠壞。
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SAYMEND_SNAPSHOT_DIR"] != nil))
struct RemoteSettingsSnapshot {
    @Test func renderStates() throws {
        let out = try #require(ProcessInfo.processInfo.environment["SAYMEND_SNAPSHOT_DIR"])
        _ = NSApplication.shared
        let settings = AppSettings(defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!,
                                   secrets: InMemorySecretStore())
        let manager = RemoteBridgeManager(settings: settings, socketDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                          clientScriptURL: nil, appVersion: "t")
        manager.add(RemoteHost(kind: .sshConfig, host: "devbox", autoConnect: true))
        manager.add(RemoteHost(kind: .manual, host: "10.0.0.5", port: 2222, user: "eve"))
        manager.add(RemoteHost(kind: .sshConfig, host: "staging"))
        manager.attach(connectControl: { _ in throw RemoteBridgeError.controlUnavailable }, cancelDictation: { _ in })
        manager.links[0].setPreviewState(.connected, isOn: true, lastResult: "Saymend：idle", remoteHome: "/home/alice")
        manager.links[1].setPreviewState(.disconnected, isOn: false,
                                         lastError: "SSH 驗證失敗（eve@10.0.0.5: Permission denied (publickey).）。Saymend 不會詢問密碼：請設定金鑰或 ssh-agent，讓終端機的 ssh 不必輸入密碼就能登入")
        manager.links[2].setPreviewState(.reconnecting, isOn: true,
                                         lastError: "SSH 連線失敗：ssh: connect to host staging port 22: Connection refused")
        try render(RemoteSettingsTab(manager: manager, clipboard: .general), size: CGSize(width: 560, height: 1250),
                   to: out + "/remote-tab.png")
        let fake = [SSHConfigEntry(alias: "devbox", hostname: "10.0.0.1", user: "alice", port: 22),
                    SSHConfigEntry(alias: "staging", hostname: "staging.example.com", user: "deploy", port: 2222)]
        try render(AddRemoteHostSheet(manager: manager, loadEntries: { fake }), size: CGSize(width: 440, height: 300),
                   to: out + "/remote-add.png")
    }

    private func render<V: View>(_ view: V, size: CGSize, to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
