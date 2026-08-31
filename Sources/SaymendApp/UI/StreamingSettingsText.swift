import SwiftUI
import SaymendCore

/// 串流設定的使用者可見說明。抽離 `SettingsView` 是為了讓產品取捨能直接測試，
/// 避免只剩「套件預設」數字，卻沒說預設值對短句體感的影響。
/// Esc 退回聽寫設定的使用者可見說明（issue #21）。與串流取捨共用同一個
/// `Text` visibility test seam，避免警告只存在於註解或被 `.hidden()` 遮掉。
enum EscapeRetractionSettingsText {
    static let polishedExplanation =
        "預設開啟。聽寫仍在進行時按 Esc，會退掉本次已上屏的全部文字，包含已潤飾的部分。關閉時保留已經潤飾落定的文字。"
    static let frozenExplanation =
        "預設關閉以遵守凍結後不再改寫的原則。開啟後，Esc 可能連你凍結後自己輸入的內容一起刪掉，而且無法復原。"
}

/// 兩個 Toggle 的 label、說明與 persistence binding 同源。SettingsView 只 `ForEach` 此表，
/// 因而不存在兩條 type-correct `onChange` 可以接反；測試直接驅動相同 Binding。
enum EscapeRetractionSetting: String, CaseIterable, Identifiable {
    case polishedText
    case frozenSession

    var id: Self { self }

    var title: String {
        switch self {
        case .polishedText: return "Esc 一併退掉已潤飾文字"
        case .frozenSession: return "凍結後按 Esc 仍退字"
        }
    }

    var explanation: String {
        switch self {
        case .polishedText: return EscapeRetractionSettingsText.polishedExplanation
        case .frozenSession: return EscapeRetractionSettingsText.frozenExplanation
        }
    }

    func binding(to settings: AppSettings) -> Binding<Bool> {
        switch self {
        case .polishedText:
            return Binding(get: { settings.escapeRetractsPolishedText },
                           set: { settings.escapeRetractsPolishedText = $0 })
        case .frozenSession:
            return Binding(get: { settings.escapeRetractsFrozenSession },
                           set: { settings.escapeRetractsFrozenSession = $0 })
        }
    }
}

enum StreamingSettingsText {
    static let requiredSegmentsTradeoff =
        "累積出多個片段時，數值 1 通常會讓文字在說話中較快上屏，但只留一個尾端片段等待後文修正，錯字可能較早鎖進定稿。"
        + "數值愈高，保留的尾端片段愈多、較穩定，但短句更可能到結束時才集中上屏；"
        + "只切成一個片段的短句，設 1 或 2 都會等到結束。"
}
