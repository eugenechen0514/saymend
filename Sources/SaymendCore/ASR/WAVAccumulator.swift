import AVFoundation

public enum WAVAccumulatorError: Error, Equatable {
    case converterUnavailable
    case conversionFailed
}

/// 逐 chunk 把麥克風原始格式（實測常為 48kHz float32）轉成 Whisper 端點要的
/// 16kHz / mono / PCM16 並累積（spec §4.2）。逐 chunk 轉換而非最後一次轉全部，
/// 避免同時持有原始 48kHz float32 全量造成記憶體尖峰。
/// 非執行緒安全：僅由 WhisperRemoteEngine 的單一 pump Task 使用。
public final class WAVAccumulator {
    public static let outputSampleRate: Double = 16000
    private static let bytesPerSample = 2

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var pcm = Data()

    public init() {}

    /// 已累積音訊的時長（秒）
    public var duration: TimeInterval {
        TimeInterval(pcm.count / Self.bytesPerSample) / Self.outputSampleRate
    }

    public func reset() {
        pcm.removeAll(keepingCapacity: true)
        // 轉換器一併丟棄：其內部尚有未排出的殘留樣本，留著會在下次 wavData() 排空時混入
        converter = nil
    }

    public func append(_ chunk: AudioChunk) throws {
        let src = chunk.buffer
        guard src.frameLength > 0 else { return }

        if converter == nil || outputFormat == nil {
            guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.outputSampleRate,
                                          channels: 1,
                                          interleaved: true),
                  let c = AVAudioConverter(from: src.format, to: out) else {
                throw WAVAccumulatorError.converterUnavailable
            }
            outputFormat = out
            converter = c
        }
        guard let converter, let outputFormat else { throw WAVAccumulatorError.converterUnavailable }

        // 輸出容量：取樣率比例 ＋ 餘裕（轉換器可能一次吐出略多於比例值的 frame）
        let ratio = outputFormat.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw WAVAccumulatorError.converterUnavailable
        }

        // 一次只餵一個來源 buffer：第二次索取回 .noDataNow 讓轉換器收工
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return src
        }
        if status == .error { throw WAVAccumulatorError.conversionFailed }

        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * Self.bytesPerSample
        ch[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { raw in
            pcm.append(raw, count: byteCount)
        }
    }

    /// 排空轉換器內部殘留（收尾用）。
    ///
    /// `AVAudioConverter` 一次 convert 只吐出內部量子的整數倍，餘量留在自己肚子裡；
    /// 而 `.noDataNow` 的語意是「暫時沒資料」——實測不會吐出殘留，必須以 `.endOfStream`
    /// 明示串流結束才排得出來。少了這一步，每次錄音尾端會固定丟掉一小段音訊：
    /// 實測 48k mono −6 樣本、48k 立體聲 −598、44.1k 立體聲 −356（首個 chunk 高達 −932），
    /// 排空後各格式皆與理論樣本數完全相符。
    ///
    /// 排空後丟棄轉換器：後續若再 append 會重建一個乾淨的，wavData() 重複呼叫亦不會重複排空。
    private func drain() {
        guard let converter, let outputFormat else { return }
        var iterations = 0
        while iterations < 64 {                       // 上限純為防呆，實測一輪即結束
            iterations += 1
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16384) else { return }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0, let ch = out.int16ChannelData {
                let byteCount = Int(out.frameLength) * Self.bytesPerSample
                ch[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { raw in
                    pcm.append(raw, count: byteCount)
                }
            }
            if status == .error || out.frameLength == 0 { break }
        }
        self.converter = nil
    }

    /// 44-byte RIFF header ＋ PCM payload。長度欄位於此刻回填。
    /// **收尾語意**：呼叫前先排空轉換器殘留，故本函式即「定稿」——之後再 append 會重開一段轉換。
    public func wavData() -> Data {
        drain()
        var d = Data(capacity: 44 + pcm.count)
        let dataSize = UInt32(pcm.count)
        let sampleRate = UInt32(Self.outputSampleRate)
        let byteRate = sampleRate * UInt32(Self.bytesPerSample)      // 單聲道

        func append(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)                                   // PCM 的 subchunk1Size
        append16(1)                                    // audioFormat = PCM
        append16(1)                                    // 單聲道
        append32(sampleRate)
        append32(byteRate)
        append16(UInt16(Self.bytesPerSample))          // blockAlign
        append16(16)                                   // bitsPerSample
        append("data")
        append32(dataSize)
        d.append(pcm)
        return d
    }

    /// 排空後把 16k mono PCM16 轉為 `[Float]`（`Int16(littleEndian:)/32768`），供本機 WhisperKit 批次辨識。
    /// **收尾語意同 `wavData()`**：呼叫前先排空轉換器殘留，故本函式即「定稿」——之後再 append 會重開一段轉換。
    public func floatSamples() -> [Float] {
        drain()
        let count = pcm.count / Self.bytesPerSample
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = raw.loadUnaligned(fromByteOffset: i * Self.bytesPerSample, as: Int16.self)
                out[i] = Float(Int16(littleEndian: v)) / 32768.0
            }
        }
        return out
    }
}
