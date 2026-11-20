import Foundation

/// 停止監看（issue #79）：呼叫端要求停止之後，確保套件的串流轉錄器**真的**停下。
///
/// 套件 `AudioStreamTranscriber.startStreamTranscription` 的順序是先
/// `await AudioProcessor.requestRecordPermission()`（macOS 14 起走 `AVAudioApplication`，會真的 suspend），
/// 才設 `isRecording = true`、進 `realtimeLoop`（`while state.isRecording`）。停止若落在這兩步之間，
/// 那次 stop 只是把本來就是 false 的旗標再設一次 false；迴圈開跑之後就再也沒有人叫它停，串流永不結束。
///
/// 模型還在載入時放開熱鍵，必定撞上：`streamTranscribe` 要等模型載完才被呼叫，那時音訊早已餵完，
/// 停止監看第一次檢查就成立，而套件還卡在要權限那一步。
///
/// 所以停過之後不能就走：套件的狀態回呼若又回報正在錄（`isRecording == true`），就再停一次。
/// 第一次停止不看狀態，照舊直接送，套件哪天不再回報 `isRecording` 也不會退化成停不下來。
/// stop 是冪等的（套件只設 `isRecording = false`，我們的 `StreamFedAudioSource.stopRecording` 是空的），
/// 多送無害；但只在真的又開始錄時才補送，避免每次輪詢都觸發一次狀態回呼、重送同一份進度。
enum StreamStopWatch {
    /// 輪詢直到所在的 Task 被取消（呼叫端在串流轉錄器返回後取消）。
    ///
    /// - `shouldStop`：呼叫端是否要求停止。一旦成立應一直成立。
    /// - `streamerRecording`：套件狀態回呼最近一次回報的 `isRecording`。
    /// - `beforeFirstStop`：第一次送停止之前呼叫一次（報「辨識中…」、記下「我們要求了停止」）。
    /// - `stop`：送一次停止；參數是第幾次（從 1 起算），大於 1 就是補送。
    static func run(shouldStop: () -> Bool,
                    streamerRecording: () -> Bool,
                    beforeFirstStop: () -> Void,
                    stop: (_ attempt: Int) async -> Void,
                    pollInterval: Duration = .milliseconds(50)) async {
        var attempts = 0
        while !Task.isCancelled {
            if shouldStop(), attempts == 0 || streamerRecording() {
                if attempts == 0 { beforeFirstStop() }
                attempts += 1
                await stop(attempts)
            }
            try? await Task.sleep(for: pollInterval)
        }
    }
}

/// 套件狀態回呼最近一次回報的 `isRecording`（issue #79）。寫入端是套件 actor 內的狀態回呼，
/// 讀取端是停止監看的 Task，故以鎖保護。
final class StreamerRecordingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func record(_ isRecording: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = isRecording
    }
}
