import AVFoundation
import Testing
import WhisperKit
@testable import SaymendCore

/// 產生指定格式、指定秒數的非靜音測試 buffer（比照 WAVAccumulatorTests）
private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount,
                        seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            p[i] = sinf(Float(i) * 0.05) * amplitude   // 非靜音，避免轉換器最佳化掉
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

@Test func streamFedSourceEmitsOneEnergyValuePer100ms() throws {
    // 套件的 isVoiceDetected 以 `距上次辨識的秒數 / 0.1` 換算「要看幾格」，
    // 所以一格必須恰好是 100ms。我們的 tap 是 4096 frames ≒ 85ms，格數與時間
    // 的對應會系統性偏掉，因此必須自行重新分桶。
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 16000, channels: 1, seconds: 1.0)))
    // 一秒應約 10 格（重取樣邊界容許 ±1）
    #expect(abs(src.relativeEnergy.count - 10) <= 1)

    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 16000, channels: 1, seconds: 1.0)))
    #expect(abs(src.relativeEnergy.count - 20) <= 1)
}

@Test func streamFedSourceEnergyIsPerChunkNotWholeHistory() throws {
    // **這條是本檔最重要的測試。**
    //
    // 套件對「新到的這一塊」算能量、參考值取最近 20 格的最小平均能量（滾動噪音基準）。
    // 若改成對「整段累積歷史」算，數值會隨 session 拉長收斂成常數——VAD 從此無法區分
    // 講話與停頓，而且長 session 下每次呼叫是 O(n)、總計 O(n²)。
    //
    // 判別方式：用套件自己的函式算出「逐塊語意」的預期值，逐格全等比對。
    // 實作若改成對整段歷史算，數值必然對不上——這是不會被巧合矇混過去的 oracle。
    //
    // 注意 relativeEnergy 量的是「這一塊相對於最近最安靜那塊」，不是絕對音量：
    // 音量均勻時參考值會追上訊號本身、數值趨近 0。它偵測的是**轉變**。
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 16000, channels: 1,
                                                 seconds: 1.0, amplitude: 0.001)))
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 16000, channels: 1,
                                                 seconds: 1.0, amplitude: 0.5)))

    let samples = Array(src.audioSamples)
    let actual = src.relativeEnergy
    let bucketLength = StreamFedAudioSource.energyBufferLength
    #expect(actual.count >= 15)

    // 參考實作：逐塊算、參考值取最近 20 格的最小平均能量（比照套件 processBuffer）
    var expected: [Float] = []
    var avgs: [Float] = []
    for i in 0..<actual.count {
        let lo = i * bucketLength
        let hi = min(lo + bucketLength, samples.count)
        guard lo < hi else { break }
        let bucket = Array(samples[lo..<hi])
        let floor = avgs.suffix(20).reduce(Float.infinity) { min($0, $1) }
        expected.append(AudioProcessor.calculateRelativeEnergy(of: bucket, relativeTo: floor))
        avgs.append(AudioProcessor.calculateEnergy(of: bucket).avg)
    }

    for (i, exp) in expected.enumerated() where !exp.isNaN {
        #expect(abs(actual[i] - exp) < 0.0001,
                "第 \(i) 格能量 \(actual[i]) 與逐塊語意的預期值 \(exp) 不符——實作可能改成對整段歷史算了")
    }

    // 行為面：安靜轉大聲時必須出現明顯尖峰，否則 VAD 偵測不到說話開始
    let quietMax = actual[1..<9].max() ?? 1
    let loudMax = actual[10...].max() ?? 0
    #expect(loudMax > quietMax + 0.3,
            "安靜段最大 \(quietMax)、大聲段最大 \(loudMax)——沒有明顯尖峰，VAD 抓不到說話起點")
}

@Test func streamFedSourceEnergyArrayIsNeverTrimmed() throws {
    // 套件的 relativeEnergy 是 audioEnergy.map { $0.rel }，從不裁剪；
    // isVoiceDetected 依「距上次辨識多久」取 suffix，裁短了它就讀到不足的窗口而誤判。
    // relativeEnergyWindow 在套件裡只用於 debug log 節流，不是裁剪長度。
    let src = StreamFedAudioSource()
    src.relativeEnergyWindow = 20
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 16000, channels: 1, seconds: 5.0)))
    // 5 秒 ≒ 50 格，遠超過 relativeEnergyWindow
    #expect(src.relativeEnergy.count > 40, "能量陣列被裁剪了，實得 \(src.relativeEnergy.count) 格")
}

@Test func streamFedSourceFinishDrainsTheConverter() throws {
    // 不排空的話，每次聽寫尾端會有一小段音訊永遠卡在重取樣器內部進不了 audioSamples
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 44100, channels: 1, seconds: 0.5)))
    let before = src.audioSamples.count
    src.finish()
    // 嚴格遞增：若排空拿不回任何樣本，finish() 就是裝飾品，這條必須紅
    #expect(src.audioSamples.count > before,
            "finish() 後樣本數仍為 \(before)，轉換器沒有排出任何殘留")
}

@Test func streamFedSourceRebuildsConverterWhenSourceFormatChanges() throws {
    // 聽寫途中換音訊裝置：拿舊格式的轉換器餵新格式的 buffer 會失敗或產生垃圾
    let src = StreamFedAudioSource()
    try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 48000, channels: 1, seconds: 0.5)))
    let after48k = src.audioSamples.count
    #expect(after48k > 0)

    #expect(throws: Never.self) {
        try src.append(AudioChunk(buffer: makeBuffer(sampleRate: 44100, channels: 2, seconds: 0.5)))
    }
    #expect(src.audioSamples.count > after48k)          // 新格式的音訊確實有進來
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
