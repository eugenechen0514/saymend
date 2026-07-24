import Foundation

/// 可接受詞彙表偏置的 ASR 引擎（spec §4.4）。不併入 ASREngine 協定：
/// 偏置是選配能力，未來若有不支援的引擎仍可實作 ASREngine。
public protocol ContextBiasable: AnyObject {
    var contextualStrings: (@MainActor () -> [String])? { get set }
}

/// ASR 引擎路由（spec §3.3）：start() 時讀一次 kind＝每 session 單一快照，
/// session 中途改設定不影響進行中那句；cancel() 只轉發給 start 當下選定的引擎。
/// 三個子引擎皆實例持有——設定由各自的 configProvider 每次呼叫時讀取，無需重建。
public final class ASREngineRouter: ASREngine, ContextBiasable, @unchecked Sendable {
    private let speechAnalyzer: any ASREngine & ContextBiasable
    private let whisperRemote: any ASREngine & ContextBiasable
    private let whisperLocal: any ASREngine & ContextBiasable
    private let kindProvider: () -> ASREngineKind

    /// 由 App 設在 router 上，start() 時轉發給選定引擎（唯一對外接點）
    public var contextualStrings: (@MainActor () -> [String])?

    private let stateLock = NSLock()
    private var active: (any ASREngine)?

    public init(speechAnalyzer: any ASREngine & ContextBiasable,
                whisperRemote: any ASREngine & ContextBiasable,
                whisperLocal: any ASREngine & ContextBiasable,
                kindProvider: @escaping () -> ASREngineKind) {
        self.speechAnalyzer = speechAnalyzer
        self.whisperRemote = whisperRemote
        self.whisperLocal = whisperLocal
        self.kindProvider = kindProvider
    }

    public func start(audio: AsyncStream<AudioChunk>, localeIdentifier: String) -> AsyncStream<TranscriptEvent> {
        let engine: any ASREngine & ContextBiasable
        switch kindProvider() {                       // 單一快照：本次 session 認定的引擎
        case .speechAnalyzer: engine = speechAnalyzer
        case .whisperRemote:  engine = whisperRemote
        case .whisperLocal:   engine = whisperLocal
        }
        engine.contextualStrings = contextualStrings  // 偏置轉發給選定引擎
        stateLock.lock(); active = engine; stateLock.unlock()
        return engine.start(audio: audio, localeIdentifier: localeIdentifier)
    }

    public func cancel() {
        stateLock.lock()
        let engine = active
        stateLock.unlock()
        engine?.cancel()                              // 尚未 start 時為 nil＝no-op
    }
}
