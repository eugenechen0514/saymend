import Foundation
import SpeeckinkCore

/// 編輯器的可測 view-model。驗證一律委派 Core 的唯一 validator，
/// 只負責把 CoreModeStoreError 轉成使用者可讀訊息與 UI 狀態。
struct CoreModeDraft {
    var name: String
    var systemRules: String
    private var storeError: CoreModeStoreError?
    private var saved = false

    init(name: String, systemRules: String) {
        self.name = name
        self.systemRules = systemRules
    }

    /// 即時驗證（打字時跑）：委派 Core validator
    var validationError: CoreModeStoreError? {
        FileCoreModeStore.validateDraft(name: name, systemRules: systemRules)
    }

    var canSave: Bool { validationError == nil }

    /// 顯示優先序：即時驗證錯誤 > store 回報的持久化錯誤
    var errorMessage: String? {
        if let e = validationError { return Self.describe(e) }
        if let e = storeError { return Self.describe(e) }
        return nil
    }

    /// 只有真正存檔成功才關閉 sheet
    var shouldDismiss: Bool { saved }

    mutating func applyStoreError(_ e: CoreModeStoreError) {
        storeError = e
        saved = false
    }

    mutating func markSaved() {
        storeError = nil
        saved = true
    }

    static func describe(_ e: CoreModeStoreError) -> String {
        switch e {
        case .emptyName: return "請輸入模式名稱。"
        case .nameTooLong: return "模式名稱不可超過 80 個字元。"
        case .emptySystemRules: return "請輸入模式規則。"
        case .systemRulesTooLong: return "模式規則不可超過 8,000 個字元。"
        case .rewriteSemanticViolation: return "模式規則不可改寫 JSON、intent 或反注入機器契約。"
        case .forbiddenUnicode: return "模式規則含不可見或控制字元，請移除後再儲存。"
        case .contractMarkerCollision: return "模式規則不可包含保留的 machine contract marker。"
        case .builtinMutationForbidden: return "內建模式不可編輯或刪除。"
        case .duplicateID: return "模式 ID 重複。"
        case .modeNotFound: return "找不到該模式，可能已被刪除。"
        case .invalidID: return "模式 ID 格式不合法。"
        case .persistenceFailed: return "儲存失敗，請確認磁碟空間與權限後再試。"
        }
    }
}
