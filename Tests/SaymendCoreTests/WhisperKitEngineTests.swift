import AVFoundation
import Foundation
import Testing
@testable import SaymendCore

/// 假串流辨識器：吐出「編排好的進度序列」，用來驗事件映射與去重。
private final class FakeStreamTranscriber: WhisperTranscribing, @unchecked Sendable {
    let lock = NSLock()
    /// 依序吐出的進度。預設：一次定稿。
    var steps: [WhisperStreamProgress] = [.init(confirmed: "整段本機辨識結果", unconfirmed: "")]
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
                    options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamProgress, Error> {
        let (load, plan, err) = sync { () -> (WhisperLoadError?, [WhisperStreamProgress], Error?) in
            seenPhrases = promptPhrases
            seenModelPath = modelPath
            seenLanguage = language
            seenOptions = options
            transcribeCount += 1
            return (loadError, steps, errorAfterSteps)
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
    private var cont: AsyncThrowingStream<WhisperStreamProgress, Error>.Continuation?
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
                    options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamProgress, Error> {
        AsyncThrowingStream { c in
            lock.lock(); cont = c; lock.unlock()
            onEntered?()
        }
    }

    func release() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        if yieldOnRelease { c?.yield(.init(confirmed: "遲到結果", unconfirmed: "")) }
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
    evs.compactMap { if case .finalized(let t) = $0 { return t }; return nil }
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
        #expect(finalizedTexts(evs) == ["已定稿"])      // 只有第一次
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
        #expect(finalizedTexts(evs).isEmpty)            // 尚未定稿，一個字都不該上屏
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
        #expect(finalizedTexts(evs) == ["今天天氣不錯。"])
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
        #expect(finalizedTexts(evs).isEmpty)
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
