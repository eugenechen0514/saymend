import Foundation

/// 串流定稿的**邊界重複**（issue #19）。
///
/// 套件的串流轉錄器每一趟都從已定稿片段的結束時間戳重解（`clipTimestamps`）。Whisper 片段的
/// 文字常常比它的結束時間戳多出幾個字，下一趟從那個時間戳起解，就會把那幾個字再解一次，
/// 接在已定稿的文字後面：「今天天氣不錯」＋「不錯我想出去走走」。
///
/// **不能只看文字就去重。**「菜色不錯。不錯的地方是…」這種合法的重複，在邊界上長得一模一樣；
/// 合成語音量測裡，無腦去重每救一個重複要誤殺十幾個合法的重複（ADR 0002）。
///
/// 判斷靠一個**證人**：讓邊界前進的那一趟留下的暫時文字。那一趟解碼時看得到邊界之前的音訊，
/// 它的暫時文字就從邊界開始。若它認為邊界之後的第一個字**不是**重疊的那個字，那段音訊在它看來
/// 屬於已定稿的片段，新一趟從邊界重解出來的那幾個字就是重複，裁掉。
///
/// 證人缺席、或證人也以同一個字開頭時，**一律不裁**：寧可留著重複，也不要吃掉使用者說的話
/// （與 `WhisperKitEngine.newlyConfirmed`「寧可重覆不要漏字」同一取捨）。代價是證人自己也重解了
/// 那幾個字的時候會漏抓，量測裡 4 次漏 1 次。
enum StreamBoundaryOverlap {
    /// 最多比對幾個字。量測到的重複最長 6 字。
    static let maxOverlap = 8

    struct Outcome: Equatable {
        /// 要送出的文字（沒裁就是原文）
        let text: String
        /// 與已送出文字尾端重疊的字數（不含標點與空白）；0＝沒有重疊
        let overlap: Int
        /// 是否裁掉了重疊的部分
        let trimmed: Bool
    }

    /// `next` 去掉與 `emitted` 尾端重疊、且證人不支持的開頭。
    ///
    /// 比對時略過標點與空白、繁簡視為同一字（小模型會簡繁混用），裁的時候裁原文：
    /// 重疊最後一個字之後的內容原樣保留；只有已送出的文字本來就以標點收尾時，才去掉緊接的標點。
    static func resolve(_ next: String, after emitted: String, witness: String?) -> Outcome {
        let head = units(of: next, limit: maxOverlap, fromEnd: false)
        let tail = units(of: emitted, limit: maxOverlap, fromEnd: true)
        let k = overlap(tail: tail.map(\.key), head: head.map(\.key))
        guard k > 0 else { return Outcome(text: next, overlap: 0, trimmed: false) }
        guard let first = witness.flatMap({ units(of: $0, limit: 1, fromEnd: false).first }),
              first.key != head[0].key else {
            return Outcome(text: next, overlap: k, trimmed: false)
        }
        var rest = next[next.index(after: head[k - 1].index)...]
        // 已送出的文字以標點收尾時，剩下的開頭標點會疊成「不錯。，我想」，一併去掉
        if let last = emitted.last(where: { !$0.isWhitespace }), isIgnorable(last) {
            rest = rest.drop(while: isIgnorable)
        }
        return Outcome(text: String(rest), overlap: k, trimmed: true)
    }

    private struct Unit {
        let key: String
        let index: String.Index
    }

    /// 從開頭（或結尾）取最多 `limit` 個有意義的字。結尾取的結果仍是原文順序。
    private static func units(of s: String, limit: Int, fromEnd: Bool) -> [Unit] {
        var out: [Unit] = []
        var i = fromEnd ? s.endIndex : s.startIndex
        while out.count < limit {
            if fromEnd {
                guard i > s.startIndex else { break }
                i = s.index(before: i)
            } else {
                guard i < s.endIndex else { break }
            }
            let ch = s[i]
            if !isIgnorable(ch) { out.append(Unit(key: fold(ch), index: i)) }
            if !fromEnd { i = s.index(after: i) }
        }
        return fromEnd ? out.reversed() : out
    }

    private static func overlap(tail: [String], head: [String]) -> Int {
        for k in stride(from: min(tail.count, head.count), through: 1, by: -1)
        where Array(tail.suffix(k)) == Array(head.prefix(k)) {
            return k
        }
        return 0
    }

    private static let ignorable = CharacterSet.punctuationCharacters
        .union(.symbols).union(.whitespacesAndNewlines)

    private static func isIgnorable(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { ignorable.contains($0) }
    }

    private static func fold(_ ch: Character) -> String {
        let s = String(ch)
        return (s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s).lowercased()
    }
}
