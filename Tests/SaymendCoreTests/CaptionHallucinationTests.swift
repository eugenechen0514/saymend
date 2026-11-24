import Foundation
import Testing
@testable import SaymendCore

/// 字幕罐頭語（issue #10，ADR 0004）：Whisper 在沒有人聲時解出來的「(字幕製作:貝爾)」這類句子。
///
/// 兩件事要同時守住：抓得到本機實際出現過的那幾句（不分繁簡、標點、空白），
/// 而真實語句只是**提到**這些字時一個都不能誤殺——誤殺就是使用者的話不見了。
@Suite struct CaptionHallucinationMatcherTests {

    // MARK: - 抓得到

    /// 本機實際出現過的兩句，原樣照抄（含實機那句用空白分隔的寫法）
    @Test func thePhrasesSeenOnThisMachineMatch() {
        #expect(CaptionHallucination.matches("(字幕製作:貝爾)"))
        #expect(CaptionHallucination.matches("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"))
    }

    /// Whisper 對同一句時而出繁體、時而出簡體，比對前兩邊都轉成簡體
    @Test func traditionalAndSimplifiedFormsBothMatch() {
        #expect(CaptionHallucination.matches("請不吝點讚 訂閱 轉發 打賞支持明鏡與點點欄目"))
        #expect(CaptionHallucination.matches("（字幕制作：贝尔）"))
        #expect(CaptionHallucination.matches("谢谢观看"))
    }

    /// 斷句、標點、大小寫每次都不一樣
    @Test func punctuationSpacingAndCaseDoNotMatter() {
        #expect(CaptionHallucination.matches("請不吝點讚，訂閱，轉發，打賞支持明鏡與點點欄目。"))
        #expect(CaptionHallucination.matches("謝謝觀看！"))
        #expect(CaptionHallucination.matches(" Thanks for watching! "))
        #expect(CaptionHallucination.matches("THANK YOU FOR WATCHING."))
    }

    /// 製作名單的名字是任意的，比的是形狀
    @Test func creditLinesMatchWhateverTheName() {
        #expect(CaptionHallucination.matches("字幕by索兰娅"))
        #expect(CaptionHallucination.matches("字幕 BY 索兰娅"))
        #expect(CaptionHallucination.matches("【字幕翻譯：小明】"))
        #expect(CaptionHallucination.matches("字幕製作人:貝爾"))
        #expect(CaptionHallucination.matches("[字幕校對: Bob]"))
    }

    /// WhisperKit 的片段文字常以空白開頭；引擎出口多半已去過頭尾空白，但比對本身不能依賴這一點
    @Test func aCreditLineWithSurroundingWhitespaceMatches() {
        #expect(CaptionHallucination.matches(" (字幕製作:貝爾) "))
        #expect(CaptionHallucination.matches("\n字幕by索兰娅\n"))
    }

    /// 清單裡每一句都要抓得到自己：正規化若把某句折成空字串或折錯，那句就形同不存在
    @Test func everyListedPhraseMatchesItself() {
        for phrase in CaptionHallucination.phrases {
            #expect(!CaptionHallucination.folded(phrase).isEmpty, "\(phrase) 被折成空字串")
            #expect(CaptionHallucination.matches(phrase), "\(phrase) 抓不到自己")
        }
    }

    // MARK: - 不誤殺

    /// 整句比對：真實語句裡提到這些字不算
    @Test func realSentencesThatMentionThePhrasesDoNotMatch() {
        #expect(!CaptionHallucination.matches("今天的影片就到這裡，謝謝觀看"))
        #expect(!CaptionHallucination.matches("感謝觀看的朋友們"))
        #expect(!CaptionHallucination.matches("請大家點讚訂閱"))
    }

    /// 製作名單一定要有分隔符，且「字幕」本身加冒號不算——使用者說話時很可能出現那種形狀
    @Test func creditShapedSpeechWithoutTheRoleAndSeparatorDoesNotMatch() {
        #expect(!CaptionHallucination.matches("字幕製作很辛苦"))
        #expect(!CaptionHallucination.matches("字幕：這段要改一下"))
        #expect(!CaptionHallucination.matches("這段字幕製作:貝爾"))
    }

    /// 名字最多 12 個字：再長就是一句話，不是名單
    @Test func aCreditLineWithASentenceForANameDoesNotMatch() {
        #expect(CaptionHallucination.matches("字幕製作:一二三四五六七八九十甲乙"))      // 12 個字
        #expect(!CaptionHallucination.matches("字幕製作:一二三四五六七八九十甲乙丙"))    // 13 個字
        #expect(!CaptionHallucination.matches("字幕製作：這段要改一下，還有下一段"))
    }

