import Foundation

/// 選單列核心模式子選單的決策模型（規格 §4.3）。純值型別、無 AppKit/SwiftUI 依賴 → 可單元測試。
/// View 只負責把本 model 的決策畫出來，不自行判斷誰打勾或何時停用。
public struct CoreModeMenuModel: Equatable, Sendable {
    public let allModes: [CoreMode]
    /// 已解析的有效模式 ID（呼叫端須傳入 resolver 的結果，不可傳 raw setting）
    public let activeModeID: String
    /// 無 frontmost bundle ID 時，per-app 綁定子選單必須停用
    public let canBindFrontApp: Bool

    public init(allModes: [CoreMode], active: CoreMode, frontAppBundleID: String?) {
        self.allModes = allModes
        self.activeModeID = active.id
        self.canBindFrontApp = frontAppBundleID != nil
    }

    public func isChecked(_ mode: CoreMode) -> Bool { mode.id == activeModeID }
}
