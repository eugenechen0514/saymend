import Foundation
import SaymendCore

/// 設定頁「模型狀態」的文案組裝（issue #17）。
///
/// 抽成純函式**是為了測得到**：這些字串是使用者判斷「該再等，還是該重開 App」的唯一依據，
/// 而 SwiftUI 的 View body 測不到。組裝規則錯了不會有任何徵兆，只會讓使用者在錯的時候放棄。
enum ModelLoadStatusText {

    /// 示警倍數。**不是隨手訂的**：實測同一台 M4、同一顆 large-v3_turbo，冷載入量到
    /// 543s／631s／1297s——散佈本身就有 2.4 倍。門檻訂 2 倍會誤殺合法載入，而誤殺的代價
    /// （使用者認定模型壞了、從此不用離線引擎）比晚幾分鐘示警嚴重得多。
    ///
    /// 倍數的基準是「看過最久的一趟」而不是「最近一次」——見 `ModelLoadHistory`
    /// 型別說明裡那段實機發現（暖載入會污染冷載入的參照）。
    static let warnMultiplier: Double = 3

    /// 沒有歷史紀錄時的絕對地板。**這個數字是猜的**——目前量到的最大值是 1297 秒
    /// （21 分 37 秒），30 分鐘只是在它之上留一點餘裕，不是任何統計意義上的上界。
    /// 更慢的機器只會更久。有歷史之後就改用倍數，那才有依據。
    ///
    /// 2026-08-26 補充：large-v3_turbo 連續三趟（首次／卸載後／重啟 App 後）分別是
    /// 632.65s、693.96s、670.94s。ANE 快取在載入完成後數分鐘就被系統清除（見 #23），
    /// 所以**正常使用情境下每一次載入都是完整重編**。這讓 30 分鐘這個地板暫時仍然安全
    /// （最慢的一趟也才 11.6 分鐘），但它的理由已經不是「冷載入很罕見」，而是
    /// 「冷載入是常態，而 30 分鐘連常態的兩倍都還沒到」。
    /// 真正的保險是使用者載過一次之後就有歷史，屆時倍數規則接手。
    static let warnFloorWithoutHistory: TimeInterval = 30 * 60

    /// `m:ss`，滿一小時長出小時欄位。
    ///
    /// 需要小時欄位是因為實測有一次載到 1297 秒，而那不是上界；超過一小時完全可能，
    /// 屆時「77:12」讀起來會讓人以為是秒數。負值（時鐘被往回調）夾到 0。
    ///
    /// **不到一秒印 `<0:01` 而不是 `0:00`**：暖快取的 tokenizer 實測 0.42 秒，
    /// 印成「0:00」讀起來像是沒有資料或壞掉，而它其實是一個真實量到的值。
    static func elapsed(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped > 0, clamped < 1 { return "<0:01" }
        let total = Int(clamped)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 一個階段的一行。已完成 `✓`、正在載 `⟳`、還沒輪到 `·`。
    ///
    /// `progress` 為 nil＝沒有進度資料（套件升級改掉 log 字串時就會這樣）：
    /// 四個階段一律顯示成待辦，**不猜**哪一個正在載。
    static func stageLine(_ stage: ModelLoadStage,
                          progress: ModelLoadProgress?,
                          previous: CompletedLoad?,
                          now: Date) -> String {
        if let done = progress?.finished.first(where: { $0.stage == stage }) {
            guard let secs = done.seconds else { return "✓ \(stage.label)" }   // 耗時未知就不編一個
            return "✓ \(stage.label)　\(elapsed(secs))"
        }
        if progress?.currentStage == stage {
            let since = progress?.currentStageStartedAt ?? now
            var line = "⟳ \(stage.label)　\(elapsed(now.timeIntervalSince(since)))"
            // 沒有紀錄就不附參照。第一次載入顯示「（最久 0:00）」比不顯示更糟。
            // 標「最久」而不是「上次」是因為存的就是最大值（見 `ModelLoadHistory`）——
            // 標錯字等於對使用者謊報這個數字的意義。
            if let ref = previous?.stages[stage] { line += "（最久 \(elapsed(ref))）" }
            return line
        }
        return "· \(stage.label)"
    }

    /// 這一趟是不是已經久到該提醒使用者了。
    ///
    /// `previousTotal` 為 nil 或 0 時退回絕對地板——0 若拿去乘倍數會讓門檻塌成 0，
    /// 於是每一次載入從第一秒就在示警。
    static func shouldWarn(elapsed: TimeInterval, previousTotal: TimeInterval?) -> Bool {
        if let p = previousTotal, p > 0 { return elapsed > p * warnMultiplier }
        return elapsed > warnFloorWithoutHistory
    }

    /// 示警文案。
    ///
    /// **不得斷言它死了。** 我們分不出「合法地載了很久」與「已經卡死」——那正是 issue #17
    /// 的前提。能誠實說的只有兩件事：這次比上次久很多；以及卸載按鈕對它沒用。
    static func warning(previousTotal: TimeInterval?) -> String {
        let head: String
        if let p = previousTotal, p > 0 {
            head = "已超過最久那次的 \(Int(warnMultiplier)) 倍（最久 \(elapsed(p))）。"
        } else {
            head = "已載入超過 \(Int(warnFloorWithoutHistory / 60)) 分鐘（這台機器還沒有可比對的紀錄）。"
        }
        return head + "載入無法從 App 內中止（ANE 為同步呼叫，「卸載」對它沒有作用），"
             + "唯一的出口是重新啟動 App。"
    }
}
