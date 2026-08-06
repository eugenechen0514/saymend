public enum ListeningMode: Equatable, Sendable {
    case hold
    case locked
}

/// HUD 顯示狀態（規格 §3.1／§3.3／§3.4 的 M2 子集）
public enum HUDState: Equatable, Sendable {
    case hidden
    case listening(mode: ListeningMode, volatile: String)
    /// 選取即目標模式聽寫中（規格 §3.6）：緩衝不上屏，volatile 只進 HUD
    case selectionListening(mode: ListeningMode, volatile: String)
    /// 8 秒延續窗：可口頭修正／復原（規格 §3.4）
    case lingering
    /// M8：批次 ASR 引擎等待辨識結果中（spec §5.2）
    case transcribing
    /// M9：本機引擎載入模型中（首次含 ANE 編譯，可能數分鐘）
    case loadingModel
    /// issue #18：聽寫中但整段都沒偵測到語音（麥克風可能太遠）。
    /// 與 `.listening` 並列而非取代其語意——聽寫階段仍在進行，那個事實不能從畫面上消失。
    case noSpeechDetected(mode: ListeningMode)
    case notice(String)
    /// 最近異動的 inline diff（規格 §3.5 降級）：overlay 不可用時在 HUD 呈現
    case diff([DiffWindow])
}

public protocol HUDPresenting: AnyObject {
    func present(_ state: HUDState)
}
