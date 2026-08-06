import Foundation

/// 斷句器（規格 §3.2／§3.4）：以「轉錄事件靜默 quietGap」切 utterance；
/// 以「無任何活動 silenceTimeout」判定鎖定模式逾時。純值型別＋顯式時間戳，可完全單元測試。
public struct UtteranceSegmenter {
    public enum Action: Equatable, Sendable {
        case utteranceEnded(raw: String)
        case sessionTimedOut
    }

    public let quietGap: TimeInterval
    public let silenceTimeout: TimeInterval

    private var buffer = ""
    private var lastEventAt: TimeInterval?
    private var lastActivityAt: TimeInterval = 0

    public init(quietGap: TimeInterval = 1.5, silenceTimeout: TimeInterval = 60) {
        self.quietGap = quietGap
        self.silenceTimeout = silenceTimeout
    }

    public mutating func sessionStarted(at t: TimeInterval) {
        buffer = ""
        lastEventAt = nil
        lastActivityAt = t
    }

    public mutating func onTranscript(_ event: TranscriptEvent, at t: TimeInterval) {
        lastEventAt = t
        lastActivityAt = t
        if case .finalized(let text, _) = event {
            buffer += text
        }
    }

    public mutating func onTick(at t: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if let last = lastEventAt, !buffer.isEmpty, t - last >= quietGap {
            actions.append(.utteranceEnded(raw: buffer))
            buffer = ""
            lastEventAt = nil
        }
        if t - lastActivityAt >= silenceTimeout {
            actions.append(.sessionTimedOut)
            lastActivityAt = t   // 避免之後每個 tick 重複發
        }
        return actions
    }

    /// session 正常結束時排空殘餘（audio 停止、ASR 串流結束後呼叫）
    public mutating func flush() -> [Action] {
        guard !buffer.isEmpty else { return [] }
        let action = Action.utteranceEnded(raw: buffer)
        buffer = ""
        lastEventAt = nil
        return [action]
    }

    /// Esc 硬取消：丟棄殘餘，flush 不再吐東西
    public mutating func hardReset() {
        buffer = ""
        lastEventAt = nil
    }
}
