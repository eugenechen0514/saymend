import Testing
import Foundation
@testable import SaymendCore

@Suite struct AppSettingsWhisperLocalTests {
    @Test func whisperLocalConfigRoundTrips() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.whisperLocalConfig().selectedModelPath == nil)
        let p = URL(filePath: "/tmp/openai_whisper-tiny")
        s.whisperLocalModelPath = p
        #expect(s.whisperLocalConfig().selectedModelPath == p)
    }

    @Test func whisperLocalScanRootsRoundTrip() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.whisperLocalConfig().extraScanRoots.isEmpty)
        let roots = [URL(filePath: "/tmp/models-a"), URL(filePath: "/tmp/models-b")]
        s.whisperLocalScanRoots = roots
        #expect(s.whisperLocalConfig().extraScanRoots == roots)
    }
    // MARK: - 聽寫等待模型的上限（issue #17）

    @Test func modelWaitTimeoutDefaultsTo15() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: d).whisperModelWaitTimeout == 15)
        #expect(AppSettings(defaults: d).whisperLocalConfig().modelWaitTimeout == 15)
    }

    @Test func modelWaitTimeoutRoundTrips() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.whisperModelWaitTimeout = 42
        #expect(s.whisperModelWaitTimeout == 42)
        #expect(s.whisperLocalConfig().modelWaitTimeout == 42)      // 真的接到引擎讀的那條路上
        #expect(AppSettings(defaults: d).whisperModelWaitTimeout == 42)   // 重讀仍在
    }

    /// 超界**回落預設而非夾到邊界**（比照 `readInt`／`readTimeout` 的既有紀律）：
    /// 邊界是使用者從未選過的值，預設才是已知良好的那個。
    @Test func modelWaitTimeoutOutOfRangeFallsBackToDefault() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.whisperModelWaitTimeout = 4                    // < 下限 5
        #expect(s.whisperModelWaitTimeout == 15)
        s.whisperModelWaitTimeout = 601                  // > 上限 600
        #expect(s.whisperModelWaitTimeout == 15)
    }

    /// 邊界值本身要收得下——夾制寫成開區間會讓使用者選得到卻存不進去。
    @Test func modelWaitTimeoutAcceptsTheBounds() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.whisperModelWaitTimeout = AppSettings.modelWaitTimeoutRange.lowerBound
        #expect(s.whisperModelWaitTimeout == 5)
        s.whisperModelWaitTimeout = AppSettings.modelWaitTimeoutRange.upperBound
        #expect(s.whisperModelWaitTimeout == 600)
    }

    /// 型別不符（別的程式寫了字串進去）也要回落，不得當機。
    @Test func modelWaitTimeoutWrongTypeFallsBackToDefault() {
        let d = UserDefaults(suiteName: "wl-\(UUID().uuidString)")!
        d.set("十五秒", forKey: "whisperModelWaitTimeout")
        #expect(AppSettings(defaults: d).whisperModelWaitTimeout == 15)
    }
}
