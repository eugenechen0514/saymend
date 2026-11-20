import Foundation
import Testing
import WhisperKit
@testable import SaymendCore

/// 收尾補解碼（issue #22）的決策。真正的解碼要載入模型，不在這裡；這裡驗「要不要補、補哪段、
/// 結果怎麼併、失敗怎麼退」。
///
/// 樣本數一律以 16kHz 計：1600 個樣本＝0.1 秒＝一格能量。
private let sr = 16_000
private let bucket = 1_600

private func energy(_ buckets: Int, voicedAt voiced: Set<Int> = [], level: Float = 0.8) -> [Float] {
    (0..<buckets).map { voiced.contains($0) ? level : 0.05 }
}

private func plan(total: Int, decoded: Int, confirmedEnd: Float = 0,
                  energy e: [Float], useVAD: Bool = true,
                  threshold: Float = 0.3) -> StreamTailDrain.Tail? {
    StreamTailDrain.plan(ledger: .init(decodedSamples: decoded, confirmedEndSeconds: confirmedEnd),
                         totalSamples: total, relativeEnergy: e,
                         useVAD: useVAD, silenceThreshold: threshold)
}

@Suite struct StreamTailDrainPlanTests {
    /// 最後一趟已經解到結尾：沒有東西可補，大模型不該再多等一趟。
    /// VAD 關掉時也一樣（那時沒有有聲判定替它擋）。
    @Test(arguments: [true, false])
    func nothingIsDrainedWhenTheLastPassReachedTheEnd(useVAD: Bool) {
        #expect(plan(total: 3 * sr, decoded: 3 * sr, energy: energy(30, voicedAt: [29]), useVAD: useVAD) == nil)
    }

    /// #22 的情境：最後一趟之後還有一段有聲的音訊。窗口從已定稿片段的結束點算到結尾。
    @Test func aVoicedTailThatNoPassReachedIsDrained() throws {
        let tail = try #require(plan(total: 3 * sr, decoded: 2 * sr, confirmedEnd: 0.5,
                                     energy: energy(30, voicedAt: Set(20..<30))))
        #expect(tail.clipStartSeconds == 0.5)
        #expect(tail.undecodedSeconds == 1.0)
        #expect(tail.windowSeconds == 2.5)
    }

    /// 放開熱鍵前已經停嘴：尾端只有靜音，補解碼只會讓大模型白跑十幾秒
    @Test func aSilentTailIsNotDrained() {
        #expect(plan(total: 3 * sr, decoded: 2 * sr, energy: energy(30, voicedAt: Set(0..<20))) == nil)
    }

    /// 有聲的那一格正好在**已解過**的範圍裡（沒解過的 10 格之前一格）：不算。
    /// 看的格數多算一格，靜音尾端就會被誤判成有聲。
    @Test func voiceBeforeTheUndecodedRangeDoesNotCount() {
        #expect(plan(total: 3 * sr, decoded: 2 * sr, energy: energy(30, voicedAt: [19])) == nil)
    }

    /// 沒解過的是 1 格又 1 個樣本：不足一格的殘量也算一格（`StreamFedAudioSource.finish` 把它結算成最後一格），
    /// 所以要看 2 格。只看 1 格的話，聲音落在倒數第二格就漏掉。
    @Test func aPartialBucketCountsAsAWholeBucket() {
        let total = 2 * sr + bucket + 1
        let e = energy(22, voicedAt: [20])
        #expect(plan(total: total, decoded: 2 * sr, energy: e) != nil)
    }

    /// 解到的位置不在格子邊界上：沒解過的第一個樣本所在的那一格也要看。
    /// 以「沒解過的長度 ÷ 一格」回推格數的話，這一格會被漏掉（decoded=33,000 落在第 20 格中間，
    /// 33,000～49,000 共 16,000 個樣本＝恰好 10 格，回推只看第 21～30 格）。
    @Test func theBucketHoldingTheFirstUndecodedSampleCounts() {
        let e = energy(31, voicedAt: [20])
        #expect(plan(total: 49_000, decoded: 33_000, energy: e) != nil)
    }

    /// **為什麼不用套件的 `isVoiceDetected`。** 它只看新音訊的前段：超過 2 秒時最後 1 秒不看，
    /// 因為串流中那 1 秒下一趟還會看到。收尾沒有下一趟——講到最後一刻才放開，聲音就落在那 1 秒。
    @Test func voiceInTheLastSecondOfALongTailIsDrained() {
        let e = energy(50, voicedAt: Set(45..<50))
        #expect(AudioProcessor.isVoiceDetected(in: e, nextBufferInSeconds: 2.5, silenceThreshold: 0.3) == false)
        #expect(plan(total: 5 * sr, decoded: 5 * sr / 2, energy: e) != nil)
    }

    /// 門檻是「超過」不是「達到」，與套件 `isVoiceDetected` 一致
    @Test func energyExactlyAtTheThresholdIsSilence() {
        let e = energy(30, voicedAt: Set(20..<30), level: 0.3)
        #expect(plan(total: 3 * sr, decoded: 2 * sr, energy: e, threshold: 0.3) == nil)
    }

    /// 關掉 VAD＝連靜音都送去解碼（設定頁的語意），收尾也照辦
    @Test func withoutVADASilentTailIsDrainedToo() {
        #expect(plan(total: 3 * sr, decoded: 2 * sr, energy: energy(30), useVAD: false) != nil)
    }

    /// 窗口不超過 1 秒：套件的解碼器本來就不解（`windowClipTime`），補了必定是空的，只會讓 HUD 白顯示「辨識中…」。
    @Test(arguments: [
        (total: 12_800, confirmedEnd: Float(0)),       // 整段 0.8 秒
        (total: 5 * 16_000, confirmedEnd: Float(4.2)), // 5 秒的 session，但窗口只剩 0.8 秒
        (total: 16_000, confirmedEnd: Float(0)),       // 剛好 1 秒：解碼器的條件是嚴格大於
    ])
    func aWindowOfAtMostOneSecondIsNotDrained(total: Int, confirmedEnd: Float) {
        let e = energy(50, voicedAt: Set(0..<50))
        #expect(plan(total: total, decoded: 0, confirmedEnd: confirmedEnd, energy: e) == nil)
    }

    /// 窗口超過 1 秒一個格子：要補
    @Test func aWindowJustOverOneSecondIsDrained() {
        #expect(plan(total: sr + bucket, decoded: 0, energy: energy(11, voicedAt: Set(0..<11))) != nil)
    }

    /// 下限是抄來的套件預設。套件改了，補解碼的判定就和解碼器實際的行為脫節。
    @Test func drainWindowFloorMatchesWhisperKit() {
        #expect(StreamTailDrain.minimumWindowSeconds == Double(DecodingOptions().windowClipTime))
    }
}

