import Foundation
import Testing
@testable import SaymendCore

/// 照套件 `AudioStreamTranscriber.startStreamTranscription` 的順序做的假串流轉錄器：
/// 先要權限（會 suspend）、才設 `isRecording = true`、進 `while isRecording` 迴圈。
/// 權限那一步由測試放行，才能讓停止確定落在兩步之間。
/// 每次改 `isRecording` 都經 `onState` 回報，對應套件 `state` 的 `didSet` 呼叫狀態回呼。
private actor FakeStreamer {
    private var isRecording = false {
        didSet { onState(isRecording) }
    }
    private let onState: @Sendable (Bool) -> Void
    private let permission: AsyncStream<Void>
    private let grant: AsyncStream<Void>.Continuation
    private(set) var askingForPermission = false
    private(set) var stops = 0

    init(onState: @escaping @Sendable (Bool) -> Void) {
        self.onState = onState
        (permission, grant) = AsyncStream.makeStream(of: Void.self)
    }

    var recording: Bool { isRecording }

    func start() async {
        guard !isRecording else { return }
        askingForPermission = true
        for await _ in permission { break }
        askingForPermission = false
        isRecording = true
        // 被取消也離開，測試逾時時才收得掉（套件的迴圈則是 `Task.sleep` 擲錯時 break）
        while isRecording, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func grantPermission() { grant.yield() }

    func stop() {
        stops += 1
        isRecording = false
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 條件在期限內成立就回 true。測試裡所有「等到…」都要有期限：變異讓前提失效時，
/// 沒期限的等待會讓整個 suite 掛死，而不是失敗。
private func eventually(within seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// `body` 在期限內做完就回 true；逾時就取消它（`body` 必須理會取消）。
private func finishes(within seconds: Double, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await body(); return true }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// 停止監看（issue #79）。接法與 `WhisperKitModelActor.streamTranscribe` 相同：
/// 狀態回呼把 `isRecording` 記進 `StreamerRecordingBox`，停止監看讀它。
@Suite struct StreamStopWatchTests {
    private let box = StreamerRecordingBox()
    private let stopWanted = Sendable_Flag()
    private let log = Log()

    private func watch(_ streamer: FakeStreamer) -> Task<Void, Never> {
        Task { [box, stopWanted, log] in
            await StreamStopWatch.run(
                shouldStop: { stopWanted.isSet },
                streamerRecording: { box.isRecording },
                beforeFirstStop: { log.add("announce") },
                stop: { attempt in
                    log.add("stop \(attempt)")
                    await streamer.stop()
                },
                pollInterval: .milliseconds(1))
        }
    }

    /// issue #79：模型載完時音訊早已餵完，停止在套件還在要權限時就送出了。那次停止被接下來的
    /// `isRecording = true` 蓋掉，要補送一次才停得下來；沒補的話串流永不結束。
    @Test func aStopThatLandsBeforeTheStreamerStartsRecordingIsSentAgain() async {
        let streamer = FakeStreamer(onState: { [box] in box.record($0) })
        let watcher = watch(streamer)
        let race = Task { [stopWanted] in
            guard await eventually({ await streamer.askingForPermission }) else { return }
            stopWanted.set()                       // 套件還在要權限，使用者早已放開
            guard await eventually({ await streamer.stops == 1 }) else { return }
            await streamer.grantPermission()       // 第一次停止落地之後才開始錄
        }
        let ended = await finishes(within: 2) { await streamer.start() }
        await race.value
        watcher.cancel()

        #expect(ended, "停止被開始錄音蓋掉之後沒有補送，串流永不結束")
        #expect(log.all == ["announce", "stop 1", "stop 2"])
    }

    /// 平常的情況：放開熱鍵時套件早就在錄了，停一次就停下。迴圈離開之後停止監看還會輪詢
    /// 一陣子（等呼叫端取消），這段期間不得再送——每送一次都會觸發狀態回呼、重送同一份進度。
    @Test func aStreamerThatIsAlreadyRecordingIsStoppedOnce() async {
        let streamer = FakeStreamer(onState: { [box] in box.record($0) })
        await streamer.grantPermission()
        let watcher = watch(streamer)
        let release = Task { [box, stopWanted] in
            guard await eventually({ box.isRecording }) else { return }
            stopWanted.set()
        }
        let ended = await finishes(within: 2) { await streamer.start() }
        await release.value
        try? await Task.sleep(for: .milliseconds(30))   // 約 30 次輪詢
        watcher.cancel()

        #expect(ended)
        #expect(log.all == ["announce", "stop 1"])
    }

    /// 沒要求停止就什麼都不做：不報「辨識中…」、不送停止
    @Test func nothingHappensUntilAStopIsWanted() async {
        let streamer = FakeStreamer(onState: { [box] in box.record($0) })
        await streamer.grantPermission()
        let watcher = watch(streamer)
        let started = Task { await streamer.start() }
        let recording = await eventually { box.isRecording }
        try? await Task.sleep(for: .milliseconds(30))   // 約 30 次輪詢

        #expect(recording)
        #expect(log.all.isEmpty)
        #expect(await streamer.stops == 0)

        stopWanted.set()
        let ended = await finishes(within: 2) { await started.value }
        if !ended { started.cancel() }
        watcher.cancel()
        #expect(ended)
    }

    /// 第一次停止不看套件回報的狀態：套件哪天不再經狀態回呼回報 `isRecording`，
    /// 也要至少照舊停一次，而不是退化成永遠不停。
    @Test func theFirstStopIsSentEvenIfTheStreamerNeverReportsRecording() async {
        let streamer = FakeStreamer(onState: { _ in })   // 什麼都不回報
        await streamer.grantPermission()
        let watcher = watch(streamer)
        let release = Task { [stopWanted] in
            guard await eventually({ await streamer.recording }) else { return }
            stopWanted.set()
        }
        let ended = await finishes(within: 2) { await streamer.start() }
        await release.value
        watcher.cancel()

        #expect(ended)
        #expect(log.all == ["announce", "stop 1"])
    }

    /// 呼叫端在串流轉錄器返回後取消停止監看，它就得結束，不能留著輪詢
    @Test func aCancelledWatcherReturns() async {
        let streamer = FakeStreamer(onState: { [box] in box.record($0) })
        let returned = Sendable_Flag()
        let watcher = Task { [box, stopWanted] in
            await StreamStopWatch.run(shouldStop: { stopWanted.isSet },
                                      streamerRecording: { box.isRecording },
                                      beforeFirstStop: {},
                                      stop: { _ in await streamer.stop() },
                                      pollInterval: .milliseconds(1))
            returned.set()
        }
        watcher.cancel()
        #expect(await eventually { returned.isSet })
    }
}
