import AVFoundation
import Speech
import SpeeckinkCore

/// Apple SpeechAnalyzer 引擎（規格 §4.2 主引擎，macOS 26+）。
/// 全專案唯一碰 Speech framework 的檔案；SDK 簽名若有出入照官方文件改這裡，介面不動。
final class SpeechAnalyzerEngine: ASREngine {
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?

    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let locale = Locale(identifier: localeIdentifier)
                    let transcriber = SpeechTranscriber(
                        locale: locale,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults],
                        attributeOptions: []
                    )
                    // 模型資產：系統管理，缺了就下載（首次會較久）
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    self.analyzer = analyzer

                    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        continuation.finish()
                        return
                    }
                    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
                    self.inputContinuation = inputBuilder
                    try await analyzer.start(inputSequence: inputSequence)

                    // 結果讀取：volatile／finalized 直接對應 TranscriptEvent
                    let resultTask = Task {
                        do {
                            for try await result in transcriber.results {
                                let text = String(result.text.characters)
                                if result.isFinal {
                                    continuation.yield(.finalized(text))
                                } else {
                                    continuation.yield(.volatile(text))
                                }
                            }
                        } catch {
                            // 引擎中斷：讓事件串流結束，上游依「不能白說話」原則處理
                        }
                        continuation.finish()
                    }

                    // 音訊泵：轉檔成 analyzer 要的格式
                    var converter: AVAudioConverter?
                    for await chunk in audio {
                        let src = chunk.buffer
                        if converter == nil {
                            converter = AVAudioConverter(from: src.format, to: analyzerFormat)
                        }
                        guard let converter,
                              let out = Self.convert(src, with: converter, to: analyzerFormat) else { continue }
                        inputBuilder.yield(AnalyzerInput(buffer: out))
                    }
                    // 音訊正常結束：請 analyzer 排空所有 finalized 再收尾
                    inputBuilder.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    _ = await resultTask.value
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            self.pumpTask = task
        }
    }

    func cancel() {
        inputContinuation?.finish()
        pumpTask?.cancel()
        let analyzer = self.analyzer
        Task { try? await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
