import Foundation

/// 收尾補解碼（issue #22）：串流結束時，從已定稿片段的結束點重解到音訊結尾，
/// 把**從來沒進過解碼器**的尾端一起解進來。
///
/// **為什麼會有沒解過的尾端**：套件的串流轉錄器每一趟先記下樣本數（`lastBufferSize`），
/// 再從已定稿片段的結束點解到那個位置為止。`stopStreamTranscription` 只把迴圈旗標關掉，
/// 正在跑的那一趟做完就離開，**那一趟取樣點之後進來的音訊不會再有下一趟**。
/// 一趟要多久，尾端就掉多少：實機 2026-08-19 量到 large-v3_turbo 一趟平均 6.28 秒，
/// 48 秒的朗讀有約 9.9 秒從頭到尾沒被解碼。小模型一趟較短，但講到最後一刻才放開熱鍵時也會掉
/// （合成語音實測：small 即時餵 24 秒的朗讀，最後約 0.7 秒沒被解碼）。
///
/// **補解碼的窗口與套件每一趟相同**：從已定稿片段的結束點解到音訊結尾。結果取代最後一趟的
/// 暫時文字，再交給引擎的收尾補發（`WhisperKitEngine.flushTail`）轉正。定稿文字不動。
///
/// 本型別只放**決策**（要不要補、補哪一段、結果怎麼併）。真正的解碼要載入模型，
/// 在 `WhisperKitModelActor.streamTranscribe` 裡以 closure 傳進 `run`。
enum StreamTailDrain {
    /// 串流轉錄器的記帳，取自它的狀態變更回呼。
    ///
    /// `decodedSamples` 與 `confirmedEndSeconds` 只增不減（套件的語意），而 `plan` 判定時的音訊總長與
    /// 能量已經是最終值（停止監看要等 `audioDone`，那是在 `StreamFedAudioSource.finish()` 之後才設的）。
    /// 所以沒解過的長度、窗口、要看的格數只會變少：**停止那一刻說不用補，之後也不會要補**。
    /// `lastProgress` 不在此列，`plan` 也不看它。
    struct Ledger: Equatable, Sendable {
        /// 最後一趟解碼開始時的樣本數（套件的 `State.lastBufferSize`）：之後的樣本都沒解過
        var decodedSamples: Int = 0
        /// 已定稿片段的結束秒數（套件的 `State.lastConfirmedSegmentEndSeconds`）：每一趟都從這裡解起
        var confirmedEndSeconds: Float = 0
        /// 最後一則進度：補解碼的結果沿用它的定稿部分
        var lastProgress: WhisperStreamProgress?
    }

    /// 要補解碼的那一段。秒數都從串流起點算。
    struct Tail: Equatable, Sendable {
        /// 解碼起點（＝已定稿片段的結束點，交給套件的 `clipTimestamps`）
        let clipStartSeconds: Float
        /// 從沒解過的那段有多長（只供 log）
        let undecodedSeconds: Double
        /// 這次要解的窗口有多長（只供 log）
        let windowSeconds: Double
    }

    /// 補解碼的結果（只供 log；使用者看得到的效果全在 `emit` 出去的進度裡）
    enum Outcome: Equatable, Sendable {
        /// 解出文字並已交出去
        case drained
        /// 解碼成功但沒有文字：沿用最後一趟的暫時文字
        case emptyResult
        /// 解碼擲錯：沿用最後一趟的暫時文字。原因只記錯誤本身的描述（模型錯誤，不含任何辨識文字），供回查
        case failed(reason: String)
        /// 解碼期間被取消（Esc）：什麼都不交
        case cancelled
    }

    /// 補解碼得到的一個片段。不直接用套件的 `TranscriptionSegment`，本型別才測得到。
    struct DrainedSegment: Equatable, Sendable {
        let text: String
        let quality: TranscriptSegmentQuality
        init(text: String, quality: TranscriptSegmentQuality) {
            self.text = text
            self.quality = quality
        }
    }

    /// 解碼窗口的下限（秒），**窗口要超過它才補**。
    ///
    /// 這不是我們訂的門檻，是對齊套件解碼器本身的下限：`TranscribeTask.run` 的迴圈條件是
    /// `seek < seekClipEnd - windowPadding`，`windowPadding` 取自 `DecodingOptions.windowClipTime`
    /// （預設 1 秒，用來避免片尾幻覺）。窗口不超過它，解碼器一個窗口都不會解、結果必定是空的——
    /// 照樣補的話，只會讓 HUD 白顯示一段「辨識中…」。
    /// 抄來的值會過期：`drainWindowFloorMatchesWhisperKit` 釘住它與套件預設一致。
    ///
    /// 附帶的效果：不到 1 秒的 session 照舊一個字都不出（套件一趟都沒解過，現況就是如此）。
    static let minimumWindowSeconds: Double = 1.0

