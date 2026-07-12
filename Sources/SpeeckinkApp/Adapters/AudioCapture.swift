import AVFoundation
import SpeeckinkCore

/// 麥克風擷取（規格 §3.1）：AVAudioEngine input tap → AsyncStream<AudioChunk>；
/// 同時計算 RMS 位準供 HUD 波形。
final class AudioCapture: AudioCaptureService {
    var levelHandler: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() throws -> AsyncStream<AudioChunk> {
        let input = engine.inputNode
        // 防禦性移除：確保 bus 0 沒有前一次殘留的 tap（removeTap 對空 bus 是 no-op，冪等）。
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            continuation.yield(AudioChunk(buffer: buffer))
            if let level = Self.rmsLevel(buffer) {
                DispatchQueue.main.async { self?.levelHandler?(level) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // start 失敗要回滾已安裝的 tap，否則下次 installTap 在同一 bus 會拋 NSException 崩潰。
            input.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            throw error
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// 0...1 的音量位準
    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 20)   // 粗略正規化
    }
}
