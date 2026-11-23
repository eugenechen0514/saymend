import Testing
@testable import SaymendCore

/// issue #19：串流定稿的邊界重複。證人不支持才裁，其餘一律原樣保留。
@Suite struct StreamBoundaryOverlapTests {
    private func resolve(_ next: String, after emitted: String, witness: String?) -> StreamBoundaryOverlap.Outcome {
        StreamBoundaryOverlap.resolve(next, after: emitted, witness: witness)
    }

    // MARK: - 裁掉的情況

    /// issue #19 的原始案例：讓邊界前進的那一趟認為邊界之後是「我想」，新一趟卻從「不錯」開始
    @Test func aRedecodedOverlapIsTrimmedWhenTheWitnessDisagrees() {
        let o = resolve("不錯我想出去走走", after: "今天天氣不錯", witness: "我想")
        #expect(o == .init(text: "我想出去走走", overlap: 2, trimmed: true))
    }

    /// 量測到的最長重複（small，6 字）
    @Test func aLongOverlapIsTrimmedAsAWhole() {
        let o = resolve("速切換的時候游標的位置會跑掉", after: "當使用者在輸入框裡快速切換的時候",
                        witness: "游標的位置")
        #expect(o.text == "游標的位置會跑掉")
        #expect(o.overlap == 6)
    }

    /// 重疊有長有短時取最長的：「好」與「好好」都對得上，重解出來的是「好好」
    @Test func theLongestOverlapWins() {
        let o = resolve("好好的", after: "他說好好", witness: "的")
        #expect(o == .init(text: "的", overlap: 2, trimmed: true))
    }

    /// 整段都是重解出來的：裁完什麼都不剩
    @Test func anEntirelyRedecodedPieceBecomesEmpty() {
        let o = resolve("好的", after: "他說好好的", witness: "那我們")
        #expect(o == .init(text: "", overlap: 2, trimmed: true))
    }

    /// 小模型會簡繁混用；比對時視為同一字，裁的時候裁原文
    @Test func traditionalAndSimplifiedAreTheSameCharacter() {
        let o = resolve("不错我想", after: "今天天氣不錯", witness: "我想")
        #expect(o.text == "我想")
    }

    /// 標點與空白不參與比對，邊界兩側的標點不會擋住重疊的判斷
    @Test func punctuationDoesNotHideAnOverlap() {
        let o = resolve("不錯，我想", after: "今天天氣不錯", witness: "我想")
        #expect(o.text == "，我想")
        #expect(o.overlap == 2)
    }

    /// 已送出的文字已經以標點收尾：剩下開頭的標點要一併去掉，否則會疊成「不錯。，我想」
    @Test func aLeadingPunctuationIsDroppedWhenTheEmittedTextAlreadyEndsWithOne() {
        let o = resolve("不錯，我想", after: "今天天氣不錯。", witness: "我想")
        #expect(o.text == "我想")
    }

    // MARK: - 保留的情況（合法的重複不得被吃掉）

    /// 合法的跨句重複：讓邊界前進的那一趟也聽到邊界之後是「不錯」
    @Test func aRepeatAcrossTheBoundaryIsKeptWhenTheWitnessHeardItToo() {
        let o = resolve("不錯的地方是價格也很合理", after: "這家餐廳的菜色不錯。", witness: "不錯的地方")
        #expect(o == .init(text: "不錯的地方是價格也很合理", overlap: 2, trimmed: false))
    }

    @Test(arguments: [
        ("這個方案不錯", "不錯，比上一版好很多", "不錯，比上一版"),
        ("他說好", "好好，我知道了", "好好"),
        ("你說得對", "對對，就是這樣", "對對對"),
    ])
    func spokenRepeatsAcrossTheBoundaryAreKept(emitted: String, next: String, witness: String) {
        let o = resolve(next, after: emitted, witness: witness)
        #expect(o.text == next)
        #expect(!o.trimmed)
    }

    /// 證人只對上第一個字也保留：小模型把「不錯」聽成「不不錯」時，仍算它聽到了
    @Test func aWitnessMatchingOnlyTheFirstCharacterStillKeeps() {
        let o = resolve("不錯這地方是", after: "菜色不不錯", witness: "不不錯")
        #expect(!o.trimmed)
    }

    /// 沒有證人就沒有證據，一律保留：寧可留著重複，也不要吃掉使用者說的話
    @Test(arguments: [nil, "", "，。 "] as [String?])
    func withoutAWitnessNothingIsTrimmed(witness: String?) {
        let o = resolve("不錯我想", after: "今天天氣不錯", witness: witness)
        #expect(o == .init(text: "不錯我想", overlap: 2, trimmed: false))
    }

    /// 同一段裡的疊字跟邊界無關，原樣保留
    @Test(arguments: ["好好好，我知道了", "對對對，就是這樣", "這個方案不錯不錯"])
    func repeatsInsideOnePieceAreNeverTouched(next: String) {
        let o = resolve(next, after: "我跟他說", witness: "隨便")
        #expect(o == .init(text: next, overlap: 0, trimmed: false))
    }

    @Test func nothingToCompareAgainstAtTheStart() {
        let o = resolve("今天天氣不錯", after: "", witness: "我想")
        #expect(o == .init(text: "今天天氣不錯", overlap: 0, trimmed: false))
    }
}