    /// Whisper 在靜音時也常吐「謝謝」「Thank you.」，但那是使用者每天都會說的話，不收
    @Test func everydayPhrasesAreNotOnTheList() {
        #expect(!CaptionHallucination.matches("謝謝"))
        #expect(!CaptionHallucination.matches("Thank you."))
        #expect(!CaptionHallucination.matches("謝謝大家"))
    }

    @Test func emptyOrPunctuationOnlyTextDoesNotMatch() {
        #expect(!CaptionHallucination.matches(""))
        #expect(!CaptionHallucination.matches("   "))
        #expect(!CaptionHallucination.matches("。。。"))
        #expect(!CaptionHallucination.matches("()"))
    }

    // MARK: - 引擎出口

    /// 引擎共用的出口：罐頭語改走另一個事件，品質資料一併帶過去（被抓到的幻覺的分數正是日後要的樣本）
    @Test func theWhisperExitRoutesCaptionsAwayFromFinalized() {
        let q = TranscriptQuality(minAvgLogprob: -0.875, maxCompressionRatio: 1.0, segmentCount: 1)
        #expect(TranscriptEvent.whisperFinalized("(字幕製作:貝爾)", quality: q)
                == .captionHallucination("(字幕製作:貝爾)", quality: q))
        #expect(TranscriptEvent.whisperFinalized("今天天氣不錯", quality: q)
                == .finalized("今天天氣不錯", quality: q))
    }
}

/// 控制器怎麼處理 `.captionHallucination`：不上屏、不送潤飾、留紀錄、收尾提示。
@MainActor
@Suite struct CaptionHallucinationControllerTests {
    private let caption = TranscriptEvent.captionHallucination("(字幕製作:貝爾)", quality: nil)

    /// 整段只有罐頭語：一個字都不上屏、不送潤飾；沒有東西可修正，提示取代延續窗
    @Test func aSessionWithOnlyACaptionInsertsNothingAndEndsWithTheNotice() async {
        let (c, _, _, key, polisher, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(caption, at: 11.0)
        c.hotkeyReleased(at: 12.0)
        c.asrStreamEnded(at: 12.1)
        await c.lastIntentTask?.value

        #expect(key.ops.isEmpty)
        #expect(polisher.calls.isEmpty, "罐頭語被送去潤飾了")
        #expect(hud.states.last == .notice(DictationController.captionHallucinationNotice))
        #expect(!hud.states.contains(.lingering), "沒有東西可修正，不該進延續窗")
        #expect(c.phase == .idle)
    }

    /// 誤殺時使用者要查得到那句話去了哪裡；被抓到的幻覺的分數也要留下來
    @Test func theCaptionIsRecordedInHistoryWithItsQuality() throws {
        let history = FakeHistory()
        let (c, _, _, _, _, _) = makeController(history: history)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.captionHallucination("(字幕製作:貝爾)",
                                                 quality: .init(minAvgLogprob: -0.875,
                                                                maxCompressionRatio: 1.0,
                                                                segmentCount: 1)),
                           at: 11.0)

        let row = try #require(history.exchanges.first)
        #expect(history.exchanges.count == 1)
        #expect(row.outcomeKind == "insertSkipped")
        #expect(row.outcomeText == "captionHallucination")
        #expect(row.utteranceRaw == "(字幕製作:貝爾)")
        let d = try #require(history.diagnostics.first)
        #expect(d.finalizedText == "(字幕製作:貝爾)")
        #expect(d.minAvgLogprob == -0.875)
    }

