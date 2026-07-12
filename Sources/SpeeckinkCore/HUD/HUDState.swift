public enum ListeningMode: Equatable, Sendable {
    case hold
    case locked
}

/// HUD 顯示狀態（規格 §3.1／§3.5 的 M1 子集）
public enum HUDState: Equatable, Sendable {
    case hidden
    case listening(mode: ListeningMode, volatile: String)
    case notice(String)
}

public protocol HUDPresenting: AnyObject {
    func present(_ state: HUDState)
}
