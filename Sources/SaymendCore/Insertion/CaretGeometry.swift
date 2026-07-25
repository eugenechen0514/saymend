import Foundation

/// 一段文字被替換後，游標應該落在哪裡（M10-C spec §3.2）。全部 UTF-16 單位。
///
/// 為什麼需要它：現行的 AX 範圍替換一律把游標收到「新文字的結尾」。那對它既有的唯一用途
/// 是正確的——被替換的那段就是整段文字的尾端，收在那裡剛好維持「游標永遠在尾端」的前提。
/// 但回收晚到的潤飾要替換的是**中段**的一句：後面還接著別的句子。沿用舊行為會把游標丟到
/// 後續文字之前，接下來每一個串流插入的字都會落在句子中間，直接毀掉使用者的文字。
///
/// 純函式、無副作用，故可在 Core 完整測試——真正的 AX 呼叫在 app target，測不到。
public func caretAfterReplacement(current: Int, location: Int, oldLength: Int, newLength: Int) -> Int {
    let rangeEnd = location + oldLength
    let target: Int
    if current >= rangeEnd {
        // 在被替換段落之後：整段跟著長度差平移。
        target = current + (newLength - oldLength)
    } else if current >= location {
        // 落在被替換段落之內：那段文字已經不存在，沒有「原位置」可回，只能收到新文字尾端。
        target = location + newLength
    } else {
        // 在被替換段落之前：替換不影響它前面的任何位置。
        target = current
    }
    // 單一夾制點：AX 在欄位被外力大幅改動時可能回報怪值（含負的 location），
    // 算出負的游標會讓設值失敗或跳到不可預期處。夾在最後一步，三個分支一體適用——
    // 只夾其中一支等於留下半套防護，讀者卻會以為負值已經處理掉了。
    return max(0, target)
}
