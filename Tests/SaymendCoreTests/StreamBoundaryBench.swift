import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import SaymendCore

/// issue #19 的量測 harness：**預設不跑**，設了 `SAYMEND_BENCH19_MODEL` 才跑。
///
/// 用合成語音以即時速度餵給真的 `WhisperKitTranscriber`（與正式路徑同一條：串流轉錄器、
/// 收尾補解碼都在），記下每一則進度快照，並算出**不做邊界重複判斷**時會送出的定稿當對照組。
/// 正式引擎（含判斷）的結果用 `StreamBoundaryReplay` 把快照重播給它取得。
/// 這裡只負責產生資料；語料、矩陣與分析腳本在 `Scripts/bench/stream-boundary/`（見 ADR 0002）。
///
/// 環境變數：
/// - `SAYMEND_BENCH19_MODEL`：模型資料夾
/// - `SAYMEND_BENCH19_MANIFEST`：語料清單（`[{id, kind, voice, text, parts: [{path, gapAfter}]}]`）。
///   一段話由幾個片段組成，片段之間插入 `gapAfter` 秒的靜音（模擬邊講邊想的停頓）
/// - `SAYMEND_BENCH19_OUT`：輸出資料夾，每段一個 JSON
/// - `SAYMEND_BENCH19_REQUIRED`：定稿所需片段數（預設 2）
/// - `SAYMEND_BENCH19_SPEED`：餵音訊的倍速（預設 1）
/// - `SAYMEND_BENCH19_ONLY`：只跑這幾段（逗號分隔的 id）
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAYMEND_BENCH19_MODEL"] != nil))
struct StreamBoundaryBench {
    struct Part: Decodable { let path: String; let gapAfter: Double }
    struct Item: Decodable { let id, kind, voice, text: String; let parts: [Part] }
    struct Snapshot: Encodable {
        let t: Double
        let confirmed: String
        let unconfirmed: String
        var confirmedN: String { StreamBoundaryBench.normalize(confirmed) }
        var unconfirmedN: String { StreamBoundaryBench.normalize(unconfirmed) }
        enum CodingKeys: String, CodingKey { case t, confirmed, unconfirmed, confirmedN, unconfirmedN }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(t, forKey: .t)
            try c.encode(confirmed, forKey: .confirmed)
            try c.encode(unconfirmed, forKey: .unconfirmed)
            try c.encode(confirmedN, forKey: .confirmedN)
            try c.encode(unconfirmedN, forKey: .unconfirmedN)
        }
    }
    struct Record: Encodable {
        let id, kind, voice, text, model: String
        let required: Int
        let speed: Double
        let audioSeconds: Double
        let snapshots: [Snapshot]
        let drainingTailAt: Double?
        let feedEndAt: Double
        let finishedAt: Double
        /// 對照組：不做邊界重複判斷時的 `.finalized` 序列（定稿增量＋收尾補發），即 #19 之前的行為
        let emissions: [String]
        /// 比對用：繁轉簡、去掉標點與空白（小模型會簡繁混用，不正規化會漏判重複）
        let emissionsN: [String]
        let textN: String
        let error: String?
    }

    static func normalize(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
        return String(String.UnicodeScalarView(simplified.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    }

    /// 麥克風一個 chunk 的大小（48k 下約 85ms），與正式路徑相同
    static let chunkFrames: AVAudioFrameCount = 4096
    static let padSeconds = 0.4

    @Test func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["SAYMEND_BENCH19_MODEL"]))
        let manifest = URL(fileURLWithPath: try #require(env["SAYMEND_BENCH19_MANIFEST"]))
        let out = URL(fileURLWithPath: try #require(env["SAYMEND_BENCH19_OUT"]))
        let required = Int(env["SAYMEND_BENCH19_REQUIRED"] ?? "2") ?? 2
        let speed = Double(env["SAYMEND_BENCH19_SPEED"] ?? "1") ?? 1
        let only = env["SAYMEND_BENCH19_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: manifest))
        if let only { items = items.filter { only.contains($0.id) } }

        let transcriber = WhisperKitTranscriber()
        await transcriber.preload(modelPath: model)
        #expect(await transcriber.state(modelPath: model) == .loaded)

        var options = WhisperStreamingOptions()
        options.requiredSegmentsForConfirmation = required

        for item in items {
            let record = try await Self.runOne(item, transcriber: transcriber, model: model,
                                               options: options, speed: speed)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(record).write(to: out.appendingPathComponent("\(item.id).json"))
            print("[bench19] \(item.id) emissions=\(record.emissions.count) error=\(record.error ?? "-")")
        }
    }

    static func runOne(_ item: Item, transcriber: WhisperKitTranscriber, model: URL,
                       options: WhisperStreamingOptions, speed: Double) async throws -> Record {
        var format: AVAudioFormat?
        var chunks: [AVAudioPCMBuffer] = []
        /// 靜音也切成麥克風大小的 chunk 餵，與真的錄音一樣
        func silence(_ seconds: Double, _ format: AVAudioFormat) -> [AVAudioPCMBuffer] {
            var left = AVAudioFrameCount(seconds * format.sampleRate)
            var out: [AVAudioPCMBuffer] = []
            while left > 0 {
                let n = min(left, chunkFrames)
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
                b.frameLength = n       // AVAudioPCMBuffer 配置時已歸零
                out.append(b)
                left -= n
            }
            return out
        }
        for (i, part) in item.parts.enumerated() {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: part.path))
            let f = file.processingFormat
            format = format ?? f
            if i == 0 { chunks += silence(padSeconds, f) }
            while file.framePosition < file.length {
                let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: chunkFrames)!
                try file.read(into: b, frameCount: chunkFrames)
                if b.frameLength == 0 { break }
                chunks.append(b)
            }
            chunks += silence(part.gapAfter > 0 ? part.gapAfter : padSeconds, f)
        }
        let format_ = try #require(format)
        let audioSeconds = Double(chunks.reduce(0) { $0 + Int($1.frameLength) }) / format_.sampleRate

        let (audio, feed) = AsyncStream<SaymendCore.AudioChunk>.makeStream()
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let d = start.duration(to: clock.now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let feedEnd = Sendable_Box<Double>(0)
        let feeder = Task {
            var at = 0.0
            for c in chunks {
                at += Double(c.frameLength) / format_.sampleRate / speed
                try? await clock.sleep(until: start.advanced(by: .seconds(at)))
                feed.yield(SaymendCore.AudioChunk(buffer: c))
            }
            feedEnd.set(elapsed())
            feed.finish()
        }

        var snapshots: [Snapshot] = []
        var drainingAt: Double?
        var errorText: String?
        do {
            for try await ev in transcriber.transcribe(modelPath: model, audio: audio, language: "zh",
                                                        promptPhrases: [], options: options) {
                switch ev {
                case .progress(let p):
                    snapshots.append(.init(t: elapsed(), confirmed: p.confirmed, unconfirmed: p.unconfirmed))
                case .drainingTail:
                    drainingAt = drainingAt ?? elapsed()
                case .audioStats:
                    break
                }
            }
        } catch {
            errorText = String(describing: error)
        }
        _ = await feeder.value
        let finishedAt = elapsed()

        return Record(id: item.id, kind: item.kind, voice: item.voice, text: item.text,
                      model: model.lastPathComponent, required: options.requiredSegmentsForConfirmation,
                      speed: speed, audioSeconds: audioSeconds, snapshots: snapshots,
                      drainingTailAt: drainingAt, feedEndAt: feedEnd.get(), finishedAt: finishedAt,
                      emissions: errorText == nil ? emissions(of: snapshots) : [],
                      emissionsN: errorText == nil ? emissions(of: snapshots).map(normalize) : [],
                      textN: normalize(item.text), error: errorText)
    }

    /// #19 之前的 `WhisperKitEngine.pump` 規則：定稿變了就送新增的那段，結束時把殘留的暫時文字補發。
    static func emissions(of snapshots: [Snapshot]) -> [String] {
        var out: [String] = []
        var lastConfirmed = "", lastUnconfirmed = ""
        for s in snapshots {
            if s.confirmed != lastConfirmed {
                let delta = WhisperKitEngine.newlyConfirmed(previous: lastConfirmed, current: s.confirmed)
                lastConfirmed = s.confirmed
                let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
            if s.unconfirmed != lastUnconfirmed { lastUnconfirmed = s.unconfirmed }
        }
        let tail = lastUnconfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}

private final class Sendable_Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// issue #19：把 `StreamBoundaryBench` 錄下的進度快照**重播給真正的 `WhisperKitEngine`**，
/// 收它實際送出的定稿。驗的是正式的 `pump`（含邊界重複的判斷），不是分析腳本裡的模擬。
/// **預設不跑**，設了 `SAYMEND_BENCH19_REPLAY`（逗號分隔的輸出資料夾）才跑；
/// 結果寫到 `<資料夾>-replay/<id>.json`。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAYMEND_BENCH19_REPLAY"] != nil))
struct StreamBoundaryReplay {
    struct Snapshot: Decodable { let confirmed: String; let unconfirmed: String }
    struct Record: Decodable { let id: String; let snapshots: [Snapshot] }
    struct Replayed: Encodable { let id: String; let finalized: [String]; let finalizedN: [String] }

    final class ReplayTranscriber: WhisperTranscribing, @unchecked Sendable {
        let steps: [WhisperStreamProgress]
        init(_ steps: [WhisperStreamProgress]) { self.steps = steps }
        func preload(modelPath: URL) async {}
        func preloadSelection(modelPath: URL) async {}
        func state(modelPath: URL) async -> ModelLoadState { .loaded }
        func unload() async {}
        func transcribe(modelPath: URL, audio: AsyncStream<SaymendCore.AudioChunk>, language: String,
                        promptPhrases: [String],
                        options: WhisperStreamingOptions) -> AsyncThrowingStream<WhisperStreamEvent, Error> {
            AsyncThrowingStream { c in
                for s in steps { c.yield(.progress(s)) }
                c.finish()
            }
        }
    }

    @Test func replay() async throws {
        let dirs = try #require(ProcessInfo.processInfo.environment["SAYMEND_BENCH19_REPLAY"])
            .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        for dir in dirs {
            let out = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-replay")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            for f in files {
                let r = try JSONDecoder().decode(Record.self, from: Data(contentsOf: f))
                let fake = ReplayTranscriber(r.snapshots.map { .init(confirmed: $0.confirmed, unconfirmed: $0.unconfirmed) })
                let engine = WhisperKitEngine(transcriber: fake,
                                              configProvider: {
                                                  WhisperLocalConfig(selectedModelPath: URL(filePath: "/tmp/m"),
                                                                     extraScanRoots: [], modelWaitTimeout: 30)
                                              },
                                              optionsProvider: { WhisperStreamingOptions() })
                let (audio, c) = AsyncStream.makeStream(of: SaymendCore.AudioChunk.self)
                c.finish()
                var finalized: [String] = []
                for await ev in engine.start(audio: audio, localeIdentifier: "zh-TW") {
                    if case .finalized(let t, _) = ev { finalized.append(t) }
                }
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                try enc.encode(Replayed(id: r.id, finalized: finalized,
                                        finalizedN: finalized.map(StreamBoundaryBench.normalize)))
                    .write(to: out.appendingPathComponent("\(r.id).json"))
            }
            print("[replay19] \(dir.lastPathComponent): \(files.count) records")
        }
    }
}