@Suite struct StreamTailDrainMergeTests {
    private let q1 = TranscriptSegmentQuality(avgLogprob: -0.2, compressionRatio: 1.1)
    private let q2 = TranscriptSegmentQuality(avgLogprob: -0.4, compressionRatio: 1.3)
    private let q3 = TranscriptSegmentQuality(avgLogprob: -0.6, compressionRatio: 1.5)

    private func ledger(confirmed: String = "第一句。", unconfirmed: String = "第二",
                        confirmedQuality: [TranscriptSegmentQuality]? = nil) -> StreamTailDrain.Ledger {
        .init(decodedSamples: 0, confirmedEndSeconds: 0,
              lastProgress: .init(confirmed: confirmed, unconfirmed: unconfirmed,
                                  confirmedQuality: confirmedQuality ?? [q1], unconfirmedQuality: [q1]))
    }

    /// 定稿不動，暫時文字換成補解碼的結果（品質一併換掉，收尾補發的診斷才對得上那段文字）
    @Test func theDrainReplacesTheUnconfirmedAndKeepsTheConfirmed() {
        let p = StreamTailDrain.progress(after: ledger(), drained: [.init(text: "第二句講完了", quality: q2)])
        #expect(p == WhisperStreamProgress(confirmed: "第一句。", unconfirmed: "第二句講完了",
                                           confirmedQuality: [q1], unconfirmedQuality: [q2]))
    }

    /// 多個片段照順序串起來，品質一段一個
    @Test func severalSegmentsAreJoinedInOrder() {
        let p = StreamTailDrain.progress(after: ledger(), drained: [
            .init(text: "第二句。", quality: q2), .init(text: "第三句。", quality: q3),
        ])
        #expect(p?.unconfirmed == "第二句。第三句。")
        #expect(p?.unconfirmedQuality == [q2, q3])
    }

    /// 解出空白：無從判斷誰對，留著 HUD 上已經給使用者看過的那段，不要清掉
    @Test(arguments: [[], ["  "], ["\n", " "]])
    func aBlankDrainKeepsTheLastPass(texts: [String]) {
        let drained = texts.map { StreamTailDrain.DrainedSegment(text: $0, quality: q2) }
        #expect(StreamTailDrain.progress(after: ledger(), drained: drained) == nil)
    }

    /// 一趟都沒解過（套件還沒回呼過）：定稿是空的
    @Test func withoutAnyEarlierPassTheConfirmedIsEmpty() {
        let p = StreamTailDrain.progress(after: .init(), drained: [.init(text: "好", quality: q2)])
        #expect(p == WhisperStreamProgress(confirmed: "", unconfirmed: "好",
                                           confirmedQuality: [], unconfirmedQuality: [q2]))
    }
}

