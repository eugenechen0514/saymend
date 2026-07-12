import AVFoundation
import Speech
import SpeeckinkCore

/// Apple SpeechAnalyzer 引擎（規格 §4.2 主引擎，macOS 26+）。
/// 全專案唯一碰 Speech framework 的檔案；SDK 簽名若有出入照官方文件改這裡，介面不動。
/// 共享狀態（analyzer/inputContinuation/pumpTask）由 stateLock 序列化：
/// 背景 pump Task 寫入、cancel() 可能從 MainActor 進來，.v5 模式編譯器不會擋這個競爭。
final class SpeechAnalyzerEngine: ASREngine {
    private let stateLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?

    private func withState<T>(_ body: (inout SpeechAnalyzer?, inout AsyncStream<AnalyzerInput>.Continuation?, inout Task<Void, Never>?) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&analyzer, &inputContinuation, &pumpTask)
    }

    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
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
                    self?.withState { a, _, _ in a = analyzer }

                    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        continuation.finish()
                        return
                    }
                    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
                    self?.withState { _, c, _ in c = inputBuilder }
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
            withState { _, _, p in p = task }
        }
    }

    func cancel() {
        let (analyzer, continuation, pump) = withState { a, c, p -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) in
            let snapshot = (a, c, p)
            a = nil
            c = nil
            return snapshot
        }
        continuation?.finish()
        pump?.cancel()
        // 實際 SDK 的 cancelAndFinishNow() 非 throwing（M1 編譯警告來源），不再包 try?
        Task { await analyzer?.cancelAndFinishNow() }
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
