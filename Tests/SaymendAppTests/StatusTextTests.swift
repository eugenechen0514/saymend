import Testing
import SaymendCore
@testable import SaymendApp

/// HUD 與選單列共用同一組狀態文字：同一個狀態只有一種說法，內部術語不上畫面。
@Suite struct StatusTextTests {
    @Test func hotkeyStatesReadTheSameInTheMenuAsInTheHUD() {
        #expect(MenuStatusText.make(.init()) == "待機")
        #expect(MenuStatusText.make(.init(hotkeyPhase: .listening(.hold))) == "聽寫中")
        #expect(MenuStatusText.make(.init(hotkeyPhase: .listening(.locked))) == "聽寫中（鎖定）")
        #expect(MenuStatusText.make(.init(hotkeyPhase: .listening(.hold), isTargetingSelection: true)) == "改寫選取中")
        #expect(MenuStatusText.make(.init(isLingering: true)) == "可修正（8 秒內可續說／復原）")
        // HUD 用的是同一組字
        #expect(StatusText.listening(locked: true) == "聽寫中（鎖定）")
        #expect(StatusText.lingering == "可修正（8 秒內可續說／復原）")
    }

    @Test func cliStatesUseTheSameWordsWithASourcePrefix() {
        #expect(MenuStatusText.make(.init(cliPhase: .recording)) == "CLI 聽寫中")
        #expect(MenuStatusText.make(.init(cliPhase: .transcribing)) == "CLI 辨識中…")
        #expect(MenuStatusText.make(.init(cliPhase: .polishing, cliOrigin: "devbox")) == "遠端 devbox 潤飾中…")
        #expect(MenuStatusText.make(.init(cliPhase: .recording, hotkeyPhase: .listening(.hold))) == "CLI 聽寫中",
                "CLI 聽寫進行中以它為準")
    }

    /// 內部術語（延續窗、排空、session）與「錄音」不出現在狀態文字裡
    @Test func noInternalJargonOnScreen() {
        let all = [StatusText.idle, StatusText.listening(locked: false), StatusText.listening(locked: true),
                   StatusText.selectionListening, StatusText.lingering, StatusText.transcribing, StatusText.polishing,
                   StatusText.cliListening(loadingModel: true, origin: "x")]
        for text in all {
            for word in ["延續窗", "排空", "session", "錄音"] { #expect(!text.contains(word), "\(text)") }
        }
    }
}
