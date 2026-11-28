import Testing
import SaymendCore
@testable import SaymendApp

/// HUD 與選單列共用同一組狀態文字：同一個狀態只有一種說法，內部術語不上畫面。
@Suite struct StatusTextTests {
    @Test func hotkeyStatesReadTheSameInTheMenuAsInTheHUD() {
        #expect(MenuStatusText.make(.init()) == "待機")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .recording, hotkeyPhase: .listening(.hold))) == "聽寫中")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .recording, hotkeyPhase: .listening(.locked))) == "聽寫中（鎖定）")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .recording, hotkeyPhase: .listening(.hold),
                                          isTargetingSelection: true)) == "改寫選取中")
        #expect(MenuStatusText.make(.init(isLingering: true)) == "可修正（8 秒內可續說／復原）")
        // HUD 用的是同一組字
        #expect(StatusText.listening(locked: true) == "聽寫中（鎖定）")
        #expect(StatusText.lingering == "可修正（8 秒內可續說／復原）")
    }

    /// 迴歸：放開熱鍵後 `phase` 已是 idle，但還在辨識或潤飾——選單列曾顯示「待機」，和 `saymend status` 的
    /// transcribing／polishing 對不上。現在跟著 `activity`（契約的 state 同一個來源）。
    @Test func hotkeyTranscribingAndPolishingFollowTheContractState() {
        #expect(MenuStatusText.make(.init(hotkeyActivity: .transcribing, hotkeyPhase: .idle)) == "辨識中…")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .polishing, hotkeyPhase: .idle)) == "潤飾中…")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .polishing, hotkeyPhase: .idle, isLingering: true)) == "潤飾中…",
                "8 秒可修正期間上一句還在潤飾：契約報 polishing")
        #expect(MenuStatusText.make(.init(hotkeyActivity: .idle, hotkeyPhase: .idle, isLingering: true))
                == "可修正（8 秒內可續說／復原）", "潤飾完、還在 8 秒內")
        // 排隊中且還沒放開：麥克風開著、錄的是新的一段
        #expect(MenuStatusText.make(.init(hotkeyActivity: .recording, hotkeyPhase: .listening(.hold))) == "聽寫中")
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
