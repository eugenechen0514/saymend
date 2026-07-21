import AVFoundation

/// ASR 事件（規格 §4.2）：volatile 只進 HUD；finalized 才上屏。
public enum TranscriptEvent: Equatable, Sendable {
    case volatile(String)
    case finalized(String)
}

/// AVAudioPCMBuffer 的 Sendable 包裝（單一生產者、單一消費者，不共享可變狀態）
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// ASR 引擎介面（規格 §4.2）。audio 串流 finish＝正常收尾：實作須排空剩餘 finalized 再結束事件串流。
public protocol ASREngine: AnyObject {
    func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent>
    /// 立即取消（Esc）：事件串流盡快結束，可不排空。
    func cancel()
}

/// 麥克風擷取介面
public protocol AudioCaptureService: AnyObject {
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
    /// 音量位準（0...1），供 HUD 波形顯示
    var levelHandler: ((Float) -> Void)? { get set }
}
