import AVFoundation
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

/// CLI 聽寫的端點判斷（`--silence-ms`／`--no-speech-seconds`／`--max-seconds`）。
/// 位準以約 0.1 秒一個樣本餵入，與真實麥克風（4096 frames @ 44.1kHz ≈ 93ms）同級距。
@Suite struct EndpointDetectorTests {
    private static let quiet: Float = 0.01
    private static let loud: Float = 0.5

    /// 從 t0 起每 0.1 秒餵一個樣本，回傳最後一個樣本的時間
    @discardableResult
    private func feed(_ d: inout EndpointDetector, _ level: Float, from t0: Double, seconds: Double) -> Double {
        let steps = Int((seconds / 0.1).rounded())
        var last = t0
        for i in 0..<steps {
            last = t0 + Double(i) * 0.1
            d.ingestLevel(level, at: last)
        }
        return last
    }

    @Test func speechThenSilenceEndsAfterSilenceMs() {
        var d = EndpointDetector(startedAt: 0)
        let opts = DictateOptions(silenceMs: 1000)
        feed(&d, Self.quiet, from: 0, seconds: 0.5)                       // 先有環境音，底線就位
        let lastLoud = feed(&d, Self.loud, from: 0.5, seconds: 1.0)
        #expect(d.speechDetected)
        #expect(d.decision(at: lastLoud, options: opts) == .keepListening)
        feed(&d, Self.quiet, from: lastLoud + 0.1, seconds: 0.9)
        #expect(d.decision(at: lastLoud + 0.95, options: opts) == .keepListening, "靜音未滿 1 秒")
        #expect(d.decision(at: lastLoud + 1.05, options: opts) == .endOfSpeech)
    }

    @Test func aShortClickIsNotSpeech() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.quiet, from: 0, seconds: 0.5)
        d.ingestLevel(Self.loud, at: 0.5)          // 敲桌一下：單一樣本
        d.ingestLevel(Self.loud, at: 0.6)          // 0.1 秒 < 確認時間 0.25 秒
        feed(&d, Self.quiet, from: 0.7, seconds: 2)
        #expect(!d.speechDetected)
        #expect(d.decision(at: 2.7, options: DictateOptions(silenceMs: 500)) == .keepListening,
                "還沒開口就不會因為靜音而結束——等使用者開口")
    }

    @Test func silenceEndIsDisabledByDefault() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.quiet, from: 0, seconds: 0.5)
        let t = feed(&d, Self.loud, from: 0.5, seconds: 1)
        feed(&d, Self.quiet, from: t + 0.1, seconds: 30)
        #expect(d.decision(at: t + 30, options: DictateOptions()) == .keepListening)
    }

    @Test func noSpeechSecondsFiresOnlyWithoutSpeech() {
        var silent = EndpointDetector(startedAt: 10)
        feed(&silent, Self.quiet, from: 10, seconds: 5)
        let opts = DictateOptions(noSpeechSeconds: 4)
        #expect(silent.decision(at: 13.9, options: opts) == .keepListening)
        #expect(silent.decision(at: 14.0, options: opts) == .noSpeech)
        #expect(silent.decision(at: 14.0, options: DictateOptions()) == .keepListening, "0＝不啟用")

        var spoke = EndpointDetector(startedAt: 10)
        feed(&spoke, Self.quiet, from: 10, seconds: 0.5)
        feed(&spoke, Self.loud, from: 10.5, seconds: 1)
        #expect(spoke.decision(at: 20, options: opts) == .keepListening, "開過口就不算沒說話")
    }

    @Test func maxDurationWinsOverEverything() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.quiet, from: 0, seconds: 1)
        let opts = DictateOptions(maxSeconds: 5, silenceMs: 1000, noSpeechSeconds: 10)
        #expect(d.decision(at: 4.99, options: opts) == .keepListening)
        #expect(d.decision(at: 5.0, options: opts) == .maxDuration)
    }

    @Test func transcriptActivityCountsAsSpeechAndKeepsItAlive() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.quiet, from: 0, seconds: 3)           // 小聲到位準沒過門檻
        d.noteTranscriptActivity(at: 3)                     // 但辨識器聽出了字
        #expect(d.speechDetected)
        let opts = DictateOptions(silenceMs: 1000)
        #expect(d.decision(at: 3.9, options: opts) == .keepListening)
        d.noteTranscriptActivity(at: 3.9)
        #expect(d.decision(at: 4.8, options: opts) == .keepListening, "新的文字重置靜音計時")
        #expect(d.decision(at: 4.95, options: opts) == .endOfSpeech)
    }

    /// 持續的環境噪音（風扇、冷氣）在最低門檻之上：不得一開麥就算開口
    @Test func loudAmbientNoiseIsNotSpeech() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, 0.15, from: 0, seconds: 5)
        #expect(!d.speechDetected)
        #expect(d.threshold > 0.15)
        // 在噪音之上說話仍要聽得出來
        feed(&d, 0.6, from: 5, seconds: 1)
        #expect(d.speechDetected)
    }

    /// 一口氣講十秒（中間沒有停頓）：底線不得被自己的聲音抬上去、話沒講完就判成靜音
    @Test func longContinuousSpeechIsNotCutOff() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.quiet, from: 0, seconds: 0.5)
        let end = feed(&d, Self.loud, from: 0.5, seconds: 10)
        #expect(d.lastSpeechAt == end, "最後一個樣本仍在門檻之上")
        #expect(d.decision(at: end, options: DictateOptions(silenceMs: 800)) == .keepListening)
    }

    /// 一開麥就在講話（第一個樣本就是人聲）：第一個停頓之後要恢復正常判斷
    @Test func speakingFromTheFirstSampleRecoversAfterThePause() {
        var d = EndpointDetector(startedAt: 0)
        feed(&d, Self.loud, from: 0, seconds: 1)
        feed(&d, Self.quiet, from: 1, seconds: 0.3)          // 換氣
        feed(&d, Self.loud, from: 1.3, seconds: 1)
        #expect(d.speechDetected)
    }

    @Test func levelMeterMatchesTheHUDScale() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        let data = try #require(buffer.floatChannelData?[0])
        for i in 0..<1600 { data[i] = i.isMultiple(of: 2) ? 0.01 : -0.01 }   // RMS 0.01
        let level = try #require(AudioLevelMeter.level(of: buffer))
        #expect(abs(level - 0.2) < 0.0001, "min(1, rms × 20)")
        for i in 0..<1600 { data[i] = 0.5 }
        #expect(AudioLevelMeter.level(of: buffer) == 1, "上限 1")
        buffer.frameLength = 0
        #expect(AudioLevelMeter.level(of: buffer) == nil)
    }
}

