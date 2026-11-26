import AVFoundation
import Foundation
import SaymendControl
import Testing
@testable import SaymendCore

/// CLI 聽寫的實音訊 harness：**預設不跑**，設了兩個環境變數才跑。
///
/// 把一段語音檔以即時速度餵給**真的** WhisperKit 引擎（與正式路徑同一條），前後墊上低音量的環境噪音
/// （模擬麥克風開著、沒人講話），驗證 `--silence-ms` 能在真實語音的音量包絡上判出「開口 → 說完 → 靜音」
/// 並自動定稿，而且辨識結果真的回到呼叫端。
///
/// 它**不能**取代真人對麥克風說話：麥克風增益、距離、房間迴響都不在這裡。麥克風本身的開關由
/// App 端實機驗證（`docs/control-interface.md` 的驗證紀錄）。
///
/// 環境變數：
/// - `SAYMEND_CLI_LIVE_MODEL`：WhisperKit 模型資料夾
/// - `SAYMEND_CLI_LIVE_AUDIO`：語音檔（例：`say -v Meijia -o speech.aiff "…"`）
/// - `SAYMEND_CLI_LIVE_SILENCE_MS`：選填，預設 1200
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAYMEND_CLI_LIVE_MODEL"] != nil
                                && ProcessInfo.processInfo.environment["SAYMEND_CLI_LIVE_AUDIO"] != nil))
struct CLIDictationLiveHarness {
    /// 從檔案「收音」的麥克風：先 1 秒環境音、再即時播放語音檔、之後一直是環境音，直到 `stop()`。
    final class FileFedMicrophone: AudioCaptureService, @unchecked Sendable {
        var levelHandler: ((Float) -> Void)?
        let leadIn: Double
        private let chunks: [AVAudioPCMBuffer]
        private let format: AVAudioFormat
        private var continuation: AsyncStream<AudioChunk>.Continuation?
        private var feeder: Task<Void, Never>?
        private(set) var stopCount = 0
        let speechSeconds: Double

        init(file url: URL, leadIn: Double = 1.0) throws {
            let file = try AVAudioFile(forReading: url)
            format = file.processingFormat
            var out: [AVAudioPCMBuffer] = []
            while file.framePosition < file.length {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                try file.read(into: b, frameCount: 4096)
                if b.frameLength == 0 { break }
                out.append(b)
            }
            chunks = out
            speechSeconds = Double(out.reduce(0) { $0 + Int($1.frameLength) }) / format.sampleRate
            self.leadIn = leadIn
        }

        /// 低音量、決定性的噪音（RMS 約 0.0003，位準約 0.006）
        private func ambient(seed: inout UInt64) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            b.frameLength = 4096
            for ch in 0..<Int(format.channelCount) {
                let d = b.floatChannelData![ch]
                for i in 0..<4096 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    d[i] = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.001
                }
            }
            return b
        }

        func start() throws -> AsyncStream<AudioChunk> {
            let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self)
            continuation = cont
            let chunks = self.chunks
            let rate = format.sampleRate
            let leadIn = self.leadIn
            feeder = Task.detached { [self] in
                let clock = ContinuousClock()
                let start = clock.now
                var at = 0.0
                var seed: UInt64 = 42
                func emit(_ b: AVAudioPCMBuffer) async -> Bool {
                    at += Double(b.frameLength) / rate
                    try? await clock.sleep(until: start.advanced(by: .seconds(at)))
                    if Task.isCancelled { return false }
                    cont.yield(AudioChunk(buffer: b))
                    return true
                }
                while at < leadIn { guard await emit(ambient(seed: &seed)) else { return } }
                for c in chunks { guard await emit(c) else { return } }
                while true { guard await emit(ambient(seed: &seed)) else { return } }
            }
            return stream
        }

        func stop() {
            stopCount += 1
            feeder?.cancel()
            continuation?.finish()
            continuation = nil
        }
    }

    @Test func speechThenSilenceEndsByItselfWithRealRecognition() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["SAYMEND_CLI_LIVE_MODEL"]))
        let audioURL = URL(fileURLWithPath: try #require(env["SAYMEND_CLI_LIVE_AUDIO"]))
        let silenceMs = Int(env["SAYMEND_CLI_LIVE_SILENCE_MS"] ?? "") ?? 1200

        let mic = try FileFedMicrophone(file: audioURL)
        let engine = WhisperKitEngine(
            transcriber: WhisperKitTranscriber(),
            configProvider: { WhisperLocalConfig(selectedModelPath: model, extraScanRoots: [], modelWaitTimeout: 600) })
        let settings = AppSettings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!,
                                   secrets: InMemorySecretStore())
        let guardian = try TraditionalizeGuard()
        let cli = CLIDictationController(
            audio: mic, asr: engine, hud: FakeHUD(), settings: settings, history: nil,
            postProcess: { { guardian.apply($0, language: .zhTW) } })
        // 模型先載好：這裡量的是端點判斷，不是冷載入
        await engine.preloadSelection()

        let log = CLIEventLog()
        let wallStart = Date()
        cli.start(DictateOptions(maxSeconds: 60, silenceMs: silenceMs)) { log.events.append($0) }
        // App 的 0.25 秒 tick（音訊停了也要能判斷）
        let ticker = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)); cli.tick() }
        }
        #expect(await waitForTerminal(log, timeout: 120))
        ticker.cancel()
        let wall = Date().timeIntervalSince(wallStart)

        guard case .finished(let r)? = log.terminal else {
            Issue.record("沒有正常定稿：\(String(describing: log.terminal))"); return
        }
        let expectedEnd = mic.leadIn + mic.speechSeconds + Double(silenceMs) / 1000
        print("""
            [CLI live] 語音 \(String(format: "%.2f", mic.speechSeconds)) 秒、靜音門檻 \(silenceMs) ms；\
            錄音 \(r.durationMs) ms（理想 ≈ \(Int(expectedEnd * 1000)) ms），總耗時 \(String(format: "%.2f", wall)) 秒；\
            partial \(log.partials.count) 則
            [CLI live] raw=\(r.raw)
            [CLI live] text=\(r.text)
            """)
        #expect(!r.text.isEmpty, "辨識結果要回到呼叫端")
        #expect(mic.stopCount >= 1, "麥克風一定要關")
        // 不早於「語音播完」就結束（沒有在句中被切斷），也沒有拖到上限才結束
        #expect(Double(r.durationMs) / 1000 >= mic.leadIn + mic.speechSeconds, "不得在語音播完前就結束")
        #expect(Double(r.durationMs) / 1000 <= expectedEnd + 3.0, "說完之後要在靜音門檻附近自動結束，而不是拖到 --max-seconds")
    }
}
