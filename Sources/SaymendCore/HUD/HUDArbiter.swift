import Foundation

/// HUD 暫態的自動隱藏時長（`HUDWindowController` 用）。
/// 放在 Core 是為了讓「救援提示的保護期必須短於 notice 壽命」能被測試釘住（`HUDArbiter.minimumHold`）。
public enum HUDTiming {
    public static let noticeLifetime: TimeInterval = 2.5
    public static let diffLifetime: TimeInterval = 4.0
}

/// 主執行緒延遲執行一次。不提供取消：`HUDArbiter` 用 epoch 忽略過期的回呼。
/// 形狀比照 App 端的 `ClipboardTimer`——抽出來只為了讓保護期的交錯能在測試裡確定性重現。
public protocol HUDScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void)
}

public final class MainQueueHUDScheduler: HUDScheduling {
    public init() {}
    public func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }
}

/// 救援提示的最短顯示保證（issue #61）：包在真正的 HUD 外面的 decorator。
///
/// **保證**：`presentRescueNotice` 送出起 `minimumHold` 秒內，下游收不到任何非救援的 present。
/// 期間到達的狀態放進兩個延後槽，到期時以「先持久、再暫態」壓縮重播——下游的覆寫語意是
/// 「最後一個持久狀態決定 persistentState、之後最後一個暫態決定畫面與 hideTask」，所以重播完的最終狀態
/// 與「保護期間依序全部送出」完全相同。只留一個槽會丟掉 `.hidden`：延續窗中遲到的救援之後若是
/// `.hidden` 接 notice，只重播 notice 會讓 window 的 persistentState 停在 `.lingering`，
/// 2.5 秒後已封存的 session 會叫回「可修正／復原」（幽靈延續窗）。
///
/// 連續多則救援提示：**取代並重新計時**（不排隊、不計數）。同一輪的救援已在剪貼簿裡累積（#56），
/// 最新一則就足以描述剪貼簿狀態；排隊的話 N 則會擋住聽寫回饋 N × 2 秒。
/// 熱鍵／Esc **不**提前解除保護（Eugene 裁定 Q2），最多延後 2 秒。
///
/// 沒有保護期時一律原樣直通：保護期以外的行為與沒包 arbiter 時逐位元相同。
/// 只在 main thread 使用、不加鎖（同 `HUDWindowController.present` 的 assert 紀律）。
public final class HUDArbiter: HUDPresenting {
    /// 必須 < `HUDTiming.noticeLifetime`：否則 window 自己的 hideTask 會先把提示收掉，保證形同虛設。
    public static let minimumHold: TimeInterval = 2.0

    private struct Hold {
        let epoch: Int
        var deferredPersistent: HUDState?
        var deferredTransient: HUDState?
    }

    private let inner: any HUDPresenting
    private let scheduler: any HUDScheduling
    private var hold: Hold?
    private var epoch = 0

    public init(inner: any HUDPresenting, scheduler: any HUDScheduling = MainQueueHUDScheduler()) {
        self.inner = inner
        self.scheduler = scheduler
    }

    public func present(_ state: HUDState) {
        guard var current = hold else {
            inner.present(state)
            return
        }
        if Self.isPersistent(state) {
            // 新的持久狀態會在下游把較早的暫態蓋掉（HUDWindowController 開頭無條件 cancel hideTask），
            // 所以延後的暫態此刻已經過時。
            current.deferredPersistent = state
            current.deferredTransient = nil
        } else {
            current.deferredTransient = state
        }
        hold = current
    }

    public func presentRescueNotice(_ message: String) {
        epoch &+= 1
        let e = epoch
        // 取代：延後的持久狀態保留（它仍是提示之下的底層狀態），延後的暫態作廢（被新提示蓋掉）
        hold = Hold(epoch: e, deferredPersistent: hold?.deferredPersistent, deferredTransient: nil)
        // 轉送 rescue 而不是 `.notice`：日後要讓 window 自己拉長救援提示的壽命，只需 App 端覆寫，Core 不動
        inner.presentRescueNotice(message)
        scheduler.schedule(after: Self.minimumHold) { [weak self] in self?.endHold(e) }
    }

    private func endHold(_ e: Int) {
        // 過期回呼（已被後來的救援提示取代）或根本不在保護期：忽略，不得捏造任何狀態
        guard let current = hold, current.epoch == e else { return }
        hold = nil
        if let persistent = current.deferredPersistent { inner.present(persistent) }
        if let transient = current.deferredTransient { inner.present(transient) }
    }

    /// 分類逐項對齊 `HUDWindowController.present` 的持久／暫態兩組。
    /// 不寫 `default`：日後新增 `HUDState` case，編譯器會逼著回來歸類。
    static func isPersistent(_ state: HUDState) -> Bool {
        switch state {
        case .hidden, .listening, .selectionListening, .lingering, .transcribing, .loadingModel, .noSpeechDetected:
            return true
        case .notice, .diff:
            return false
        }
    }
}
