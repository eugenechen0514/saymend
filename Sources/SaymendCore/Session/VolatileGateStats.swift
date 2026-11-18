import Foundation

/// issue #65 Step 0 量測：暫時文字閘門的頻率與耗時（計畫 §4.5、Eugene 裁定 Q7）。
///
/// **型別上就放不進文字**：欄位只有 `Int`／`Double`／`Bool`／`TimeInterval?`。暫時文字可能正是焦點在
/// 密碼欄期間說出的字（#10），量測要的是「每秒幾則 × 每則多久」，句子內容對這個目的沒有任何貢獻。
/// 日後要加欄位，`VolatileGateStatsTests` 會用 reflection 擋下任何非數字型別。
///
/// 決策規則（Q7）：實測「事件/秒 p95 × 閘門耗時 p95 > 20ms/s」才開節流 follow-up。
/// 本結構只記一段（自 `startListening` 起到 `endListening`／`archiveSession`）的最大值；
/// p95 由多段 log 彙整得出。
struct VolatileGateStats: Equatable {
    /// 本段在 `.listening` 相位抵達的暫時文字數。含空字串與遮罩後的——它們代表閘門「本來要面對」的頻率。
    private(set) var events = 0
    /// 實際呼叫閘門的次數（空字串、已遮罩、沒有 reader 都不呼叫）
    private(set) var gateCalls = 0
    /// 任一個整秒桶內的最大事件數（以事件時間 `t` 的整數秒分桶）
    private(set) var maxPerSecond = 0
    /// 單次閘門呼叫的最大耗時（秒）
    private(set) var maxGateSeconds: Double = 0
    /// 本段是否遮罩過
    private(set) var masked = false
    /// 本段是否因暫時文字查到 `.secure` 而硬停
    private(set) var aborted = false
    /// 第一則／最後一則事件的時間（`handleTranscript(_:at:)` 的 `t`，呼叫端的時鐘）
    private(set) var firstAt: TimeInterval?
    private(set) var lastAt: TimeInterval?
    private var bucketSecond: Int?
    private var bucketCount = 0

    mutating func recordEvent(at t: TimeInterval) {
        events += 1
        if firstAt == nil { firstAt = t }
        lastAt = t
        guard t.isFinite else { return }            // 防禦：非有限值轉 Int 會 trap
        let second = Int(t.rounded(.down))
        if second == bucketSecond {
            bucketCount += 1
        } else {
            bucketSecond = second
            bucketCount = 1
        }
        maxPerSecond = max(maxPerSecond, bucketCount)
    }

    mutating func recordGateCall(_ elapsed: Duration) {
        gateCalls += 1
        maxGateSeconds = max(maxGateSeconds, Self.seconds(elapsed))
    }

    mutating func noteMasked() { masked = true }
    mutating func noteAborted() { aborted = true }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
