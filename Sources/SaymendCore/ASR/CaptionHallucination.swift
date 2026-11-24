import Foundation

/// Whisper 在沒有人聲時解出來的字幕罐頭語（issue #10，見 ADR 0004）。
///
/// Whisper 的訓練資料含大量影片字幕，片尾的製作名單、頻道結尾語對應的往往是沒有人聲的片段。
/// 於是靜音、或喇叭放出來的影片聲，會被解成這些句子。本機實際出現過的兩句：
/// 「(字幕製作:貝爾)」（2026-07-26 一次 8 列、2026-08-19 又一次）與
/// 「请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」（2026-08-02，含 VAD 的串流版）。
///
/// **只做整句比對**：定稿文字整句就是罐頭語才算。真實語句裡提到這些字（「字幕製作很辛苦」
/// 「今天就到這裡，謝謝觀看」）不受影響；代價是罐頭語和真實語句併在同一段定稿裡時抓不到。
///
/// **為什麼不用對數機率門檻**：WhisperKit 的 `logProbThreshold` 沒過時只會換更高的溫度重解，
/// 最後一次的結果照樣輸出（`TranscribeTask.decodeWithFallback`），擋不住任何東西；
/// 自己依分數丟棄又沒有足夠的樣本訂門檻。
///
/// 只給 Whisper 家族的引擎用：系統內建引擎辨識出同樣的字，就是使用者真的說了。
public enum CaptionHallucination {

    /// 整句比對的罐頭語。寫成哪種字形都可以——比對前兩邊都經過 `folded`（繁轉簡、去標點空白、小寫）。
    static let phrases: [String] = [
        // 本機實際出現過
        "請不吝點讚 訂閱 轉發 打賞支持明鏡與點點欄目",
        // 同一類（片尾結語、字幕志工名單），本機尚未觀察到
        "明鏡需要您的支持 歡迎訂閱明鏡",
        "字幕由Amara.org社區提供",
        "小編字幕由Amara.org社區提供",
        "Subtitles by the Amara.org community",
        "謝謝觀看",
        "感謝觀看",
        "Thanks for watching",
        "Thank you for watching",
        "ご視聴ありがとうございました",
    ]

    private static let foldedPhrases: Set<String> = Set(phrases.map(folded))

    /// 製作名單：「(字幕製作:貝爾)」「字幕by索兰娅」。名字是任意的，只能比形狀。
    ///
    /// 形狀刻意收得很窄，**必須有分隔符**：角色詞（製作／翻譯／校對／提供）後接冒號或 by，
    /// 或「字幕」直接接 by。所以「字幕製作很辛苦」「字幕：這段要改一下」都不算——
    /// 前者沒有分隔符，後者只有「字幕」加冒號，那是使用者說話時很可能出現的形狀。
    /// 名字最多 12 個字，不含空白與句讀。比對的是繁轉簡之後的文字，角色詞寫簡體即可。
    nonisolated(unsafe) private static let creditLine =
        #/^[(（\[【]?\s*字幕(?:(?:制作|翻译|校对|提供)人?\s*(?:[:：]|by)|\s*by)\s*[^\s，。！？、,.!?()（）\[\]【】:：]{1,12}\s*[)）\]】]?$/#
            .ignoresCase()

    /// 整句是不是字幕罐頭語。
    public static func matches(_ text: String) -> Bool {
        let simplified = simplifiedChinese(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if simplified.wholeMatch(of: creditLine) != nil { return true }
        return foldedPhrases.contains(folded(text))
    }

    /// 比對用的正規形：繁轉簡、小寫、只留字母與數字（含中日文字與假名）。
    /// 空白與標點全部去掉——Whisper 對同一句罐頭語的斷句與標點每次都不一樣
    /// （實機那句就是用空白分隔的）。
    static func folded(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in simplifiedChinese(text).lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// 繁轉簡是多對一（製／制 → 制），所以兩邊都轉成簡體才比得起來；反方向一對多，轉了反而對不上。
    private static func simplifiedChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
}

public extension TranscriptEvent {
    /// Whisper 家族引擎的定稿出口（issue #10）：整句是字幕罐頭語就改送 `.captionHallucination`，
    /// 否則照常是 `.finalized`。三個出口（本機串流定稿、本機收尾補發、遠端）都經過這裡，
    /// 比對規則只有一份。
    static func whisperFinalized(_ text: String, quality: TranscriptQuality?) -> TranscriptEvent {
        CaptionHallucination.matches(text)
            ? .captionHallucination(text, quality: quality)
            : .finalized(text, quality: quality)
    }
}
