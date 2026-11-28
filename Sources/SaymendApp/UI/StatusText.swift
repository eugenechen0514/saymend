import SaymendCore

/// HUD 與選單列共用的狀態文字：同一個狀態只有一種說法，兩邊都從這裡取，不會各寫各的。
///
/// 用詞規則（與 saymend-voice mod 一致）：麥克風開著一律是「聽寫中」（「錄音」只留給講音訊本身的地方）；
/// 「說話」只指使用者，Mac 發聲是「朗讀」。內部術語（延續窗、排空、session）不出現在畫面上。
enum StatusText {
    static let idle = "待機"
    static func listening(locked: Bool) -> String { locked ? "聽寫中（鎖定）" : "聽寫中" }
    /// 選取文字當目標、聽寫的是改寫指令或替換內容
    static let selectionListening = "改寫選取中"
    /// 熱鍵聽寫結束後的 8 秒內：可以接著說，或按復原
    static let lingering = "可修正（8 秒內可續說／復原）"
    static let transcribing = "辨識中…"
    static let polishing = "潤飾中…"

    /// CLI 來源的前綴：本機是「CLI 」，遠端橋接發起的是「遠端 <主機> 」
    static func source(origin: String?) -> String { origin.map { "遠端 \($0) " } ?? "CLI " }

    /// HUD 上 CLI 來源聽寫的標籤
    static func cliListening(loadingModel: Bool, origin: String?) -> String {
        let who = source(origin: origin) + listening(locked: false)
        return loadingModel ? "\(who)（載入模型中…）｜Esc 取消" : "\(who)｜Esc 取消"
    }
}

/// 選單列第一行的狀態。CLI 聽寫進行中以它為準，否則看熱鍵聽寫。
enum MenuStatusText {
    struct Input: Equatable {
        var cliPhase: CLIDictationController.Phase = .idle
        var cliOrigin: String?
        var hotkeyPhase: DictationController.Phase = .idle
        var isLingering = false
        var isTargetingSelection = false
    }

    static func make(_ i: Input) -> String {
        let who = StatusText.source(origin: i.cliOrigin)
        switch i.cliPhase {
        case .recording: return who + StatusText.listening(locked: false)
        case .transcribing: return who + StatusText.transcribing
        case .polishing: return who + StatusText.polishing
        case .idle: break
        }
        switch i.hotkeyPhase {
        case .idle:
            return i.isLingering ? StatusText.lingering : StatusText.idle
        case .listening(let mode):
            return i.isTargetingSelection ? StatusText.selectionListening : StatusText.listening(locked: mode == .locked)
        }
    }
}