    /// 要不要補解碼；要的話回傳要解的那一段。
    ///
    /// **有聲判定刻意不用套件的 `AudioProcessor.isVoiceDetected`**。那個函式只看新音訊的前段
    /// （`prefix(max(10, n - 10))`）：新音訊超過 1 秒時，最後最多 1 秒不看，因為串流中下一趟還會看到。
    /// 收尾沒有下一趟：講到最後一刻才放開時，聲音正好落在它不看的那一段。
    ///
    /// 這裡改成沒解過的每一格都看。能量格從第 0 個樣本起每 `energyBufferLength` 個一格
    /// （最後不足一格的殘量由 `StreamFedAudioSource.finish` 結算成一格），所以從
    /// 「沒解過的第一個樣本所在的那一格」看到最後一格。
    static func plan(ledger: Ledger,
                     totalSamples: Int,
                     relativeEnergy: [Float],
                     useVAD: Bool,
                     silenceThreshold: Float,
                     sampleRate: Double = StreamFedAudioSource.sampleRate) -> Tail? {
        let undecoded = totalSamples - ledger.decodedSamples
        guard undecoded > 0 else { return nil }
        let window = Double(totalSamples) / sampleRate - Double(ledger.confirmedEndSeconds)
        guard window > minimumWindowSeconds else { return nil }
        if useVAD {
            let firstUndecodedBucket = ledger.decodedSamples / StreamFedAudioSource.energyBufferLength
            guard relativeEnergy.dropFirst(firstUndecodedBucket).contains(where: { $0 > silenceThreshold }) else {
                return nil
            }
        }
        return Tail(clipStartSeconds: ledger.confirmedEndSeconds,
                    undecodedSeconds: Double(undecoded) / sampleRate,
                    windowSeconds: window)
    }

    /// 補解碼的結果併成最後一則進度：定稿沿用最後一趟，暫時文字換成補解碼的結果。
    ///
    /// 沒有文字就回 nil，**沿用最後一趟的暫時文字**。補解碼的窗口涵蓋最後一趟解過的範圍，
    /// 照理結果至少不比它短；真的解出空白時無從判斷誰對，寧可留著已經在 HUD 上給使用者
    /// 看過的那段，也不要把它清掉（與 `WhisperKitEngine.newlyConfirmed` 寧可重覆不要漏字同一取捨）。
    static func progress(after ledger: Ledger, drained: [DrainedSegment]) -> WhisperStreamProgress? {
        let text = drained.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WhisperStreamProgress(confirmed: ledger.lastProgress?.confirmed ?? "",
                                     unconfirmed: text,
                                     confirmedQuality: ledger.lastProgress?.confirmedQuality ?? [],
                                     unconfirmedQuality: drained.map(\.quality))
    }

    /// 執行補解碼。`decode` 收解碼起點、回傳片段；呼叫端負責真正的模型呼叫。
    ///
    /// **失敗不升級成串流失敗**：定稿文字早已上屏，把整段聽寫判成失敗只會讓使用者以為全沒了。
    /// 補不成就退回原本的行為（最後一趟的暫時文字照常補發），並交由呼叫端記 log。
    ///
    /// `isolation` 讓 `decode` 在呼叫端的隔離域執行：模型元件不是 Sendable，
    /// 呼叫端（`WhisperKitModelActor`）不能把它們交給別的隔離域。
    static func run(_ tail: Tail,
                    ledger: Ledger,
                    isolation: isolated (any Actor)? = #isolation,
                    isCancelled: () -> Bool = { Task.isCancelled },
                    decode: (Float) async throws -> [DrainedSegment],
                    emit: (WhisperStreamProgress) -> Void) async -> Outcome {
        let drained: [DrainedSegment]
        do {
            drained = try await decode(tail.clipStartSeconds)
        } catch {
            return isCancelled() ? .cancelled : .failed(reason: String(describing: error))
        }
        if isCancelled() { return .cancelled }
        guard let progress = progress(after: ledger, drained: drained) else { return .emptyResult }
        emit(progress)
        return .drained
    }
}