private struct DecodeFailure: Error {}

private final class Emitted: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [WhisperStreamProgress] = []
    func append(_ p: WhisperStreamProgress) { lock.lock(); v.append(p); lock.unlock() }
    var all: [WhisperStreamProgress] { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite struct StreamTailDrainRunTests {
    private let tail = StreamTailDrain.Tail(clipStartSeconds: 17.4, undecodedSeconds: 9.9, windowSeconds: 30.8)
    private let ledger = StreamTailDrain.Ledger(
        decodedSamples: 0, confirmedEndSeconds: 17.4,
        lastProgress: .init(confirmed: "前面。", unconfirmed: "中段"))
    private let q = TranscriptSegmentQuality(avgLogprob: -0.3, compressionRatio: 1.2)

    /// 解碼起點交給呼叫端的是已定稿片段的結束點；結果併好之後交出去
    @Test func aSuccessfulDrainIsEmitted() async {
        let out = Emitted()
        var seenClip: Float?
        let outcome = await StreamTailDrain.run(tail, ledger: ledger, isCancelled: { false },
                                                decode: { clip in
                                                    seenClip = clip
                                                    return [.init(text: "中段和尾端", quality: q)]
                                                }, emit: out.append)
        #expect(outcome == .drained)
        #expect(seenClip == 17.4)
        #expect(out.all == [.init(confirmed: "前面。", unconfirmed: "中段和尾端",
                                  confirmedQuality: [], unconfirmedQuality: [q])])
    }

    /// 補解碼壞了不交任何東西：最後一趟的暫時文字照常由引擎補發，定稿早已上屏，不升級成失敗
    @Test func aFailedDrainEmitsNothing() async {
        let out = Emitted()
        let outcome = await StreamTailDrain.run(tail, ledger: ledger, isCancelled: { false },
                                                decode: { _ in throw DecodeFailure() }, emit: out.append)
        #expect(outcome == .failed(reason: String(describing: DecodeFailure())))
        #expect(out.all.isEmpty)
    }

    @Test func aBlankDrainEmitsNothing() async {
        let out = Emitted()
        let outcome = await StreamTailDrain.run(tail, ledger: ledger, isCancelled: { false },
                                                decode: { _ in [.init(text: " ", quality: q)] },
                                                emit: out.append)
        #expect(outcome == .emptyResult)
        #expect(out.all.isEmpty)
    }

    /// 補解碼期間按了 Esc：解完也不交（取消不得有文字上屏，同引擎的 fail-closed）
    @Test func aDrainCancelledWhileDecodingEmitsNothing() async {
        let out = Emitted()
        let outcome = await StreamTailDrain.run(tail, ledger: ledger, isCancelled: { true },
                                                decode: { _ in [.init(text: "尾端", quality: q)] },
                                                emit: out.append)
        #expect(outcome == .cancelled)
        #expect(out.all.isEmpty)
    }

    /// 取消造成的擲錯記成取消，不記成失敗（log 回查時兩者的意思完全不同）
    @Test func aThrowAfterCancellationIsACancellation() async {
        let outcome = await StreamTailDrain.run(tail, ledger: ledger, isCancelled: { true },
                                                decode: { _ in throw CancellationError() }, emit: { _ in })
        #expect(outcome == .cancelled)
    }
}

/// 補解碼的提早中止條件照抄套件 `AudioStreamTranscriber.shouldStopEarly`（private，叫不到）。
/// 回傳 false＝中止這個窗口、nil＝繼續。
@Suite struct TailDrainStopEarlyTests {
    private func progress(tokens: [Int], avgLogprob: Float? = nil) -> TranscriptionProgress {
        TranscriptionProgress(timings: TranscriptionTimings(), text: "", tokens: tokens, avgLogprob: avgLogprob)
    }
    private let options = DecodingOptions(compressionRatioThreshold: 2.4, logProbThreshold: -1.0)

    /// 退化成複讀：超過檢查窗口的 token 壓縮比過高就中止
    @Test func repetitionBeyondTheCheckWindowStops() {
        let p = progress(tokens: Array(repeating: 42, count: 61))
        #expect(WhisperKitModelActor.shouldStopEarly(progress: p, options: options, compressionCheckWindow: 60) == false)
    }

