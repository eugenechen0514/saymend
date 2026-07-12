import Testing
@testable import SpeeckinkCore

@Test func quietGapEndsUtterance() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    seg.onTranscript(.finalized("你好"), at: 1.0)
    #expect(seg.onTick(at: 2.0) == [])                       // 1.0s < 1.5s
    #expect(seg.onTick(at: 2.6) == [.utteranceEnded(raw: "你好")])
    #expect(seg.onTick(at: 3.0) == [])                       // 已清空不重複
}

@Test func volatileKeepsUtteranceAlive() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    seg.onTranscript(.finalized("第一"), at: 1.0)
    seg.onTranscript(.volatile("第一段還"), at: 2.2)           // 說話中
    #expect(seg.onTick(at: 2.6) == [])                        // gap 從 2.2 起算
    #expect(seg.onTick(at: 3.8) == [.utteranceEnded(raw: "第一")])
}

@Test func multipleFinalizedAccumulate() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    seg.onTranscript(.finalized("你好"), at: 1.0)
    seg.onTranscript(.finalized("，世界"), at: 1.4)
    #expect(seg.onTick(at: 3.0) == [.utteranceEnded(raw: "你好，世界")])
}

@Test func silenceTimeoutFiresAfter60s() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    #expect(seg.onTick(at: 59.0) == [])
    #expect(seg.onTick(at: 60.0) == [.sessionTimedOut])
}

@Test func activityDefersSilenceTimeout() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    seg.onTranscript(.volatile("嗯"), at: 50)
    #expect(seg.onTick(at: 60.0) == [])                       // 50+60=110 才逾時
    let acts = seg.onTick(at: 110.5)
    #expect(acts.contains(.sessionTimedOut))
}

@Test func flushEmitsRemainderAndHardResetDiscards() {
    var seg = UtteranceSegmenter()
    seg.sessionStarted(at: 0)
    seg.onTranscript(.finalized("尾巴"), at: 1.0)
    #expect(seg.flush() == [.utteranceEnded(raw: "尾巴")])
    seg.onTranscript(.finalized("要丟棄"), at: 2.0)
    seg.hardReset()
    #expect(seg.flush() == [])
}
