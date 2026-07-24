import AVFoundation
import Testing
@testable import SaymendCore

/// 產生指定格式、指定秒數的靜音／正弦測試 buffer
private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount,
                        seconds: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            p[i] = sinf(Float(i) * 0.05) * 0.5      // 非靜音，避免轉換器最佳化掉
        }
    }
    return buf
}

private func u32(_ d: Data, _ offset: Int) -> UInt32 {
    d.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
}
private func u16(_ d: Data, _ offset: Int) -> UInt16 {
    d.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
}

@Test func wavHeaderDeclares16kMonoPCM16() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    let wav = acc.wavData()
    #expect(String(data: wav.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
    #expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
    #expect(String(data: wav.subdata(in: 12..<16), encoding: .ascii) == "fmt ")
    #expect(u32(wav, 16) == 16)          // subchunk1Size（PCM）
    #expect(u16(wav, 20) == 1)           // audioFormat = PCM
    #expect(u16(wav, 22) == 1)           // 單聲道
    #expect(u32(wav, 24) == 16000)       // 取樣率
    #expect(u32(wav, 28) == 32000)       // byteRate = 16000 * 1 * 2
    #expect(u16(wav, 32) == 2)           // blockAlign
    #expect(u16(wav, 34) == 16)          // bitsPerSample
    #expect(String(data: wav.subdata(in: 36..<40), encoding: .ascii) == "data")
}

@Test func wavSizeFieldsMatchActualPayload() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    let wav = acc.wavData()
    let dataSize = u32(wav, 40)
    #expect(Int(dataSize) == wav.count - 44)     // data chunk 長度與實際 payload 一致
    #expect(u32(wav, 4) == UInt32(wav.count - 8))// RIFF chunkSize = 檔案長 - 8
}

@Test func resamplesFrom48kTo16kApproximatelyOneThirdSamples() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    // 1 秒 → 16000 樣本 ±2%（轉換器邊界容差）
    #expect(abs(acc.duration - 1.0) < 0.02)
    let samples = (acc.wavData().count - 44) / 2
    #expect(abs(samples - 16000) < 320)
}

@Test func downmixesStereoToMono() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 44100, channels: 2, seconds: 0.5)))
    #expect(u16(acc.wavData(), 22) == 1)          // 立體聲來源仍輸出單聲道
    #expect(abs(acc.duration - 0.5) < 0.02)
}

/// 收尾必須排空轉換器殘留，否則錄音尾端固定被截掉一小段（實測立體聲來源少 356～932 樣本）。
/// 48k 立體聲是麥克風的另一種常見輸出格式，殘留量最大，故以它守住這條線。
@Test func tailIsFlushedFromConverterOnFinalize() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 2, seconds: 1.0)))
    let samples = (acc.wavData().count - 44) / 2
    #expect(abs(samples - 16000) < 320)
    #expect(abs(acc.duration - 1.0) < 0.02)
}

@Test func durationAccumulatesAcrossChunks() throws {
    let acc = WAVAccumulator()
    for _ in 0..<4 {
        try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.25)))
    }
    #expect(abs(acc.duration - 1.0) < 0.05)
}

@Test func resetClearsAccumulation() throws {
    let acc = WAVAccumulator()
    try acc.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    acc.reset()
    #expect(acc.duration == 0)
    #expect(acc.wavData().count == 44)            // 只剩 header
}

@Test func floatSamplesExactCountAfterDrain() throws {
    let acc = WAVAccumulator()
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    let n = AVAudioFrameCount(24000)   // 0.5 秒 @48k
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
    for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0.5 }
    try acc.append(AudioChunk(buffer: buf))
    let s = acc.floatSamples()
    #expect(s.count == 8000)                       // 精確；漏排空必紅
    #expect(s.allSatisfy { $0 >= -1.0 && $0 < 1.0 })
    #expect((s.dropFirst(100).first ?? 0) > 0.45)
}
