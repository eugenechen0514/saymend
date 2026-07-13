import Foundation
import Testing
@testable import SpeeckinkCore

@Suite struct AppProfileTests {
    private func makeStore() -> (FileAppProfileStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-\(UUID().uuidString).json")
        return (FileAppProfileStore(fileURL: url), url)
    }

    @Test func unknownBundleGetsBlankProfile() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = store.profile(for: "com.unknown.app")
        #expect(p.bundleID == "com.unknown.app")
        #expect(p.boundsForRangeCapable == nil)      // 未探測＝未知
        #expect(p.vocabEnabled)                      // 預設開
        #expect(!p.cmdCSelectionFallback)            // 預設關（白名單制）
    }

    @Test func builtinDefaultsAreServedForKnownApps() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let slack = store.profile(for: "com.tinyspeck.slackmacgap")
        #expect(slack.extraPrompt?.isEmpty == false)  // 內建庫帶 Slack 口語風格追加 prompt
        let chrome = store.profile(for: "com.google.Chrome")
        #expect(chrome.boundsForRangeCapable == false)  // 內建庫已知 Chrome 網頁區無 BoundsForRange
    }

    @Test func userUpdateOverridesBuiltinAndPersists() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var chrome = store.profile(for: "com.google.Chrome")
        chrome.fixedLanguage = .english
        store.update(chrome)
        let reloaded = FileAppProfileStore(fileURL: url)
        let p = reloaded.profile(for: "com.google.Chrome")
        #expect(p.fixedLanguage == .english)          // 使用者覆寫存活
        #expect(p.boundsForRangeCapable == false)     // 內建欄位一併帶著（update 存整份）
    }

    @Test func capabilityWriteBackPersists() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var p = store.profile(for: "com.apple.TextEdit")
        p.boundsForRangeCapable = true                // 探測結果回填
        store.update(p)
        #expect(FileAppProfileStore(fileURL: url).profile(for: "com.apple.TextEdit").boundsForRangeCapable == true)
    }
}
