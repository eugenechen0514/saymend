import AVFoundation
import Foundation
import Testing
@testable import SaymendCore

/// 本檔專用的 URLProtocol stub。**刻意不與 OpenAICompatProviderTests 的 StubURLProtocol 共用**：
/// Swift Testing 的 .serialized 只序列化單一 suite 內部，不同 suite 之間仍平行執行，
/// 共用同一個 static handler 會互相覆寫（spec §7 更正說明）。
final class WhisperStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
            }
            return d
        }
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct WhisperRemoteEngineTests {

    private func makeEngine(config: WhisperRemoteConfig? = WhisperRemoteConfig(
                                baseURL: URL(string: "https://stub.test/v1")!,
                                apiKey: "k", model: "whisper-1", timeout: 30),
                            maxDuration: TimeInterval = 600) -> WhisperRemoteEngine {
        WhisperStubURLProtocol.requestCount = 0
        WhisperStubURLProtocol.lastBody = nil
        WhisperStubURLProtocol.lastRequest = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [WhisperStubURLProtocol.self]
        return WhisperRemoteEngine(configProvider: { config },
                                   session: URLSession(configuration: cfg),
                                   maxDuration: maxDuration)
    }

    private func buffer(seconds: Double) -> AudioChunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(48000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 0.05) * 0.5 }
        return AudioChunk(buffer: buf)
    }

    /// 餵一段音訊、結束串流，收集引擎吐出的所有事件
    private func run(_ engine: WhisperRemoteEngine, seconds: Double = 0.5,
                     locale: String = "zh-TW") async -> [TranscriptEvent] {
        let (audio, cont) = AsyncStream.makeStream(of: AudioChunk.self)
        let events = engine.start(audio: audio, localeIdentifier: locale)
        cont.yield(buffer(seconds: seconds))
        cont.finish()
        var out: [TranscriptEvent] = []
        for await e in events { out.append(e) }
        return out
    }

    /// multipart body 含二進位 WAV，`String(data:encoding:.utf8)` 會因無效序列回 nil，
    /// 使所有 contains 斷言變成對空字串求值（連「不該出現」的斷言都會空洞通過）。
    /// 改用 lossy 解碼：無效位元組換成 U+FFFD，文字欄位與 "RIFF" 標頭皆原樣保留。
    private func bodyText() -> String {
        String(decoding: WhisperStubURLProtocol.lastBody ?? Data(), as: UTF8.self)
    }

    private func ok(_ json: String) {
        WhisperStubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(json.utf8))
        }
    }

    @Test func successYieldsTranscribingThenFinalized() async {
        ok(#"{"text":"今天天氣很好。"}"#)
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .finalized("今天天氣很好。")])
    }

    @Test func httpErrorYieldsFailedWithSharedVocabulary() async {
        WhisperStubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .failed(reason: "HTTP 401")])   // 與 M7 degradedReason 同語彙
    }

    @Test func transportErrorYieldsConnectivityReason() async {
        WhisperStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .failed(reason: "無法連線")])
    }

    @Test func timeoutYieldsTimeoutReasonWithSeconds() async {
        WhisperStubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .failed(reason: "逾時 30 秒")])
    }

    @Test func emptyTextYieldsFailed() async {
        ok(#"{"text":"   "}"#)
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .failed(reason: "回應內容為空")])
    }

    @Test func malformedJSONYieldsFailed() async {
        ok("not json at all")
        let events = await run(makeEngine())
        #expect(events == [.transcribing, .failed(reason: "回應格式不合法")])
    }

    @Test func missingConfigFailsClosedWithoutRequest() async {
        let events = await run(makeEngine(config: nil))
        #expect(events == [.failed(reason: "Whisper 端點未設定")])
        #expect(WhisperStubURLProtocol.requestCount == 0)   // 未設定不得發請求
    }

    @Test func exceedingMaxDurationFailsImmediatelyWithoutRequest() async {
        ok(#"{"text":"x"}"#)
        // 上限設 0.2 秒、餵 0.5 秒 → 累積階段即時失敗（不等串流結束）
        let events = await run(makeEngine(maxDuration: 0.2))
        #expect(events == [.failed(reason: "錄音超過 10 分鐘上限")])
        #expect(WhisperStubURLProtocol.requestCount == 0)   // 失敗發生在呼叫外部之前
    }

    @Test func multipartCarriesModelLanguageAndPrompt() async {
        ok(#"{"text":"ok"}"#)
        let engine = makeEngine()
        engine.contextualStrings = { ["聲紋辨識", "端對端加密"] }
        _ = await run(engine, locale: "zh-TW")
        let body = bodyText()
        #expect(body.contains("name=\"model\""))
        #expect(body.contains("whisper-1"))
        #expect(body.contains("name=\"language\""))
        #expect(body.contains("zh"))                       // ISO-639-1 前綴
        #expect(body.contains("name=\"prompt\""))
        #expect(body.contains("聲紋辨識、端對端加密"))
        #expect(body.contains("name=\"file\""))
        #expect(body.contains("RIFF"))                     // WAV 內容確實在 body 裡
    }

    @Test func promptOmittedWhenVocabEmpty() async {
        ok(#"{"text":"ok"}"#)
        let engine = makeEngine()
        engine.contextualStrings = { [] }
        _ = await run(engine)
        let body = bodyText()
        #expect(!body.contains("name=\"prompt\""))         // 空詞彙表不送空欄位
    }

    @Test func promptTruncatedAtFiveHundredCharacters() async {
        ok(#"{"text":"ok"}"#)
        let engine = makeEngine()
        engine.contextualStrings = { Array(repeating: "詞彙", count: 400) }
        _ = await run(engine)
        let body = bodyText()
        // 取出 prompt 欄位值並確認長度上限
        guard let range = body.range(of: "name=\"prompt\"\r\n\r\n") else {
            Issue.record("找不到 prompt 欄位"); return
        }
        let after = body[range.upperBound...]
        guard let end = after.range(of: "\r\n--") else { Issue.record("prompt 欄位未正確結束"); return }
        #expect(after[..<end.lowerBound].count <= 500)
    }

    @Test func authorizationHeaderSentOnlyWhenKeyPresent() async {
        ok(#"{"text":"ok"}"#)
        _ = await run(makeEngine())
        #expect(WhisperStubURLProtocol.lastRequest?
            .value(forHTTPHeaderField: "Authorization") == "Bearer k")

        ok(#"{"text":"ok"}"#)
        _ = await run(makeEngine(config: WhisperRemoteConfig(
            baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil,
            model: "whisper-1", timeout: 30)))
        #expect(WhisperStubURLProtocol.lastRequest?
            .value(forHTTPHeaderField: "Authorization") == nil)   // 無 key＝不送 header（本地端點常見）
    }

    @Test func requestTargetsAudioTranscriptionsPath() async {
        ok(#"{"text":"ok"}"#)
        _ = await run(makeEngine())
        #expect(WhisperStubURLProtocol.lastRequest?.url?.absoluteString
                == "https://stub.test/v1/audio/transcriptions")
        #expect(WhisperStubURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test func cancelEndsStreamWithoutFinalized() async {
        // handler 是同步閉包，故以 Thread.sleep 阻塞模擬「永不回應」
        WhisperStubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 5)
            throw URLError(.cancelled)
        }
        let engine = makeEngine()
        let (audio, cont) = AsyncStream.makeStream(of: AudioChunk.self)
        let events = engine.start(audio: audio, localeIdentifier: "zh-TW")
        cont.yield(buffer(seconds: 0.3))
        cont.finish()
        let collector = Task {
            var out: [TranscriptEvent] = []
            for await e in events { out.append(e) }
            return out
        }
        try? await Task.sleep(for: .milliseconds(150))
        engine.cancel()
        let out = await collector.value
        #expect(!out.contains { if case .finalized = $0 { return true }; return false })
    }
}
