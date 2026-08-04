import AVFoundation
import Foundation
import Testing
@testable import SaymendCore

/// 假串流辨識器：吐出「編排好的進度序列」，用來驗事件映射與去重。
private final class FakeStreamTranscriber: WhisperTranscribing, @unchecked Sendable {
    let lock = NSLock()
    /// 依序吐出的進度。預設：一次定稿。
    var steps: [WhisperStreamProgress] = [.init(confirmed: "整段本機辨識結果", unconfirmed: "")]
    /// 需要編排音訊統計時改設這個；設了就整串照發，`steps` 不再使用。
    var events: [WhisperStreamEvent]?
    var loadError: WhisperLoadError?
    /// 吐完 steps 之後改以擲錯收場
    var errorAfterSteps: Error?
    private(set) var seenPhrases: [String] = []
    private(set) var seenModelPath: URL?
    private(set) var seenLanguage: String?
    private(set) var seenOptions: WhisperStreamingOptions?
    private(set) var preloadCount = 0
    private(set) var transcribeCount = 0
    private(set) var unloadCount = 0
    var stateToReport: ModelLoadState = .idle
    /// preload 是否真的把模型載起來（false＝模擬 coordinator 內 try? 吞掉的載入失敗）
    var preloadSucceeds = true

    /// async 方法內直接 lock() 在 Swift 6 語言模式是 error，包成同步函式才乾淨
    private func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func preload(modelPath: URL) async {
        sync { preloadCount += 1; if preloadSucceeds { stateToReport = .loaded } }
    }
    func state(modelPath: URL) async -> ModelLoadState { sync { stateToReport } }
    func unload() async { sync { unloadCount += 1; stateToReport = .idle } }

    func transcribe(modelPath: URL, audio: AsyncStream<AudioChunk>, language: String,
                    promptPhrases: [String],
                    options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamEvent, Error> {
        let (load, plan, err) = sync { () -> (WhisperLoadError?, [WhisperStreamEvent], Error?) in
            seenPhrases = promptPhrases
            seenModelPath = modelPath
            seenLanguage = language
            seenOptions = options
            transcribeCount += 1
            return (loadError, events ?? steps.map { .progress($0) }, errorAfterSteps)
        }
        return AsyncThrowingStream { cont in
            if let load { cont.finish(throwing: load); return }
            for s in plan { cont.yield(s) }
            cont.finish(throwing: err)
        }
    }
}

/// 可控暫停的假辨識器：進到辨識就發 entered 訊號、等 release 才收尾。
private final class GatedStreamFake: WhisperTranscribing, @unchecked Sendable {
    let lock = NSLock()
    private var cont: AsyncThrowingStream<WhisperStreamEvent, Error>.Continuation?
    var onEntered: (@Sendable () -> Void)?
    /// 放行後改以擲錯收場（驗取消時不得吐 .failed）
    var errorAfterRelease: Error?
    /// 放行時是否先吐一筆進度。設 false ＝「取消後直接擲錯」，這才走得到
    /// catch 區塊裡的取消守衛——先 yield 的話迴圈開頭就先返回了，守衛碰不到。
    var yieldOnRelease = true

    func preload(modelPath: URL) async {}
    func state(modelPath: URL) async -> ModelLoadState { .loaded }
    func unload() async {}

    func transcribe(modelPath: URL, audio: AsyncStream<AudioChunk>, language: String,
                    promptPhrases: [String],
                    options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamEvent, Error> {
        AsyncThrowingStream { c in
            lock.lock(); cont = c; lock.unlock()
            onEntered?()
        }
    }

    func release() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        if yieldOnRelease { c?.yield(.progress(.init(confirmed: "遲到結果", unconfirmed: ""))) }
        c?.finish(throwing: errorAfterRelease)
    }
}

private func chunk16k(_ f: Int = 1600) -> AudioChunk {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                            channels: 1, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f))!
    b.frameLength = AVAudioFrameCount(f)
    for i in 0..<f { b.floatChannelData![0][i] = 0.1 }
    return AudioChunk(buffer: b)
}

