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
