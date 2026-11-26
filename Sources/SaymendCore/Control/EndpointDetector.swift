import AVFoundation
import Foundation
import SaymendControl

/// 音量位準（0...1）。刻度與 `AudioCapture.rmsLevel`（HUD 音量條）相同：`min(1, rms × 20)`。
/// 放在 Core 是為了讓 CLI 聽寫的 end-of-speech 判斷可以在測試裡餵合成音訊。
public enum AudioLevelMeter {
    public static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0..<n {
                let s = Float(data[i]) / Float(Int16.max)
                sum += s * s
            }
        } else {
            return nil
        }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 20)
    }
}

/// CLI 聽寫的端點判斷：什麼時候算「開始說話」、什麼時候算「說完了」。純值型別＋顯式時間戳，可完全單元測試。
///
/// **聲學判斷為主**：位準連續高於門檻 `speechConfirmDuration` 才算開口（擋掉咳嗽、敲桌一下），
/// 之後位準低於門檻連續達 `--silence-ms` 就算說完。辨識引擎吐出**新增的**文字也算開口與「還在講」
/// ——小聲說話時位準可能擦邊，但辨識器聽得懂；只認「文字變長」，因為 Whisper 串流在靜音中也會
/// 反覆改寫同一段暫時文字，那不是有人在講話。
///
/// **門檻隨環境噪音浮動**：`max(minimumSpeechLevel, noiseFloor × noiseMultiplier)`，吵雜環境才不會
/// 「一開麥就算開口、永遠不算說完」。噪音底線以第一個樣本起算、往下立即跟；往上只讓**低於門檻**的樣本
/// 正常拉（`noiseRiseRate`），高於門檻的樣本（多半是說話）只能極慢地推（`noiseCreepRate`）——
/// 否則一口氣講十秒，底線會被自己的聲音抬上去、話沒講完就被判成靜音。
/// 一開麥就在講話（第一個樣本就是人聲）時門檻會暫時偏高，第一個停頓就會把底線拉回環境音。
public struct EndpointDetector: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        /// 位準下限：再安靜的環境，低於它都算靜音（AudioLevelMeter 刻度；0.08 ≈ RMS 0.004 ≈ −48 dBFS）
        public var minimumSpeechLevel: Float
        public var noiseMultiplier: Float
        /// 連續高於門檻多久才認定開口
        public var speechConfirmDuration: TimeInterval
        /// 低於門檻的樣本把噪音底線往上拉的比例（音訊約每 0.1 秒一個樣本 → 時間常數約 2 秒）
        public var noiseRiseRate: Float
        /// 高於門檻的樣本把底線往上推的比例（時間常數約 50 秒：只為了吸收中途才出現的持續噪音）
        public var noiseCreepRate: Float

        public init(minimumSpeechLevel: Float = 0.08, noiseMultiplier: Float = 2.5,
                    speechConfirmDuration: TimeInterval = 0.25,
                    noiseRiseRate: Float = 0.05, noiseCreepRate: Float = 0.002) {
            self.minimumSpeechLevel = minimumSpeechLevel
            self.noiseMultiplier = noiseMultiplier
            self.speechConfirmDuration = speechConfirmDuration
            self.noiseRiseRate = noiseRiseRate
            self.noiseCreepRate = noiseCreepRate
        }
    }

    public enum Decision: Equatable, Sendable {
        case keepListening
        /// 開口之後連續靜音達 `silenceMs`：正常定稿
        case endOfSpeech
        /// 達 `maxSeconds`：正常定稿
        case maxDuration
        /// `noSpeechSeconds` 內完全沒開口：放棄（exit 6）
        case noSpeech
    }

    public let config: Config
    public let startedAt: TimeInterval
    public private(set) var speechDetected = false
    public private(set) var noiseFloor: Float?
    /// 開口之後最後一次「有人在講」的時間（位準高於門檻，或辨識文字變長）
    public private(set) var lastSpeechAt: TimeInterval?
    private var aboveSince: TimeInterval?

    public init(startedAt: TimeInterval, config: Config = Config()) {
        self.startedAt = startedAt
        self.config = config
    }

    public var threshold: Float {
        max(config.minimumSpeechLevel, (noiseFloor ?? 0) * config.noiseMultiplier)
    }

    public mutating func ingestLevel(_ level: Float, at t: TimeInterval) {
        // 門檻用「這個樣本進來之前」的底線算：不讓說話中的樣本先把自己的門檻抬高。
        let gate = threshold
        if level >= gate {
            if aboveSince == nil { aboveSince = t }
            if !speechDetected, let since = aboveSince, t - since >= config.speechConfirmDuration {
                speechDetected = true
            }
            if speechDetected { lastSpeechAt = t }
        } else {
            aboveSince = nil
        }
        if let floor = noiseFloor {
            if level < floor {
                noiseFloor = level
            } else {
                let rate = level >= gate ? config.noiseCreepRate : config.noiseRiseRate
                noiseFloor = floor + (level - floor) * rate
            }
        } else {
            noiseFloor = level
        }
    }

    /// 辨識器吐出新增的文字：等同聽到有人在講。
    public mutating func noteTranscriptActivity(at t: TimeInterval) {
        speechDetected = true
        lastSpeechAt = t
    }

    public func decision(at t: TimeInterval, options: DictateOptions) -> Decision {
        let elapsed = t - startedAt
        if elapsed >= options.maxSeconds { return .maxDuration }
        if !speechDetected, options.noSpeechSeconds > 0, elapsed >= options.noSpeechSeconds { return .noSpeech }
        if speechDetected, options.silenceMs > 0, let last = lastSpeechAt,
           t - last >= Double(options.silenceMs) / 1000 {
            return .endOfSpeech
        }
        return .keepListening
    }
}