    /// token 數還沒超過檢查窗口：再重複也不判
    @Test func repetitionWithinTheCheckWindowContinues() {
        let p = progress(tokens: Array(repeating: 42, count: 60))
        #expect(WhisperKitModelActor.shouldStopEarly(progress: p, options: options, compressionCheckWindow: 60) == nil)
    }

    /// 壓縮比剛好等於門檻：不中止（套件是嚴格大於）
    @Test func aCompressionRatioExactlyAtTheThresholdContinues() {
        let tokens = Array(repeating: 42, count: 61)
        let ratio = TextUtilities.compressionRatio(of: Array(tokens.suffix(60)))
        let atThreshold = DecodingOptions(compressionRatioThreshold: ratio, logProbThreshold: -1.0)
        #expect(WhisperKitModelActor.shouldStopEarly(progress: progress(tokens: tokens), options: atThreshold,
                                                     compressionCheckWindow: 60) == nil)
    }

    /// 對數機率剛好等於門檻：不中止（套件是嚴格小於）
    @Test func anAverageLogprobExactlyAtTheThresholdContinues() {
        let p = progress(tokens: [1, 2, 3], avgLogprob: -1.0)
        #expect(WhisperKitModelActor.shouldStopEarly(progress: p, options: options, compressionCheckWindow: 60) == nil)
    }

    @Test func aLowAverageLogprobStops() {
        let p = progress(tokens: [1, 2, 3], avgLogprob: -1.5)
        #expect(WhisperKitModelActor.shouldStopEarly(progress: p, options: options, compressionCheckWindow: 60) == false)
    }

    @Test func aGoodAverageLogprobContinues() {
        let p = progress(tokens: [1, 2, 3], avgLogprob: -0.5)
        #expect(WhisperKitModelActor.shouldStopEarly(progress: p, options: options, compressionCheckWindow: 60) == nil)
    }
}

/// 套件狀態到我們這邊的接線（issue #22）。**接錯就是重覆上屏或漏字**，而且不會有任何編譯或執行期徵兆：
/// 定稿結束點變成 0，補解碼會從頭解，已上屏的定稿會被收尾補發再插一次。
@Suite struct TailDrainWiringTests {
    /// 套件的 `State` init 是 internal，測試建不出來，改用同一組欄位的假件
    private struct FakeState: StreamerStateReading {
        var lastBufferSize = 612_345
        var lastConfirmedSegmentEndSeconds: Float = 17.4
        var confirmedSegments = [
            TranscriptionSegment(start: 0, end: 9.1, text: "第一句。", avgLogprob: -0.2, compressionRatio: 1.1),
            TranscriptionSegment(start: 9.1, end: 17.4, text: "第二句。", avgLogprob: -0.3, compressionRatio: 1.2),
        ]
        var unconfirmedSegments = [
            TranscriptionSegment(start: 17.4, end: 30.0, text: "還在改", avgLogprob: -0.6, compressionRatio: 1.5),
        ]
    }
    private func state() -> FakeState { FakeState() }

    @Test func theLedgerTakesTheDecodedSamplesAndTheConfirmedEnd() {
        let p = WhisperStreamProgress(confirmed: "x", unconfirmed: "y")
        let ledger = WhisperKitModelActor.tailLedger(from: state(), progress: p)
        #expect(ledger == .init(decodedSamples: 612_345, confirmedEndSeconds: 17.4, lastProgress: p))
    }

    @Test func progressKeepsConfirmedAndUnconfirmedApart() {
        let p = WhisperKitModelActor.progress(from: state())
        #expect(p == WhisperStreamProgress(
            confirmed: "第一句。第二句。", unconfirmed: "還在改",
            confirmedQuality: [.init(avgLogprob: -0.2, compressionRatio: 1.1),
                               .init(avgLogprob: -0.3, compressionRatio: 1.2)],
            unconfirmedQuality: [.init(avgLogprob: -0.6, compressionRatio: 1.5)]))
    }

    /// 補解碼從已定稿片段的結束點解起，其餘解碼參數與串流每一趟相同（特殊 token 照樣濾掉、詞彙偏置照樣帶）
    @Test func theDrainDecodesFromTheClipStartWithTheStreamingOptions() {
        let streaming = WhisperKitModelActor.decodingOptions(language: "zh", promptTokens: [11, 12],
                                                             options: WhisperStreamingOptions(logProbThreshold: -0.8))
        let o = WhisperKitModelActor.drainDecodingOptions(streaming, clipStart: 17.4)
        #expect(o.clipTimestamps == [17.4])
        #expect(o.language == "zh")
        #expect(o.skipSpecialTokens)
        #expect(o.promptTokens == [11, 12])
        #expect(o.logProbThreshold == -0.8)
    }
}
