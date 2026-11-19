/// 一次剪貼簿救援對「上一段救援」造成的影響（issue #71）。由 App 端的 `ClipboardChannel` 回報。
///
/// 只分得出「上一輪的救援此刻還在剪貼簿、被這次覆寫了」，**分不出使用者是否已經貼上過它**：
/// Cmd+V 是讀取，不推進 `NSPasteboard.changeCount`。所以提示只能說「已被取代」，不能說「還沒取回」。
public enum ClipboardRescueOutcome: Equatable, Sendable {
    /// 一般情況：剪貼簿原本不是我方救援、是同一輪的救援（接在後面），或使用者已複製過別的東西。
    /// 寫入失敗（`setString` 回 false）也回這個：剪貼簿已放回原本的內容，沒有東西被取代。
    case landed
    /// 剪貼簿原本是**上一輪**（別的聽寫 session）的救援，這次把它覆寫掉了。
    case replacedEarlierRescue
}
