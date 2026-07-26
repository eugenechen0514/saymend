import Testing
@testable import SaymendCore

// 中段回溯改寫的游標歸位（M10-C #6）。全部 UTF-16 單位。
// 現行的整段替換一律把游標收到新文字尾端——那對「被替換的就是尾端」是對的，
// 但用在中段改寫會把游標丟到後續文字之前，接下來每個字都插進句子中間。

@Test func caretAfterTheReplacedRangeShiftsByLengthDelta() {
    // 被替換段落 [10, 10+5)，游標在 30。潤飾後長度 5→8，游標應往後 3。
    #expect(caretAfterReplacement(current: 30, location: 10, oldLength: 5, newLength: 8) == 33)
    // 縮短同理：5→2，游標往前 3
    #expect(caretAfterReplacement(current: 30, location: 10, oldLength: 5, newLength: 2) == 27)
    // 長度不變則不動
    #expect(caretAfterReplacement(current: 30, location: 10, oldLength: 5, newLength: 5) == 30)
}

@Test func caretExactlyAtRangeEndIsUnambiguous() {
    // 邊界：游標恰在被替換段落的結尾（15＝10+5）。
    // 這裡兩個分支代數上等價——「之後」給 current+(new-old)=15+3=18，
    // 「之內」給 location+new=10+8=18——所以這條只鎖「值」，鎖不了「走哪個分支」。
    // 誠實記著：把 `>=` 改成 `>` 這條不會紅，因為那個改動在這個點上不改變任何結果。
    #expect(caretAfterReplacement(current: 15, location: 10, oldLength: 5, newLength: 8) == 18)
    #expect(caretAfterReplacement(current: 15, location: 10, oldLength: 5, newLength: 2) == 12)
}

@Test func caretInsideTheReplacedRangeCollapsesToNewEnd() {
    // 那段文字已經不存在了，沒有「原位置」可回，只能收到新文字尾端 10+8=18
    #expect(caretAfterReplacement(current: 12, location: 10, oldLength: 5, newLength: 8) == 18)
    // 段落起點也算在內
    #expect(caretAfterReplacement(current: 10, location: 10, oldLength: 5, newLength: 8) == 18)
}

@Test func caretBeforeTheReplacedRangeDoesNotMove() {
    // 替換某段不影響它前面的任何位置
    #expect(caretAfterReplacement(current: 3, location: 10, oldLength: 5, newLength: 8) == 3)
    #expect(caretAfterReplacement(current: 9, location: 10, oldLength: 5, newLength: 2) == 9)
    #expect(caretAfterReplacement(current: 0, location: 10, oldLength: 5, newLength: 8) == 0)
}

@Test func caretNeverGoesNegative() {
    // 病態輸入（AX 在欄位被外力大幅改動時可能回怪值，含負的 location）不得算出負的游標——
    // 設回負值會讓 AX 呼叫失敗或跳到不可預期的位置。
    //
    // 三個分支各一個「沒有夾制就會回負數」的案例：不夾制的話依序得到 -50／-50／-10。
    // （原本寫的 location:10 案例其實走不到夾制、拿掉保護也不會紅——變異測試抓出來的。）
    #expect(caretAfterReplacement(current: 0, location: -50, oldLength: 100, newLength: 0) == 0)   // 之內分支
    #expect(caretAfterReplacement(current: -50, location: -10, oldLength: 0, newLength: 0) == 0)   // 之前分支
    #expect(caretAfterReplacement(current: -5, location: -10, oldLength: 5, newLength: 0) == 0)    // 之後分支
}