/// 餵一段音訊、結束串流，收集引擎吐出的所有事件
private func drive(_ e: WhisperKitEngine) async -> [TranscriptEvent] {
    let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
    c.yield(chunk16k())
    c.finish()
    var evs: [TranscriptEvent] = []
    for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
    return evs
}

private func engine(_ f: any WhisperTranscribing,
                    path: URL? = URL(filePath: "/tmp/m"),
                    options: WhisperStreamingOptions = WhisperStreamingOptions()) -> WhisperKitEngine {
    WhisperKitEngine(transcriber: f,
                     configProvider: { WhisperLocalConfig(selectedModelPath: path, extraScanRoots: []) },
                     optionsProvider: { options })
}

private func finalizedTexts(_ evs: [TranscriptEvent]) -> [String] {
    evs.compactMap { if case .finalized(let t, _) = $0 { return t }; return nil }
}
/// issue #10：定稿事件帶的品質診斷，順序與 `finalizedTexts` 一致
private func finalizedQualities(_ evs: [TranscriptEvent]) -> [TranscriptQuality?] {
    evs.compactMap { if case .finalized(_, let q) = $0 { return .some(q) }; return nil }
}
private func volatileTexts(_ evs: [TranscriptEvent]) -> [String] {
    evs.compactMap { if case .volatile(let t) = $0 { return t }; return nil }
}

@Suite struct WhisperKitEngineTests {
    @Test func transcribingThenFinalized() async {
        let f = FakeStreamTranscriber()
        let evs = await drive(engine(f))
        #expect(evs.contains(.transcribing))
        #expect(finalizedTexts(evs) == ["整段本機辨識結果"])
        #expect(f.seenModelPath == URL(filePath: "/tmp/m"))
    }

    // MARK: - 事件映射與去重（本張票的核心）

    /// **這條若失守，話語永不閉合、整個串流改造歸零。**
    /// 套件的狀態變更回呼每個音訊 buffer 都會觸發（含靜音），內容常常完全沒變；
    /// 斷句器對任何辨識事件都會重置靜音計時，照單全收就再也不會斷句。
    @Test func identicalProgressEmitsNoEvents() async {
        let f = FakeStreamTranscriber()
        let same = WhisperStreamProgress(confirmed: "已定稿", unconfirmed: "進行中")
        f.steps = [same, same, same, same, same]
        let evs = await drive(engine(f))
        // 五筆完全相同的進度：定稿只在第一次發一次，「進行中」的第二筆來自串流結束時的
        // 尾端補發。去重若失守，這裡會各出現五筆。
        #expect(finalizedTexts(evs) == ["已定稿", "進行中"])
        #expect(volatileTexts(evs) == ["進行中"])       // 只有第一次
    }

