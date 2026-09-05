import CoreGraphics

/// 合成鍵盤事件的「建構」與「送出」兩步（issue #38）。
///
/// 拆成兩步是為了讓 inserter 能先把一整段操作的所有事件建好、確認沒有任何一個建構失敗，
/// 再開始送出——`CGEvent(keyboardEventSource:…)` 是唯一會失敗的步驤，而 `post` 一旦執行就不可逆。
/// 舊實作在迴圈裡邊建邊送，第 N 次建構失敗時前 N−1 個事件已進了目標 App，呼叫端卻只拿到
/// 一個沒有 progress 資訊的 `postFailed`，無從回滾（詳見 #38 的三個 partial-progress bug）。
///
/// 測試以假通道在指定次數的建構回 nil、並記錄 post 次數，藉此斷言「拋錯＝零 post」。
protocol KeyEventChannel: AnyObject {
    /// 建構一個鍵盤事件；回 nil＝建構失敗（記憶體或事件系統暫時不可用）
    func makeKeyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent?
    /// 送進系統事件佇列。沒有 delivery acknowledgment——目標 App 靜默丟事件仍無法偵測。
    func post(_ event: CGEvent)
}

/// 真實通道：以 `.combinedSessionState` 事件來源建構、post 到 `.cghidEventTap`。
final class CGKeyEventChannel: KeyEventChannel {
    private let source = CGEventSource(stateID: .combinedSessionState)

    func makeKeyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent? {
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
    }

    func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }
}
