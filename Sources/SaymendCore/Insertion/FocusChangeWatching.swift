/// 焦點變更**當下**、新焦點元素的密碼欄判定（issue #70）。
///
/// 與 `FieldGate` 分開：`FieldGate` 回答「現在聚焦的是什麼」，是事件驅動的查詢——只在暫時文字或定稿
/// 抵達的那一刻才問。焦點若在兩次查詢之間「進入密碼欄 P、又離開 P」，閘門從頭到尾只看得到一般欄位。
/// 這個值是 AX 在焦點**移進某個元素的那一刻**推過來的，判定的是那個元素本身，不是事後再查一次目前焦點
/// ——事後再查正好會撞上「已經離開 P」的那一瞬間，等於重造 #70 的洞。
public enum FocusedFieldSecurity: Equatable, Sendable {
    /// 問到了、不是密碼欄（或元素本來就沒有 subrole 屬性，比照 #59 的寬鬆判定）
    case notSecure
    /// AX 明確回答：這個元素就是密碼欄位
    case secure
    /// AX 連續兩次問不出 subrole（逾時）：依 #59 fail closed，行為與 `.secure` 相同，分開只為事後量得出誤殺
    case secureUnknown
}

/// 聽寫期間的焦點變更監看（issue #70）。
///
/// **生命週期綁「錄音中」**：controller 進入 `.listening` 時 `startWatching`、離開時（放開熱鍵進排空窗、
/// 或任何直達封存的路徑）`stop()`。每一次 `startWatching` 回傳的 handle **恰 `stop()` 一次**——
/// 比照 #43 的 lease 紀律，測試以 start／stop 計數驗帳。
///
/// 只監看錄音中是刻意的：密碼外洩的前提是「焦點在 P 的期間有人說話而且被錄進去」。放開熱鍵之後
/// 不再收音，排空窗吐出的定稿全是錄音期間（已被監看涵蓋）說的話；排空窗內焦點才移進密碼欄，
/// 寫入前那道閘門（`InsertionCoordinator`）照樣擋得住，不需要把整段排空中的文字也一起作廢。
public protocol FocusChangeWatching: AnyObject {
    /// 開始監看。之後每次焦點變更，以**變更當下那個元素**的判定在 main thread 上呼叫 `onChange`。
    /// 讀不到 AX（App 不支援、observer 掛不上）＝不呼叫，維持 #21「缺 AX 照常聽寫」，
    /// 原本那兩道事件驅動的閘門仍在。
    ///
    /// **不得在 `startWatching` 裡同步呼叫 `onChange`**：controller 拿到 handle 之前若被回呼而硬停，
    /// 封存時還沒有 handle 可停，回傳的 watch 就會洩漏到 idle。開始當下的狀態由 controller 自己補查。
    @MainActor
    func startWatching(onChange: @escaping @MainActor (FocusedFieldSecurity) -> Void) -> any FocusWatch
}

/// 一次監看的 handle。`stop()` 之後不得再呼叫 `onChange`；重複 `stop()` 必須是 no-op。
public protocol FocusWatch: AnyObject {
    /// 確認監看仍掛在**目前焦點所屬的行程**上。不是的話改掛過去，並以那個元素的判定同步呼叫 `onChange`。
    /// AX observer 綁單一行程，而焦點可以跨行程移動卻不觸發 App 啟用（System Settings 的 remote view、
    /// 系統授權框、非啟用型 panel）——這些正是輸入密碼的地方。controller 在錄音中的每個 tick 呼叫。
    @MainActor
    func resync()

    @MainActor
    func stop()
}