    @Test func changedUnconfirmedEmitsOneVolatileEach() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "", unconfirmed: "今"),
            .init(confirmed: "", unconfirmed: "今天"),
            .init(confirmed: "", unconfirmed: "今天天氣"),
        ]
        let evs = await drive(engine(f))
        #expect(volatileTexts(evs) == ["今", "今天", "今天天氣"])
        // 串流進行中一個定稿都不該發——暫時文字不是定稿。唯一那筆是串流結束時的尾端補發，
        // 且必須排在所有暫時文字之後。
        #expect(finalizedTexts(evs) == ["今天天氣"])
        #expect(evs.last == .finalized("今天天氣"))
    }

    /// 定稿只增不減：每次只吐**新增的那一段**，重覆的部分不得再上屏一次
    @Test func grownConfirmedEmitsOnlyTheNewPart() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "第一句。", unconfirmed: ""),
            .init(confirmed: "第一句。第二句。", unconfirmed: ""),
            .init(confirmed: "第一句。第二句。第三句。", unconfirmed: ""),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["第一句。", "第二句。", "第三句。"])
    }

    @Test func confirmedAndUnconfirmedBothChangeEmitsBoth() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "", unconfirmed: "今天天氣"),
            .init(confirmed: "今天天氣不錯。", unconfirmed: "我想"),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["今天天氣不錯。", "我想"])   // 末筆為收尾補發
        #expect(volatileTexts(evs) == ["今天天氣", "我想"])
        // 定稿要排在該步的暫時文字之前：暫時文字是「定稿之後還沒定的那截」
        let fi = evs.firstIndex(of: .finalized("今天天氣不錯。"))!
        let vi = evs.firstIndex(of: .volatile("我想"))!
        #expect(fi < vi)
    }

    /// 未定稿文字被推翻（變短或內容不同）只發暫時文字事件，**不得**產生定稿事件
    @Test func retractedUnconfirmedDoesNotFinalize() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "", unconfirmed: "今天天氣真"),
            .init(confirmed: "", unconfirmed: "今天"),
            .init(confirmed: "", unconfirmed: "金田"),
        ]
        let evs = await drive(engine(f))
        #expect(volatileTexts(evs) == ["今天天氣真", "今天", "金田"])
        // 被推翻的那兩版一個字都不得上屏；只有最後倖存的那版在收尾時補發
        #expect(finalizedTexts(evs) == ["金田"])
    }

    /// 定稿內容被重寫（非前綴關係）時保守處理：整段當新增，寧可重覆也不要漏字
    @Test func rewrittenConfirmedFallsBackToWholeText() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "今天天氣", unconfirmed: ""),
            .init(confirmed: "金田天氣不錯", unconfirmed: ""),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["今天天氣", "金田天氣不錯"])
    }

    @Test func blankConfirmedDeltaEmitsNothing() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "有字", unconfirmed: ""),
            .init(confirmed: "有字   ", unconfirmed: ""),   // 只多了空白
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["有字"])
    }

    // MARK: - 沒偵測到語音的示警（issue #18）

    /// **實機 2026-08-01 的失敗情境**：使用者講了 11 秒，整段沒有一格相對能量超過門檻，
    /// 串流轉錄器一次都沒把音訊送去解碼——欄位、HUD 全空，沒有任何錯誤。
    /// 引擎必須在聽寫進行中就把這件事說出來，而不是讓使用者講完整段才發現。
    @Test func silentSessionWarnsWhileStillListening() async throws {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 1.0),
                    .audioStats(voicedBuckets: 0, seconds: 2.5),
                    .audioStats(voicedBuckets: 0, seconds: 3.5),   // 過門檻 → 此刻就該示警
                    .progress(.init(confirmed: "後面才辨出的字", unconfirmed: ""))]
        let evs = await drive(engine(f))
        // 判別靠**順序**：聽寫中發的示警必然排在後續定稿之前。
        // 只寫 `contains` 的話，拿掉聽寫中示警、單靠收尾補發也會通過——測試就沒有牙齒。
        let wi = try #require(evs.firstIndex(of: .noSpeechDetected))
        let fi = try #require(evs.firstIndex(of: .finalized("後面才辨出的字")))
        #expect(wi < fi, "示警排在定稿之後——它是收尾補發的，不是聽寫進行中發的")
    }

    /// 3 秒以下不示警：按了熱鍵先醞釀一下是常態，誤報比漏報更傷信任
    @Test func silenceUnderThreeSecondsDoesNotWarnWhileListening() async {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 1.0),
                    .audioStats(voicedBuckets: 0, seconds: 2.9),
                    .progress(.init(confirmed: "後來還是辨出東西了", unconfirmed: ""))]
        let evs = await drive(engine(f))
        // 2.9 秒仍 ≥ 1.5，收尾會補發——所以驗的是「聽寫中沒發」而非「完全沒發」。
        // 判別靠**順序**：聽寫中發的話會排在定稿之前，收尾補發的必然在定稿之後。
        // 少了這個順序斷言，把門檻改成 0 秒（即刻示警）也一樣能過，測試就沒有牙齒。
        #expect(evs.filter { $0 == .noSpeechDetected }.count == 1)
        let wi = evs.firstIndex(of: .noSpeechDetected)!
        let fi = evs.firstIndex(of: .finalized("後來還是辨出東西了"))!
        #expect(wi > fi, "示警排在定稿之前——它是聽寫中發的，不是收尾補發的")
    }

    /// 有偵測到語音就永不示警——正常聽寫不得被打擾
    @Test func voicedSessionNeverWarns() async {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 2.0),
                    .audioStats(voicedBuckets: 7, seconds: 4.0),
                    .audioStats(voicedBuckets: 12, seconds: 9.0),
                    .progress(.init(confirmed: "今天天氣不錯", unconfirmed: ""))]
        let evs = await drive(engine(f))
        #expect(!evs.contains(.noSpeechDetected))
        #expect(finalizedTexts(evs) == ["今天天氣不錯"])
    }

    /// 一個 session 最多示警一次。持續判否時 `audioStats` 每 0.5 秒就來一筆，
    /// 若每筆都發，斷句器的靜音計時會被打爆、話語永不閉合——#14 的核心紀律。
    @Test func warningIsEmittedAtMostOncePerSession() async {
        let f = FakeStreamTranscriber()
        f.events = (0..<12).map { .audioStats(voicedBuckets: 0, seconds: 3.0 + Double($0) * 0.5) }
        let evs = await drive(engine(f))
        #expect(evs.filter { $0 == .noSpeechDetected }.count == 1)
    }

    /// 1.5–3.0 秒的零語音 session：聽寫中不夠格示警，但收尾要補發。
    /// 少了收尾這一關，短嘗試會完全靜默——正是這張票要消滅的失敗模式。
    @Test func shortSilentSessionIsWarnedAtStreamEnd() async {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 1.8)]
        let evs = await drive(engine(f))
        #expect(evs.contains(.noSpeechDetected))
    }

    /// 1.5 秒以下＝誤觸熱鍵，不得每次手滑都被唸
    @Test func accidentalTapIsNotWarned() async {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 0.8)]
        let evs = await drive(engine(f))
        #expect(!evs.contains(.noSpeechDetected))
    }

    /// 失敗收場不得再疊一個示警：使用者要看的是失敗原因，不是「沒偵測到語音」
    @Test func failedStreamDoesNotAlsoWarn() async {
        let f = FakeStreamTranscriber()
        f.events = [.audioStats(voicedBuckets: 0, seconds: 5.0)]
        f.errorAfterSteps = WhisperStreamError.audioConversionFailed
        let evs = await drive(engine(f))
        // 聽寫中那筆示警已經發出去了（5 秒 > 3 秒），但收尾不得再補一筆
        #expect(evs.filter { $0 == .noSpeechDetected }.count == 1)
        #expect(evs.contains(.failed(reason: "音訊轉換失敗")))
    }

    // MARK: - 收尾：未定稿的尾端

    /// **短句聽寫會一個字都不出。**
    ///
    /// 套件的 `stopStreamTranscription` 只是把迴圈旗標關掉，**不會**把剩下的未定稿段落
    /// 轉正——它自己的示範 App 是把 confirmed 與 unconfirmed 併起來顯示，所以看不出問題。
    /// 我們只把 confirmed 的增量送上屏、unconfirmed 僅供 HUD 顯示，於是串流結束時還留在
    /// unconfirmed 的文字會**永遠遺失**。
    ///
    /// 而套件的定稿條件是 `segments.count > 定稿所需片段數`（預設 2）：Whisper 對五秒鐘的
    /// 一句話通常只切出 1 段，條件永遠不成立——整段聽寫一個字都不會落地。
    @Test func residualUnconfirmedIsFinalizedWhenStreamEndsNormally() async {
        let f = FakeStreamTranscriber()
        f.steps = [.init(confirmed: "", unconfirmed: "一整句話從頭到尾都沒被轉正")]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["一整句話從頭到尾都沒被轉正"])
    }

    /// 已定稿的部分不得因為補發尾端而重覆上屏
    @Test func tailFlushDoesNotDuplicateAlreadyConfirmedText() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "第一句。", unconfirmed: "第二句還在改"),
            .init(confirmed: "第一句。第二句定稿了。", unconfirmed: "第三句還在改"),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["第一句。", "第二句定稿了。", "第三句還在改"])
    }

    /// 尾端已經被轉正（unconfirmed 收斂成空）時不得再補一次空白事件
    @Test func emptyTailFlushesNothing() async {
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "", unconfirmed: "進行中"),
            .init(confirmed: "全都定稿了。", unconfirmed: "   "),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["全都定稿了。"])
    }

    /// 失敗收場時**不得**補發尾端：辨識中途壞掉，殘留的未定稿文字沒有可信度可言，
    /// 送上屏等於把半成品當成結果寫進使用者的欄位。
    @Test func tailIsNotFlushedWhenStreamFails() async {
        let f = FakeStreamTranscriber()
        f.steps = [.init(confirmed: "", unconfirmed: "半成品")]
        f.errorAfterSteps = WhisperStreamError.audioConversionFailed
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs).isEmpty)
        #expect(evs.contains(.failed(reason: "音訊轉換失敗")))
    }

    // MARK: - 辨識品質診斷（issue #10）

    /// 每筆定稿只帶**新增那幾個片段**的品質。刻意讓第一個片段品質很差、第二個很好：
    /// 切分若失守（整組都算進去），第二筆的兩個數字與片段數會同時對不上。
    @Test func finalizedCarriesQualityOfNewlyConfirmedSegmentsOnly() async throws {
        let bad = TranscriptSegmentQuality(avgLogprob: -0.90, compressionRatio: 2.5)
        let good = TranscriptSegmentQuality(avgLogprob: -0.10, compressionRatio: 1.0)
        let f = FakeStreamTranscriber()
        f.steps = [
            .init(confirmed: "第一句。", unconfirmed: "", confirmedQuality: [bad]),
            .init(confirmed: "第一句。第二句。", unconfirmed: "", confirmedQuality: [bad, good]),
        ]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["第一句。", "第二句。"])
        let qs = finalizedQualities(evs)
        let first = try #require(qs.first ?? nil)
        #expect(first.minAvgLogprob == -0.90)
        #expect(first.segmentCount == 1)
        let second = try #require(qs.count > 1 ? qs[1] : nil)
        #expect(second.minAvgLogprob == -0.10)
        #expect(second.maxCompressionRatio == 1.0)
        #expect(second.segmentCount == 1)
    }

    /// **收尾補發那筆也必須帶品質。** #15 的驗收量到短句聽寫**全部**的文字都走這條路
    /// （套件的定稿條件對只切出一段的短句永遠不成立）——漏了它，診斷對短句永遠是空的，
    /// 而幻覺恰好都是短句。
    @Test func tailFlushCarriesUnconfirmedQuality() async throws {
        let f = FakeStreamTranscriber()
        f.steps = [.init(confirmed: "", unconfirmed: "一整句話從頭到尾都沒被轉正",
                         unconfirmedQuality: [.init(avgLogprob: -0.55, compressionRatio: 1.9)])]
        let evs = await drive(engine(f))
        #expect(finalizedTexts(evs) == ["一整句話從頭到尾都沒被轉正"])
        let q = try #require(finalizedQualities(evs).first ?? nil)
        #expect(q.minAvgLogprob == -0.55)
        #expect(q.maxCompressionRatio == 1.9)
        #expect(q.segmentCount == 1)
    }

    /// 給不出品質的來源不得被捏造成有資料——空值會在統計時混進假樣本
    @Test func progressWithoutQualityYieldsNilQuality() async {
        let f = FakeStreamTranscriber()
        f.steps = [.init(confirmed: "沒有品質資料的定稿", unconfirmed: "")]
        let evs = await drive(engine(f))
        #expect(finalizedQualities(evs) == [nil])
    }

    // MARK: - 失敗路徑

    @Test func failsWhenNoModel() async {
        #expect(await drive(engine(FakeStreamTranscriber(), path: nil)).last == .failed(reason: "未選擇本機模型"))
    }

    @Test func failsOnLoadError() async {
        let f = FakeStreamTranscriber()
        f.loadError = WhisperLoadError(message: "x")
        #expect(await drive(engine(f)).last == .failed(reason: "模型載入失敗"))
    }

    @Test func failsOnTranscribeError() async {
        let f = FakeStreamTranscriber()
        f.errorAfterSteps = NSError(domain: "x", code: 1)
        #expect(await drive(engine(f)).last == .failed(reason: "辨識失敗"))
    }

    @Test func failsOnOverCapacityWithItsOwnWording() async {
        let f = FakeStreamTranscriber()
        f.steps = []
        f.errorAfterSteps = WhisperStreamError.overCapacity(minutes: 30)
        #expect(await drive(engine(f)).last == .failed(reason: "錄音超過 30 分鐘上限"))
    }

    @Test func failsOnAudioConversionWithItsOwnWording() async {
        let f = FakeStreamTranscriber()
        f.steps = []
        f.errorAfterSteps = WhisperStreamError.audioConversionFailed
        #expect(await drive(engine(f)).last == .failed(reason: "音訊轉換失敗"))
    }

    // MARK: - 參數與偏置

    @Test func passesBias() async {
        let f = FakeStreamTranscriber()
        let e = engine(f)
        e.contextualStrings = { ["術語A", "術語B"] }
        _ = await drive(e)
        #expect(f.seenPhrases == ["術語A", "術語B"])
    }

    @Test func passesStreamingOptionsThrough() async {
        let f = FakeStreamTranscriber()
        var opts = WhisperStreamingOptions()
        opts.requiredSegmentsForConfirmation = 5
        opts.silenceThreshold = 0.7
        opts.useVAD = false
        _ = await drive(engine(f, options: opts))
        #expect(f.seenOptions?.requiredSegmentsForConfirmation == 5)
        #expect(f.seenOptions?.silenceThreshold == 0.7)
        #expect(f.seenOptions?.useVAD == false)
    }

    // MARK: - 模型載入狀態（首次 ANE 編譯很久，不能折進「辨識中…」裝沒事）

    @Test func reportsLoadingModelBeforeTranscribing() async {
        let f = FakeStreamTranscriber()                  // 預設 .idle＝未載入
        let evs = await drive(engine(f))
        guard let i = evs.firstIndex(of: .loadingModel), let j = evs.firstIndex(of: .transcribing) else {
            Issue.record("預期先 .loadingModel 再 .transcribing，實得 \(evs)"); return
        }
        #expect(i < j)
        #expect(f.preloadCount == 1)
        #expect(finalizedTexts(evs) == ["整段本機辨識結果"])
    }

    @Test func skipsLoadingModelWhenAlreadyLoaded() async {
        let f = FakeStreamTranscriber()
        f.stateToReport = .loaded
        let evs = await drive(engine(f))
        #expect(!evs.contains(.loadingModel))
        #expect(evs.contains(.transcribing))
        #expect(f.preloadCount == 0)
    }

    /// preload 是 best-effort（coordinator 內以 try? 吞錯），載不起來時不得帶著沒載入的模型
    /// 硬進辨識——那會再觸發一次 ANE 編譯（large 數分鐘），還會先誤顯「辨識中…」
    @Test func failsWhenPreloadDoesNotLoadModel() async {
        let f = FakeStreamTranscriber()
        f.preloadSucceeds = false
        let evs = await drive(engine(f))
        #expect(evs.contains(.loadingModel))
        #expect(!evs.contains(.transcribing))
        #expect(evs.last == .failed(reason: "模型載入失敗"))
        #expect(f.transcribeCount == 0)
    }

    @Test func engineStateFollowsTranscriber() async {
        let f = FakeStreamTranscriber()
        f.stateToReport = .loaded
        #expect(await engine(f).state() == .loaded)
    }

    @Test func engineStateIsIdleWithoutSelectedModel() async {
        let f = FakeStreamTranscriber()
        f.stateToReport = .loaded
        #expect(await engine(f, path: nil).state() == .idle)
    }

    @Test func engineUnloadForwards() async {
        let f = FakeStreamTranscriber()
        await engine(f).unload()
        #expect(f.unloadCount == 1)
    }

    @Test func preloadForwards() async {
        let f = FakeStreamTranscriber()
        await engine(f).preload()
        #expect(f.preloadCount == 1)
    }

    // MARK: - 取消
    //
    // 下面兩條驗的是**使用者可見的契約**：取消之後不得出現 .failed 或 .finalized。
    // 它們**不是**在驗引擎裡那幾個 Task.isCancelled 守衛——實測把守衛全部拿掉這兩條
    // 仍然綠，因為 AsyncThrowingStream 在消費端被取消時迭代即結束，catch 不會執行。
    // 契約有守住就夠；守衛屬 defence-in-depth，已在產品碼標明無測試覆蓋。

    /// REV #3：偏置讀取（MainActor 往返）期間被取消 → 根本不該進辨識
    @Test func cancelBeforeTranscribeSkipsTranscriber() async {
        let f = FakeStreamTranscriber()
        let e = engine(f)
        e.contextualStrings = { [weak e] in e?.cancel(); return [] }   // 讀偏置的當下取消
        let evs = await drive(e)
        #expect(f.transcribeCount == 0)
        #expect(finalizedTexts(evs).isEmpty)
    }

    /// REV #3：辨識中被取消，之後才擲錯 → 不得吐 .failed（取消不是失敗）
    @Test func cancelDuringTranscribeSuppressesFailure() async {
        let f = GatedStreamFake()
        f.errorAfterRelease = NSError(domain: "x", code: 1)
        f.yieldOnRelease = false          // 直接擲錯，才走得到 catch 區塊的取消守衛
        let e = engine(f)
        let (entered, enteredC) = AsyncStream.makeStream(of: Void.self)
        f.onEntered = { enteredC.yield(()) }
        let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
        c.yield(chunk16k())
        c.finish()
        let collector = Task {
            var evs: [TranscriptEvent] = []
            for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
            return evs
        }
        var it = entered.makeAsyncIterator()
        _ = await it.next()
        e.cancel()
        f.release()
        let evs = await collector.value
        #expect(!evs.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func cancelDuringTranscribeEmitsNoFinalized() async {
        let f = GatedStreamFake()
        let e = engine(f)
        let (entered, enteredC) = AsyncStream.makeStream(of: Void.self)
        f.onEntered = { enteredC.yield(()) }
        let (st, c) = AsyncStream.makeStream(of: AudioChunk.self)
        c.yield(chunk16k())
        c.finish()
        let collector = Task {
            var evs: [TranscriptEvent] = []
            for await ev in e.start(audio: st, localeIdentifier: "zh-TW") { evs.append(ev) }
            return evs
        }
        var it = entered.makeAsyncIterator()
        _ = await it.next()
        e.cancel()
        f.release()
        let evs = await collector.value
        #expect(!evs.contains(.finalized("遲到結果")))
    }
}
