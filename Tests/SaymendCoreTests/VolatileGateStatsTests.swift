import Foundation
import Testing
@testable import SaymendCore

/// issue #65 Step 0 量測（計畫 §4.5、裁定 Q7）：`VolatileGateStats` 的純函式，以及 controller 的接線。
/// log 輸出本身不測（os.Logger 沒有可觀察的 seam）；這裡釘的是「記到的數字對」與「記錄本身不可能含文字」。
@Suite struct VolatileGateStatsTests {

    // MARK: - M1：純函式

    @Test func eventsAreBucketedByWholeSecondOfTheirTimestamp() {
        var s = VolatileGateStats()
        for t in [10.1, 10.5, 10.9, 11.0, 12.2, 12.3] { s.recordEvent(at: t) }
        #expect(s.events == 6)
        #expect(s.maxPerSecond == 3, "10.x 秒桶 3 則最多；11.0 屬於下一個桶")
        #expect(s.firstAt == 10.1)
        #expect(s.lastAt == 12.3)
    }

    @Test func gateCallsKeepTheMaximumElapsedTime() {
        var s = VolatileGateStats()
        s.recordGateCall(.milliseconds(1))
        s.recordGateCall(.milliseconds(5))
        s.recordGateCall(.milliseconds(2))
        #expect(s.gateCalls == 3)
        #expect(abs(s.maxGateSeconds - 0.005) < 1e-9)
    }

    @Test func durationConversionKeepsSubSecondPrecision() {
        #expect(abs(VolatileGateStats.seconds(.milliseconds(1500)) - 1.5) < 1e-12)
        #expect(abs(VolatileGateStats.seconds(.microseconds(250)) - 0.00025) < 1e-12)
    }

    /// 隱私不變式（#10）的型別版：每個儲存屬性都只能是數字、Bool 或可選的時間。
    /// 日後有人想「順便記一下最後一則暫時文字」加個 `String` 欄位，這條會擋下來。
    @Test func storedPropertiesCanOnlyHoldNumbersAndFlags() {
        var s = VolatileGateStats()
        s.recordEvent(at: 1.0)
        s.recordGateCall(.milliseconds(1))
        s.noteMasked()
        let offending = Mirror(reflecting: s).children.filter { child in
            !(child.value is Int || child.value is Double || child.value is Bool
              || child.value is Int? || child.value is Double?)
        }
        #expect(offending.isEmpty, "不得出現非數字型別的欄位：\(offending.map { $0.label ?? "?" })")
    }
}

/// controller 的接線：在 `.listening` 相位逐則記事件、只在真的查閘門時記閘門呼叫、遮罩／硬停記旗標，
/// 並在段落結束時歸零（輸出 log 之後）。
@Suite @MainActor struct VolatileGateStatsWiringTests {

    @Test func theControllerCountsEventsAndGateCallsWhileListening() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("U", text: "", subroleUnknown: true, bundleID: "com.slow.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile(""), at: 10.1)        // 事件、不查
        c.handleTranscript(.volatile("一"), at: 10.2)      // 事件、查
        env.focus("U")
        c.handleTranscript(.volatile("一二"), at: 10.4)    // 事件、查 → 遮罩
        c.handleTranscript(.volatile("一二三"), at: 11.1)  // 事件、已遮不查

        #expect(env.fieldGateCalls == 2, "前提：閘門確實查了兩次")
        let s = c.volatileGateStats
        #expect(s.events == 4)
        #expect(s.gateCalls == 2)
        #expect(s.maxPerSecond == 3)
        #expect(s.masked)
        #expect(!s.aborted)
        #expect(s.firstAt == 10.1)
        #expect(s.lastAt == 11.1)
    }

    @Test func theFinishingPhaseIsNotCountedAndAnEmptySegmentIsNotLogged() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.hotkeyReleased(at: 11.0)                         // 排空：本段零事件
        c.handleTranscript(.volatile("x"), at: 11.2)       // 排空窗的暫時文字不算
        #expect(c.volatileGateStats == VolatileGateStats())
        #expect(c.lastFlushedVolatileGateStats == nil, "零事件的段落不輸出")
    }

    @Test func endListeningFlushesAndResets() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.volatile("一"), at: 10.2)
        c.hotkeyReleased(at: 11.0)
        #expect(c.lastFlushedVolatileGateStats?.events == 1)
        #expect(c.lastFlushedVolatileGateStats?.gateCalls == 1)
        #expect(c.volatileGateStats == VolatileGateStats(), "輸出後歸零，下一段從頭算")
    }

    @Test func anAbortOnAVolatileIsFlaggedAndFlushedByTheArchive() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let (c, _, _) = makeStatefulController(env: env)
        c.hotkeyPressed(at: 10.0)
        env.focus("P")
        c.handleTranscript(.volatile("1"), at: 10.2)
        #expect(!c.ledger.isActive, "前提：暫時文字閘門已硬停（archiveSession 已跑）")
        #expect(c.lastFlushedVolatileGateStats?.aborted == true)
        #expect(c.lastFlushedVolatileGateStats?.events == 1)
        #expect(c.volatileGateStats == VolatileGateStats())
    }
}
