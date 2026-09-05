import SwiftUI
import SaymendCore

/// Esc 退字兩個設定的使用者可見說明（issue #46）。抽離 `SettingsView` 是為了讓文案可直接測試——
/// 預設值與風險要一起說清楚，否則文案與實際行為日後會分岔。
enum EscapeRetractionSettingsText {
    static let polishedExplanation =
        "預設開啟：聽寫中按 Esc 會退掉本次上屏的全部文字，包含已潤飾的部分。"
        + "關閉時只退掉尚未潤飾的原始轉錄，保留已潤飾落定的文字。"
        + "無法確認原欄位時一律不動文字、只提示。"
    static let frozenExplanation =
        "預設關閉：你手動編輯過（已凍結）後，Esc 只結束聽寫、不動欄位。"
        + "開啟後 Esc 仍會退掉本次聽寫寫入的範圍；你在其後手打的文字保留，打進範圍內則不退、只提示。"
}

/// 兩個 Toggle 的 label、說明與 persistence Binding 同源：SettingsView 只依此表產生控件，
/// 不存在兩條 type-correct 的 `onChange` 可以接反；測試直接驅動相同的 Binding。
enum EscapeRetractionSetting: CaseIterable {
    case polishedText
    case frozenSession

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

    /// AppSettings 非 ObservableObject：Binding 直接讀寫 settings，不經 @State 快照。
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
