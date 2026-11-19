/// 一次剪貼簿救援的結果（issue #71）。由 App 端的 `ClipboardChannel` 回報，controller 據此決定救援提示怎麼說。
///
/// 分得出「上一輪的救援此刻還在剪貼簿、被這次覆寫了」，**分不出使用者是否已經貼上過它**：
/// Cmd+V 是讀取，不推進 `NSPasteboard.changeCount`。所以提示只能說上一段「移到選單」，不能說「還沒取回」。
public enum ClipboardRescueOutcome: Equatable, Sendable {
    /// 重新開始一份：剪貼簿原本不是我方救援，或使用者已複製過別的東西（上一份已取回或放棄）
    case landed
    /// 接在同一輪上一份救援後面（剪貼簿仍是它，#56 的累積）
    case appended
    /// 剪貼簿原本是**別一輪**（別的聽寫 session）的救援，這次把它覆寫掉了
    case replacedEarlierRescue
    /// 寫不進剪貼簿（`setString` 回 false）：剪貼簿已放回原本的內容，這段只留在選單的「最近救援」
    case notWritten
}
