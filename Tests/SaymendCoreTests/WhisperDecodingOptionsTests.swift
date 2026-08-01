import Foundation
import Testing
import WhisperKit
@testable import SaymendCore

/// **特殊 token 不得漏進使用者的文件。**
///
/// `DecodingOptions.skipSpecialTokens` 的套件預設是 false，`SegmentSeeker` 會據此
/// 直接解碼原始 token 串，於是 `segment.text` 長這樣：
/// `<|startoftranscript|><|zh|><|transcribe|><|0.00|>今天天氣不錯<|2.00|><|endoftext|>`
/// 而我們把 segment.text 直接當成辨識結果上屏——這串垃圾會被寫進使用者正在編輯的文件。
/// 實機 2026-07-28 真的發生了。
@Test func decodingSkipsSpecialTokens() {
    let o = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: nil,
                                                 options: WhisperStreamingOptions())
    #expect(o.skipSpecialTokens)
}

/// **prewarm 必須關閉。**
///
/// 套件的 prewarm 把每個模型載起來再丟掉，接著 `load: true` 再完整載一次——開著就是每次
/// 冷啟動做兩遍。實機 2026-07-28 量到 large-v3-turbo 關掉 prewarm 仍要 631 秒
/// （文字解碼器 104s ＋ 音訊編碼器 527s），開著約 20 分鐘，使用者會直接認定 App 當掉。
@Test func modelConfigDisablesPrewarm() {
    let c = WhisperKitModelActor.modelConfig(modelFolder: URL(filePath: "/m/large"))
    #expect(c.prewarm == false)
    #expect(c.load == true)        // 不 prewarm，但要真的載
}

/// 離線承諾：不得連網下載模型。這條寫在設定頁上給使用者看，破了就是對使用者說謊。
@Test func modelConfigNeverDownloads() {
    let c = WhisperKitModelActor.modelConfig(modelFolder: URL(filePath: "/m/large"))
    #expect(c.download == false)
    #expect(c.modelFolder == "/m/large")
}

/// 空語系＝交套件自行偵測，不得送出空字串當語系
@Test func emptyLanguageBecomesNil() {
    let auto = WhisperKitModelActor.decodingOptions(language: "", promptTokens: nil,
                                                    options: WhisperStreamingOptions())
    #expect(auto.language == nil)
    let zh = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: nil,
                                                  options: WhisperStreamingOptions())
    #expect(zh.language == "zh")
}

/// 詞彙表偏置要真的送進解碼參數，否則整條 ContextBiasable 是白接的
@Test func promptTokensReachDecodingOptions() {
    let o = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: [1, 2, 3],
                                                 options: WhisperStreamingOptions())
    #expect(o.promptTokens == [1, 2, 3])
    #expect(o.usePrefillPrompt)          // promptTokens 只有在 prefill 開啟時才會被用上
}

/// 設定頁調過的兩個解碼門檻必須覆蓋掉套件預設；沒調過（nil）則原樣保留套件預設
@Test func userThresholdsOverridePackageDefaults() {
    var opts = WhisperStreamingOptions()
    opts.logProbThreshold = -2.5
    opts.compressionRatioThreshold = 1.8
    let tuned = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: nil, options: opts)
    #expect(tuned.logProbThreshold == -2.5)
    #expect(tuned.compressionRatioThreshold == 1.8)

    let untouched = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: nil,
                                                         options: WhisperStreamingOptions())
    #expect(untouched.logProbThreshold == WhisperStreamingOptions.packageLogProbThreshold)
    #expect(untouched.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}
