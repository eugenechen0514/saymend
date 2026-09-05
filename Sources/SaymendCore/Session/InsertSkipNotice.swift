import Foundation

/// 潤飾未能套用的成因分類（M10-C spec §4.5）。
/// 這四種以前在畫面上長得一模一樣（都只顯示「未潤飾」），使用者無從分辨剛剛發生了什麼。
public enum InsertSkipCause: Equatable, Sendable {
    case frozen         // 帳本已凍結：聽寫中手動打字或點擊，本段不再自動改寫
    case tailAdvanced   // 該句已不在尾端，且回收也未成功
    case unverified     // 無 anchor／identity／AX 能力，無法確認文字位置（issue #44）：什麼都沒動
    case unknown        // 未預期的插入錯誤
}

/// 插入側「未潤飾」文案的唯一定義點，比照 `degradedReason`（LLM 側）的體例：
/// 語彙集中一處、測試以全等斷言鎖定，避免同一句話在多個呼叫點各寫一份而逐漸漂移。
/// 保留「未潤飾」前綴——使用者已習慣這個詞，加原因是補充而非替換。
public func insertSkipNotice(_ cause: InsertSkipCause) -> String {
    switch cause {
    case .frozen:       return "未潤飾（已停止改寫）"
    case .tailAdvanced: return "未潤飾（文字位置已變動）"
    case .unverified:   return "未潤飾（無法確認文字位置）"
    case .unknown:      return "未潤飾（未知錯誤）"
    }
}
