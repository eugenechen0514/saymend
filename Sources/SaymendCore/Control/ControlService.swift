import Foundation
import OSLog
import SaymendControl

/// 本機控制介面的請求處理器：把 socket 上的請求接到 CLI 聽寫與熱鍵聽寫的狀態上。
/// socket 本身（accept、uid 驗證、逐行切分）在 `SaymendControl.ControlServer`；這裡只有語意，可以不碰 socket 測試。
@MainActor
public final class ControlService: ControlRequestHandler {
    private final class Subscriber {
        let peer: any ControlPeer
        var last: Snapshot?
        init(peer: any ControlPeer) { self.peer = peer }
    }

    public struct Snapshot: Equatable, Sendable {
        public let state: ControlState
        public let source: ControlSource?
    }

    private let cli: CLIDictationController
    private let hotkeyActivity: () -> DictationActivity
    private let modelReady: () async -> Bool
    private let appVersion: String
    private let now: () -> Date
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    /// 正在等 dictate 結果的那條連線：它斷線＝取消那一段（CLI 被 kill 之後麥克風絕不能還開著）
    private var dictatePeer: ObjectIdentifier?
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var changeScheduled = false
    private static let log = Logger(subsystem: "io.saymend.app", category: "control")

    /// - Parameters:
    ///   - schedule: 狀態變化的合併點。預設排到 main queue 的下一個 turn——同一個 turn 裡相位可能連跳好幾次
    ///     （例如排隊接手：finishing → listening），只送最後的結果，不讓 events 串流出現一閃而過的狀態。
    public init(cli: CLIDictationController,
                hotkeyActivity: @escaping () -> DictationActivity,
                modelReady: @escaping () async -> Bool,
                appVersion: String,
                now: @escaping () -> Date = Date.init,
                schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { block in
                    DispatchQueue.main.async { MainActor.assumeIsolated(block) }
                }) {
        self.cli = cli
        self.hotkeyActivity = hotkeyActivity
        self.modelReady = modelReady
        self.appVersion = appVersion
        self.now = now
        self.schedule = schedule
    }

    /// 目前的對外狀態。CLI 聽寫進行中以它為準；否則看熱鍵聽寫；都沒有＝idle、沒有來源。
    public func snapshot() -> Snapshot {
        switch cli.phase {
        case .recording: return Snapshot(state: .recording, source: .cli)
        case .transcribing: return Snapshot(state: .transcribing, source: .cli)
        case .polishing: return Snapshot(state: .polishing, source: .cli)
        case .idle: break
        }
        switch hotkeyActivity() {
        case .recording: return Snapshot(state: .recording, source: .hotkey)
        case .transcribing: return Snapshot(state: .transcribing, source: .hotkey)
        case .polishing: return Snapshot(state: .polishing, source: .hotkey)
        case .idle: return Snapshot(state: .idle, source: nil)
        }
    }

    /// 兩個狀態機的任一個可能變了。合併到下一個 turn 才算、只送給「上次收到的值不同」的訂閱者。
    public func activityChanged() {
        guard !changeScheduled else { return }
        changeScheduled = true
        schedule { [weak self] in self?.broadcastIfChanged() }
    }

    public var subscriberCount: Int { subscribers.count }

    // MARK: - ControlRequestHandler

    public func handle(_ request: ControlRequest, peer: any ControlPeer) {
        switch request {
        case .status:
            let snap = snapshot()
            Task { [modelReady] in
                let ready = await modelReady()
                peer.send(.status(state: snap.state, source: snap.source, modelReady: ready))
                peer.close()
            }
        case .version:
            peer.send(.version(app: appVersion))
            peer.close()
        case .stop:
            if cli.stop() {
                peer.send(.ok)
            } else {
                peer.send(.error(code: .nothingToStop, message: "目前沒有錄音中的 CLI 聽寫"))
            }
            peer.close()
        case .cancel:
            if cli.cancel(source: "saymend cancel") {
                peer.send(.ok)
            } else {
                peer.send(.error(code: .nothingToStop, message: "目前沒有 CLI 聽寫"))
            }
            peer.close()
        case .events:
            let sub = Subscriber(peer: peer)
            subscribers[ObjectIdentifier(peer)] = sub
            let snap = snapshot()
            sub.last = snap
            peer.send(.state(state: snap.state, source: snap.source, at: now()))
        case .dictate(let options):
            // 先判忙碌再認領：已有別條連線在等結果時，不得把「斷線就取消」的認領搶過來
            guard !cli.isActive else {
                peer.send(.error(code: .busy, message: "已有一段 CLI 聽寫進行中"))
                peer.close()
                return
            }
            let id = ObjectIdentifier(peer)
            dictatePeer = id
            cli.start(options) { [weak self] event in
                switch event {
                case .started:
                    peer.send(.started)
                case .partial(let text):
                    peer.send(.partial(text))
                case .finished(let r):
                    self?.releaseDictate(id)
                    peer.send(.final(text: r.text, raw: r.raw, durationMs: r.durationMs))
                    peer.close()
                case .failed(let f):
                    self?.releaseDictate(id)
                    peer.send(.error(code: f.code, message: f.message))
                    peer.close()
                }
            }
        }
    }

    public func handleFollowUp(_ request: ControlRequest, peer: any ControlPeer) {
        // 只認 dictate 連線上的 cancel（CLI 收到 SIGINT／SIGTERM 時送）；其他一律忽略
        guard case .cancel = request, dictatePeer == ObjectIdentifier(peer) else { return }
        cli.cancel(source: "CLI 收到 SIGINT／SIGTERM")
    }

    public func peerClosed(_ peer: any ControlPeer) {
        let id = ObjectIdentifier(peer)
        subscribers.removeValue(forKey: id)
        if dictatePeer == id {
            dictatePeer = nil
            if cli.isActive {
                cli.cancel(source: "等待結果的 CLI 已斷線")
            }
        }
    }

    // MARK: - 私有

    private func releaseDictate(_ id: ObjectIdentifier) {
        if dictatePeer == id { dictatePeer = nil }
    }

    private func broadcastIfChanged() {
        changeScheduled = false
        let snap = snapshot()
        let at = now()
        for sub in subscribers.values where sub.last != snap {
            sub.last = snap
            sub.peer.send(.state(state: snap.state, source: snap.source, at: at))
        }
    }
}
