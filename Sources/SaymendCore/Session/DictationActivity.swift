/// 熱鍵聽寫的對外狀態（本機控制介面用）。與 `ControlState` 一一對應，但不讓聽寫狀態機依賴協定型別。
public enum DictationActivity: Equatable, Sendable {
    case idle
    /// 麥克風開著
    case recording
    /// 麥克風已關，辨識引擎還在排空
    case transcribing
    /// 辨識完成，潤飾在途
    case polishing
}