@Suite struct TranscriptPostProcessorTests {
    @Test func replacesMishearingsWithThePhrase() {
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "OpenPets", mishearings: ["歐噴佩茲", "open pets"])],
                                        traditionalize: nil)
        #expect(p.apply("我在用歐噴佩茲") == "我在用OpenPets")
        #expect(p.apply("try Open Pets now") == "try OpenPets now", "英文不分大小寫")
    }

    @Test func latinMishearingsRequireWordBoundaries() {
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "AI", mishearings: ["ai"])], traditionalize: nil)
        #expect(p.apply("he said ai is fine") == "he said AI is fine", "said 裡的 ai 不得被換掉")
        #expect(p.apply("用ai寫") == "用AI寫", "中文與英文相鄰時中文不是字邊界")
    }

    @Test func longerMishearingsWinOverTheirPrefixes() {
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "甲", mishearings: ["歐噴"]),
                                                VocabEntry(phrase: "OpenPets", mishearings: ["歐噴佩茲"])],
                                        traditionalize: nil)
        #expect(p.apply("歐噴佩茲和歐噴") == "OpenPets和甲")
    }

    @Test func traditionalizesBeforeReplacing() {
        // 簡轉繁之後才比對：使用者用繁體登記的誤轉寫，要對得上 Whisper 吐出來的簡體
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "Saymend", mishearings: ["說們的"])],
                                        traditionalize: { $0.replacingOccurrences(of: "说们", with: "說們") })
        #expect(p.apply("说们的很好") == "Saymend很好")
    }

    @Test func ignoresEmptyAndSelfMishearings() {
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "Swift", mishearings: ["", "  ", "Swift", "swift"])],
                                        traditionalize: nil)
        #expect(p.apply("swift Swift code") == "Swift Swift code", "空白與等於詞彙本身的條目略過；只差大小寫的照換")
    }

    @Test func replacementTextIsLiteral() {
        let p = TranscriptPostProcessor(vocab: [VocabEntry(phrase: "$1 \\n", mishearings: ["錢"])], traditionalize: nil)
        #expect(p.apply("錢") == "$1 \\n", "詞彙不得被當成 regex 樣板")
    }

    @Test func realOpenCCConvertsSimplifiedForZhTW() throws {
        let guardian = try TraditionalizeGuard()
        let p = TranscriptPostProcessor(vocab: [], traditionalize: { guardian.apply($0, language: .zhTW) })
        #expect(p.apply("软件") == "軟體")
    }
}
