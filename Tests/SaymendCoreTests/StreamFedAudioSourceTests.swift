import AVFoundation
import Testing
import WhisperKit
@testable import SaymendCore

/// 產生指定格式、指定秒數的非靜音測試 buffer（比照 WAVAccumulatorTests）
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

@Test func streamFedSourceAccumulatesAt16kMono() throws {
    let src = StreamFedAudioSource()
    #expect(src.audioSamples.isEmpty)

    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    // 48k→16k：一秒約 16000 個樣本（轉換器邊界容許少量誤差）
    #expect(abs(src.audioSamples.count - 16_000) < 500)

    let afterFirst = src.audioSamples.count
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))
    #expect(src.audioSamples.count > afterFirst)          // 依序累積，不是覆蓋
    #expect(abs(src.audioSamples.count - 32_000) < 1_000)
}

@Test func streamFedSourceConvertsStereoAndNonStandardRates() throws {
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 44100, channels: 2, seconds: 0.5)))
    // 44.1k 立體聲 → 16k 單聲道：半秒約 8000 個樣本。
    // 容差放寬到 1000：44100/16000 不是整數比，重取樣濾波器有一次性的 priming 延遲
    // （實測約 576 個樣本 ≒ 36ms）。真正該擔心的是「每個 buffer 都掉」，見下一條測試。
    #expect(abs(src.audioSamples.count - 8_000) < 1_000)
}

@Test func streamFedSourceDoesNotLoseFramesOnEveryChunk() throws {
    // 轉換器的 priming 損失必須是**一次性**的。若每個 chunk 都掉 36ms，
    // 連續說話的音訊會被切得斷斷續續，辨識品質崩壞——而且從單一 chunk 的測試看不出來。
    let src = StreamFedAudioSource()
    var counts: [Int] = []
    for _ in 0..<6 {
        try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 44100, channels: 2, seconds: 0.5)))
        counts.append(src.audioSamples.count)
    }
    // 逐次增量會抖動（實測在 7430 與 9024 之間交替）——重取樣器內部緩衝不完整的 frame，
    // 下一次補吐出來。這是正常的，不該對單次增量設緊容差。
    //
    // 真正要鎖的是「誤差有界、不隨 chunk 數累積」：每一個累計點的偏差都不得超過
    // 一次 priming 的量級。若每個 chunk 都固定掉 36ms，偏差會隨 N 線性成長。
    // 實測缺口在 576→1146→122→692→1262→238 之間週期震盪（44100/16000 = 2.75625
    // 不是整數比，轉換器的內部緩衝形成週期）。界線取 2000：足以容納這個震盪，
    // 但若真的每個 chunk 都固定掉 576，第 6 個時缺口會累積到 3456 而被抓出來。
    for (i, total) in counts.enumerated() {
        let expected = (i + 1) * 8_000
        #expect(abs(total - expected) < 2_000,
                "第 \(i + 1) 個 chunk 後累計 \(total)，理論 \(expected)——偏差隨 chunk 數成長代表在持續掉樣本")
    }
}

@Test func streamFedSourceNeverShrinks() throws {
    // 串流轉錄器以絕對索引記帳（新增量＝目前長度－上次長度、解碼起點為絕對秒數），
    // 樣本一旦被清理，那兩個記帳會同時失效。故本型別**不得**自行縮短陣列。
    let src = StreamFedAudioSource()
    var lengths: [Int] = []
    for _ in 0..<5 {
        try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.5)))
        lengths.append(src.audioSamples.count)
    }
    #expect(lengths == lengths.sorted())                  // 單調遞增
    #expect(Set(lengths).count == lengths.count)          // 每次都真的變長

    // 協定要求的清理方法必須存在，但在本用法下必須是無操作
    let before = src.audioSamples.count
    src.purgeAudioSamples(keepingLast: 10)
    #expect(src.audioSamples.count == before)
}

@Test func streamFedSourceReportsWhenOverDurationCap() throws {
    // 上限是「失控 session 的安全網」，不是正常使用的限制：超過時要明確回報，
    // 不可靜默截斷（截斷＝破壞單調遞增）也不可無限成長。
    let src = StreamFedAudioSource(maxDuration: 1.0)
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.6)))
    #expect(!src.isOverCapacity)

    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.6)))
    #expect(src.isOverCapacity)                           // 累計 1.2 秒 > 1.0 秒上限
    #expect(src.audioSamples.count > 0)                   // 已收的音訊不得被丟棄
}

@Test func streamFedSourceEnergyMatchesPackageStaticFunction() throws {
    // 語音活動偵測完全依賴這個數值。自行實作會與套件原生行為漂移，且極難察覺——
    // 故必須逐值等同套件的公開靜態函式。
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 1.0)))

    #expect(!src.relativeEnergy.isEmpty)
    let samples = Array(src.audioSamples)
    let expected = AudioProcessor.calculateRelativeEnergy(of: samples, relativeTo: nil)
    // 最後一格能量由整段樣本算出，應與套件靜態函式一致
    #expect(abs((src.relativeEnergy.last ?? .nan) - expected) < 0.0001)
}

@Test func streamFedSourceRecordingLifecycleIsNoOp() throws {
    // 麥克風由既有的音訊管線持有；這些方法被套件呼叫時不得嘗試開啟裝置。
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.2)))
    let before = src.audioSamples.count

    #expect(throws: Never.self) {
        try src.startRecordingLive(inputDeviceID: nil, callback: nil)
        try src.resumeRecordingLive(inputDeviceID: nil, callback: nil)
    }
    src.pauseRecording()
    src.stopRecording()

    #expect(src.audioSamples.count == before)             // 生命週期方法不得動到已收的樣本
}

@Test func streamFedSourceEmptyChunkIsIgnored() throws {
    let src = StreamFedAudioSource()
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                            channels: 1, interleaved: false)!
    let empty = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 128)!
    empty.frameLength = 0
    try src.append(AudioChunk(buffer: empty))
    #expect(src.audioSamples.isEmpty)
}
