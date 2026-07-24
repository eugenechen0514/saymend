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
}
