import Foundation

public struct CoreModeResolver: Sendable {
    public init() {}

    /// 解析式：session > per-app > global > 內建預設（純聽寫整理）
    /// stale/unknown ID 視為該層未設定，繼續往下；所有候選皆無效時必回內建預設。
    public func resolve(
        sessionModeID: String?,
        appModeID: String?,
        defaultModeID: String?,
        availableModes: [CoreMode]
    ) -> CoreMode {
        let ids = Set(availableModes.map(\.id))
        if let id = sessionModeID, ids.contains(id),
           let m = availableModes.first(where: { $0.id == id }) { return m }
        if let id = appModeID, ids.contains(id),
           let m = availableModes.first(where: { $0.id == id }) { return m }
        if let id = defaultModeID, ids.contains(id),
           let m = availableModes.first(where: { $0.id == id }) { return m }
        return availableModes.first(where: { $0.id == PromptAssembler.builtinDefaultModeID })
            ?? PromptAssembler.pureDictationMode
    }
}
