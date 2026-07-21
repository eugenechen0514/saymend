/// UTF-16 絕對範圍（AX 慣例；Task 9 的 FeedbackUpdate 與 overlay 高亮共用）
public struct SpanUTF16: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum DiffOp: Equatable, Sendable {
    case kept(String)
    case deleted(String)
    case added(String)
}

/// 一處異動的呈現窗口：kept 已裁剪至 context 字並帶省略號（規格 §3.5 HUD diff 降級）
public struct DiffWindow: Equatable, Sendable {
    public var ops: [DiffOp]
    public init(ops: [DiffOp]) { self.ops = ops }
}

/// 純文字差異（規格 §3.5）：刪除帶刪除線、新增帶底線、只顯示異動前後各約 15 字。
/// grapheme 級 LCS；超過上限（600×600）不做 LCS，退化為整段刪＋整段加。
public enum InlineDiff {
    static let lcsCap = 600

    /// 完整 op 序列（相鄰同類已合併）。超限回 [deleted(old), added(new)]。
    static func ops(old: String, new: String, cap: Int = InlineDiff.lcsCap) -> [DiffOp] {
        if old == new { return old.isEmpty ? [] : [.kept(old)] }
        let a = Array(old), b = Array(new)
        guard a.count <= cap, b.count <= cap else {
            var out: [DiffOp] = []
            if !old.isEmpty { out.append(.deleted(old)) }
            if !new.isEmpty { out.append(.added(new)) }
            return out
        }
        // 經典 LCS DP（(a.count+1)×(b.count+1)），回溯產生 op 串
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var raw: [DiffOp] = []
        var i = 0, j = 0
        var kept = "", del = "", add = ""
        func flushChange() {
            if !del.isEmpty { raw.append(.deleted(del)); del = "" }
            if !add.isEmpty { raw.append(.added(add)); add = "" }
        }
        func flushKept() {
            if !kept.isEmpty { raw.append(.kept(kept)); kept = "" }
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flushChange()
                kept.append(a[i]); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                flushKept()
                del.append(a[i]); i += 1
            } else {
                flushKept()
                add.append(b[j]); j += 1
            }
        }
        flushKept()
        while i < a.count { del.append(a[i]); i += 1 }
        while j < b.count { add.append(b[j]); j += 1 }
        flushChange()
        return raw
    }

    /// 異動窗口：兩處異動間的 kept 若長於 2×context 就拆窗；窗口頭尾 kept 裁到 context 字＋省略號。
    public static func windows(old: String, new: String, context: Int = 15) -> [DiffWindow] {
        let sequence = ops(old: old, new: new)
        guard sequence.contains(where: { if case .kept = $0 { return false }; return true }) else { return [] }

        var result: [DiffWindow] = []
        var current: [DiffOp] = []
        for op in sequence {
            switch op {
            case .kept(let text):
                let chars = Array(text)
                if current.isEmpty {
                    // 窗口未開：只留尾部 context 作前導
                    if chars.count > context {
                        current = [.kept("…" + String(chars.suffix(context)))]
                    } else {
                        current = [.kept(text)]
                    }
                } else if chars.count > context * 2 {
                    // 足夠長的 kept＝異動群的分界：收掉現窗、以尾部開新窗
                    current.append(.kept(String(chars.prefix(context)) + "…"))
                    result.append(DiffWindow(ops: current))
                    current = [.kept("…" + String(chars.suffix(context)))]
                } else {
                    current.append(.kept(text))
                }
            case .deleted, .added:
                current.append(op)
            }
        }
        // 收尾：window 未含任何異動就不算窗口（純前導）
        if current.contains(where: { if case .kept = $0 { return false }; return true }) {
            // 尾端 kept 裁剪
            if case .kept(let tail) = current[current.count - 1] {
                let chars = Array(tail)
                if chars.count > context {
                    current[current.count - 1] = .kept(String(chars.prefix(context)) + "…")
                }
            }
            result.append(DiffWindow(ops: current))
        }
        return result
    }

    /// 相對 new 全文的異動 UTF-16 範圍（overlay 高亮用）：共同前綴／後綴法。
    /// 無異動回 nil；純刪除回 length 0（呼叫端只畫底線不畫高亮）。
    public static func changedSpanUTF16(old: String, new: String) -> SpanUTF16? {
        guard old != new else { return nil }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let location = String(b[0..<prefix]).utf16.count
        let length = String(b[prefix..<(b.count - suffix)]).utf16.count
        return SpanUTF16(location: location, length: length)
    }
}