    /// 背景影片一直在播時，罐頭語不得重置斷句器的靜音計時（同 #18 示警事件的判別法）：
    /// 先前的定稿要照時閉合，送去潤飾的也只有真的文字。
    @Test func aCaptionDoesNotFeedTheSegmenter() async {
        let (c, _, _, _, polisher, _) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("今天天氣不錯"), at: 10.5)
        // quietGap 1.5 秒：沒重置 → 12.0 距 10.5 剛好 1.5 秒，話語閉合；被重置 → 只差 0.1 秒，不閉合
        c.handleTranscript(caption, at: 11.9)
        c.tick(at: 12.0)
        #expect(c.pendingIntents == 1, "罐頭語重置了斷句器的靜音計時——話語沒有閉合")
        await c.lastIntentTask?.value
        #expect(polisher.calls.map(\.raw) == ["今天天氣不錯"])
    }

    /// 有真的文字時照常進延續窗，提示疊在上面——略過的那句若其實是使用者說的，不提示就無聲消失了
    @Test func withRealTextTheSessionLingersAndTheNoticeStillShows() {
        let (c, _, _, key, _, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("今天天氣不錯"), at: 10.5)
        c.handleTranscript(caption, at: 11.0)
        c.hotkeyReleased(at: 12.0)
        c.asrStreamEnded(at: 12.1)

        #expect(key.ops == [.insert("今天天氣不錯")])
        #expect(c.isLingering)
        guard let lingering = hud.states.lastIndex(of: .lingering),
              let notice = hud.states.lastIndex(of: .notice(DictationController.captionHallucinationNotice)) else {
            Issue.record("延續窗或提示沒出現：\(hud.states)")
            return
        }
        #expect(lingering < notice, "提示要疊在延續窗上面（notice 過期後畫面回到「可修正」），不能被它蓋掉")
    }

    /// 罐頭語不是使用者開口的證據：橘色示警不能因它解除
    @Test func aCaptionDoesNotReleaseTheNoSpeechWarning() {
        let (c, _, _, _, _, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.noSpeechDetected, at: 13.0)
        c.handleTranscript(caption, at: 14.0)
        #expect(hud.states.last == .noSpeechDetected(mode: .hold))
    }

    /// 兩者都有時講罐頭語：示警之後辨識器解出了東西，代表後來確實有聲音進來，
    /// 「麥克風可能太遠」會讓使用者往錯的方向調
    @Test func theCaptionNoticeWinsOverTheNoSpeechNotice() {
        let (c, _, _, _, _, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.noSpeechDetected, at: 13.0)
        c.handleTranscript(caption, at: 14.0)
        c.hotkeyReleased(at: 15.0)
        c.asrStreamEnded(at: 15.1)

        #expect(hud.states.last == .notice(DictationController.captionHallucinationNotice))
        #expect(!hud.states.contains(.notice(DictationController.noSpeechNotice)))
        #expect(c.phase == .idle)
    }

    /// 旗標是「這一段」的：延續窗內續聽的下一段沒有罐頭語，就不再提示
    @Test func theNoticeDoesNotLeakIntoTheNextListeningSegment() {
        let (c, _, _, _, _, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        c.handleTranscript(caption, at: 11.0)
        c.hotkeyReleased(at: 12.0)
        c.asrStreamEnded(at: 12.1)
        #expect(c.isLingering)                         // 前提：下一次按下是同 session 續聽

        c.hotkeyPressed(at: 13.0)
        c.handleTranscript(.finalized("第二句"), at: 13.5)
        c.hotkeyReleased(at: 14.0)
        c.asrStreamEnded(at: 14.1)

        let notices = hud.states.filter { $0 == .notice(DictationController.captionHallucinationNotice) }
        #expect(notices.count == 1, "上一段的罐頭語在下一段又提示了一次")
        #expect(hud.states.last == .lingering)
    }

    /// 排空中按下熱鍵（#85）：舊串流的罐頭語提示要走救援提示通道，才不會被接手的錄音畫面蓋掉
    @Test func whileQueuedTheOldSessionsCaptionNoticeGoesThroughTheRescueChannel() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, asr, hud) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)
        c.hotkeyPressed(at: 11.5)                       // 排空中按下：排隊
        c.handleTranscript(caption, at: 11.8)          // 舊串流排空時解出罐頭語

        c.asrStreamEnded(at: 12.0)

        #expect(hud.rescueNotices == [DictationController.captionHallucinationNotice])
        #expect(asr.startCount == 2)
        #expect(c.phase == .listening(.hold))
    }

    /// **過濾只在 Whisper 引擎的出口。** 系統內建引擎送來同樣的字是一般的定稿——
    /// 那是使用者真的說了，控制器不得自作主張再濾一次。
    @Test func aFinalizedWithTheSameWordsIsInsertedNormally() {
        let (c, _, _, key, _, hud) = makeController()
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("謝謝觀看"), at: 10.5)
        c.hotkeyReleased(at: 11.0)
        c.asrStreamEnded(at: 11.1)
        #expect(key.ops == [.insert("謝謝觀看")])
        #expect(!hud.states.contains(.notice(DictationController.captionHallucinationNotice)))
    }
}
