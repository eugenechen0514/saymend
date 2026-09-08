import Foundation
import Testing
@testable import SaymendCore

/// issue #37 的保險絲 `rawAppendGateEnabled`（defaults-only，**沒有 UI**）。
///
/// 存在的理由是**誤判率未知**：`CFEqual` 在真實 App 上把同一欄位判成兩個 element 的機率
/// 沒有實測數據。若偏高，使用者會看到一連串不該出現的跳過，而在這個開關之前沒有任何辦法關掉。
///
/// 保險絲的邊界是本檔案最要緊的一條：**它只能燒掉 `.different` 的攔阻，不能燒掉密碼欄位保護**。
/// 規格 §5.3 是硬規則，不是可調參數。政策因此寫在 `InsertionCoordinator.focusGateBlock()`
/// 而不是接線用的 closure——放在 coordinator 才有下面這些單元測試可釘。
///
/// 密碼欄位那半在 issue #63 之後是**硬停**（archive session、notice「密碼欄位不聽寫」、
/// 不救剪貼簿、診斷只留 metadata），不是「跳過這句」。所以下面的邊界測試不只斷言「沒寫進欄位」，
/// 還要斷言被擋片段**沒有流到雲端 provider 與 history**——「不寫就滿足 §5.3」是被否決的舊判斷。
@Suite @MainActor struct RawAppendGateSwitchTests {

    private func notices(_ hud: FakeHUD) -> [String] {
        hud.states.compactMap { if case .notice(let s) = $0 { return s }; return nil }
    }

    private func skipEvents(_ history: FakeHistory) -> [HistoryExchangeRecord] {
        history.exchanges.filter { $0.outcomeKind == "insertSkipped" }
    }

    // MARK: - coordinator 單元：開關對兩種閘門結果的不對稱效果

    /// 關閉時 `.different` 視同 `.unknown`：照常寫、鏡像照常前進。
    @Test func disablingTheGateLetsADifferentFieldAppendAsUsual() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .different(currentAppBundleID: "com.other.app") },
                                     gateEnabled: { false })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("照常") == .inserted)
        #expect(try c.insertDetached("也照常") == .inserted)
        #expect(key.ops == [.insert("照常"), .insert("也照常")])
        #expect(c.displayedText == "照常也照常", "關閉＝退回 #21 的舊行為，鏡像照常前進")
    }

    /// **本檔案最重要的一對之一**：保險絲燒不到 AX 明說的密碼欄位。
    /// 關閉開關 ＋ 閘門回 `.secure` → 仍然一個字都不寫、仍然回 `.secureField(subroleUnknown: false)`。
    /// 這條若紅，代表保險絲把規格 §5.3 一起關掉了——那是資安問題，不是行為調整。
    @Test func disablingTheGateStillBlocksSecureFields() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .secure },
                                     gateEnabled: { false })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("不該寫") == .secureField(subroleUnknown: false),
                "保險絲不得節制 .secure")
        #expect(try c.insertDetached("也不該寫") == .secureField(subroleUnknown: false))
        #expect(key.ops.isEmpty, "密碼欄位一個字都不能進")
        #expect(paste.ops.isEmpty)
        #expect(c.displayedText == "", "鏡像不得前進")
    }

    /// **另一半**：`.secureUnknown`（AX 問不出 subrole，fail closed 當作是）同樣不受保險絲節制。
    /// 兩種形態要各釘一條——只釘 `.secure` 的話，「保險絲順手把 fail-closed 那半關掉」不會被抓到，
    /// 而那正是誤判率最高、最想被「關掉」的一格（0.2s AX timeout，issue #59）。
    @Test func disablingTheGateStillBlocksSubroleUnknownFields() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .secureUnknown },
                                     gateEnabled: { false })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("不該寫") == .secureField(subroleUnknown: true),
                "保險絲不得節制 .secureUnknown，且必須保住 subroleUnknown 這格 metadata")
        #expect(try c.insertDetached("也不該寫") == .secureField(subroleUnknown: true))
        #expect(key.ops.isEmpty)
        #expect(paste.ops.isEmpty)
        #expect(c.displayedText == "")
    }

    /// 開啟（或沒接開關）時 `.different` 照擋——保險絲的預設不得把閘門變成裝飾。
    @Test func theGateStillBlocksWhenTheSwitchIsOnOrAbsent() throws {
        for (label, enabled): (String, (() -> Bool)?) in [("開關開啟", { true }), ("沒接開關（nil）", nil)] {
            let key = RecordingInserter(), paste = RecordingInserter()
            let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                         fieldGate: { _ in .different(currentAppBundleID: "com.other.app") },
                                         gateEnabled: enabled)
            c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
            // 兩格都帶 label：否則其中一格壞掉時，失敗訊息長得一模一樣、分不出是哪一格。
            #expect(try c.insertFinalized("不該寫") == .fieldChanged(currentAppBundleID: "com.other.app"),
                    "\(label)：閘門必須照擋")
            #expect(key.ops.isEmpty, "\(label)：一個字都不能寫")
        }
    }

    /// 開關是每次寫入前現讀，不是建構當下快照——使用者 `defaults write` 之後不必重開 App。
    @Test func theSwitchIsReadOnEveryWriteNotCapturedOnce() throws {
        let key = RecordingInserter(), paste = RecordingInserter()
        var enabled = true
        let c = InsertionCoordinator(keystroke: key, paste: paste, pasteThreshold: 100,
                                     fieldGate: { _ in .different(currentAppBundleID: "com.other.app") },
                                     gateEnabled: { enabled })
        c.beginSession(anchor: 0, identity: FieldIdentity(token: 1))
        #expect(try c.insertFinalized("擋下") == .fieldChanged(currentAppBundleID: "com.other.app"))
        enabled = false
        #expect(try c.insertFinalized("放行") == .inserted)
        #expect(key.ops == [.insert("放行")])
    }

    // MARK: - controller 端到端：關閉後使用者看得到什麼

    /// 關閉後 `.different` 完全回到閘門之前的世界：文字照常進（現在聚焦的）欄位、
    /// 零 notice、零剪貼簿、零 `insertSkipped` 診斷。
    /// 「零診斷」這條特別重要：關掉的是攔阻，遙測若還照記，之後算誤判率會把沒發生的跳過算進去。
    @Test func withTheSwitchOffAChangedFieldProducesNoNoticeRescueOrDiagnostic() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.focus("B")
        c.handleTranscript(.finalized("第二句"), at: 11.0)

        #expect(env.text(in: "B") == "第二句", "關閉＝照常寫（等同 .unknown），字落在現在聚焦的欄位")
        #expect(env.text(in: "A") == "第一句")
        #expect(notices(hud).isEmpty, "零 notice")
        #expect(clipboard.texts.isEmpty, "零剪貼簿救援")
        #expect(skipEvents(history).isEmpty, "零 insertSkipped 診斷")
        #expect(c.ledger.isActive, "`.different` 不封存（裁定 Q2）；關掉開關更不該封存")
    }

    /// 保險絲邊界的端到端版本：關閉開關之後，切進密碼欄位**仍然硬停**。
    ///
    /// 斷言刻意不只看「欄位沒被寫」——issue #63 的教訓是：光「不寫」滿足不了 §5.3，
    /// 被擋片段在 `segmenter.onTranscript` 就已進 buffer，session 不停就會把整句 raw
    /// 送雲端 provider、並讓潤飾全文經 `dispatch` 頂端無條件的 `recordExchange` 落進 history。
    /// 所以這裡連 `polisher.calls` 與 `history.exchanges` 一起釘。
    @Test func withTheSwitchOffASecureFieldStillHardStopsTheSession() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("第一句這段不可上屏。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        #expect(!c.settings.rawAppendGateEnabled,
                "前提：開關真的關掉了。少了這條，接線一斷本測試會靜默退化成既有硬停測試的重複")
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("P")                                  // controller 守衛答完之後才切進密碼欄
        }
        c.handleTranscript(.finalized("這段不可上屏"), at: 10.8)
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "P") == "", "保險絲關掉的是換欄位的攔阻，不是密碼欄位保護")
        #expect(!c.ledger.isActive, "仍然硬停：保險絲不管 session 生命週期")
        #expect(notices(hud).last == "密碼欄位不聽寫")
        #expect(!polisher.calls.contains { $0.raw.contains("這段不可上屏") },
                "關掉開關也不得讓被擋片段送進雲端 provider；實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("這段不可上屏") || ($0.outcomeText?.contains("這段不可上屏") ?? false)
        }, "history_exchange 任何一列都不得含被擋片段；實際：\(history.exchanges)")
        #expect(env.text(in: "A") == "第一句", "被擋片段不得經 outcome 繞回原欄位")
        #expect(!clipboard.texts.contains("這段不可上屏"), "硬停不救剪貼簿（剪貼簿是另一個持久容器）")
        #expect(skipEvents(history).last?.outcomeText == "secureField")
        #expect(skipEvents(history).last?.utteranceRaw == "", "只留 metadata，不留句子")
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("這段不可上屏") },
                "asr_diagnostic 是**另一張**明文表：`.secureField` 那條終點刻意不記，保險絲關閉時也不得因此多記一列；實際：\(history.diagnostics.map(\.finalizedText))")
    }

    /// 同上的 `.secureUnknown` 版：`subroleUnknown` 那格 metadata 在開關關閉時也必須留著，
    /// 否則 0.2s AX timeout 的誤殺率永遠量不出來（issue #59）——而「想關掉閘門」的使用者
    /// 正是最可能踩到那格的人，這裡的樣本反而最有價值。
    @Test func withTheSwitchOffASubroleUnknownFieldStillHardStops() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("Q", text: "", subroleUnknown: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("第一句這段不可上屏。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        #expect(!c.settings.rawAppendGateEnabled,
                "前提：開關真的關掉了。少了這條，接線一斷本測試會靜默退化成既有硬停測試的重複")
        c.hotkeyPressed(at: 10.0)
        c.handleTranscript(.finalized("第一句"), at: 10.5)
        env.afterFieldGate = { [weak env] in
            env?.afterFieldGate = nil
            env?.focus("Q")
        }
        c.handleTranscript(.finalized("這段不可上屏"), at: 10.8)
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "Q") == "")
        #expect(!c.ledger.isActive)
        #expect(notices(hud).last == "密碼欄位不聽寫")
        #expect(!polisher.calls.contains { $0.raw.contains("這段不可上屏") },
                "實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("這段不可上屏") || ($0.outcomeText?.contains("這段不可上屏") ?? false)
        }, "實際：\(history.exchanges)")
        #expect(skipEvents(history).last?.outcomeText == "secureUnknown：sessionApp:com.foo.app",
                "分類與 detail 格式必須與硬停那條逐字相同，保險絲不得改寫它")
        #expect(skipEvents(history).last?.utteranceRaw == "")
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("這段不可上屏") },
                "asr_diagnostic 同樣不得留明文；實際：\(history.diagnostics.map(\.finalizedText))")
        #expect(!clipboard.texts.contains("這段不可上屏"))
    }

    // MARK: - fallback 重送窗口 W1′：保險絲在第二道閘門也必須同進同退

    /// `insertWithFallback` 查**兩次**閘門：primary 送出前（W1）、primary 拋錯後備援重送前（W1′）。
    /// 上面所有測試走的都是 W1——primary 從不失敗，第二道閘門一次也沒被執行過。
    ///
    /// 這個缺口不是假設性的：把 W1′ 那次查詢整個包進保險絲
    /// （`if gateEnabled?() ?? true, let blocked = focusGateBlock() { ... }`，一個看起來很自然的
    /// 「關掉就別查了」最佳化），在補這三條之前**全套照樣全綠**；實際行為卻是使用者關掉開關之後，
    /// 只要 primary 失敗且焦點落進密碼欄，備援就把整句話打進去。
    /// primary 失敗本身就常伴隨 App 狀態變動，這不是罕見組合。

    /// W1′ 的 `.different` 那半：關閉時備援重送同樣照常寫（與 W1 對稱）。
    @Test func withTheSwitchOffTheFallbackResendAlsoWritesAsUsual() {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        c.hotkeyPressed(at: 10.0)
        env.failInsertsRemaining = 1                               // primary 拋錯一次 → 走備援
        // 查詢序：1＝controller 的密碼守衛，2＝coordinator 的 W1，3＝primary 拋錯後的 W1′。
        // 在第 2 次之後搬焦點，讓 W1′ 那次看到 `.different`。硬編碼的序號，日後路徑增減閘門查詢
        // 會**大聲紅**（焦點沒搬 → 字寫回 A → 下面 B 的斷言失敗），不會安靜變綠。
        env.afterFieldGate = { [weak env] in
            guard env?.fieldGateCalls == 2 else { return }
            env?.focus("B")
        }
        c.handleTranscript(.finalized("備援照常寫"), at: 10.5)

        #expect(env.text(in: "B") == "備援照常寫", "關閉時 W1′ 也放行，字落在當下聚焦的欄位")
        #expect(env.text(in: "A") == "", "primary 已拋錯（#38 原子契約：一個字都沒進）")
        #expect(notices(hud).isEmpty)
        #expect(clipboard.texts.isEmpty)
        #expect(skipEvents(history).isEmpty)
    }

    /// **W1′ 的密碼欄那半**：開關關閉 ＋ primary 拋錯 ＋ 焦點在備援重送前落進密碼欄
    /// → 仍然硬停。保險絲對 W1 與 W1′ 必須同進同退，不得只擋前面那道。
    @Test func withTheSwitchOffTheFallbackResendStillHardStopsOnASecureField() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("P", text: "", isSecure: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("我的密碼是1234。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        c.hotkeyPressed(at: 10.0)
        env.failInsertsRemaining = 1
        env.afterFieldGate = { [weak env] in
            guard env?.fieldGateCalls == 2 else { return }
            env?.focus("P")
        }
        c.handleTranscript(.finalized("我的密碼是1234"), at: 10.5)
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "P") == "", "備援重送必須先過閘門，且保險絲燒不到密碼欄")
        #expect(env.text(in: "A") == "")
        #expect(!c.ledger.isActive, "仍然硬停")
        #expect(notices(hud).last == "密碼欄位不聽寫")
        #expect(!polisher.calls.contains { $0.raw.contains("1234") },
                "被 W1′ 擋下的片段同樣不得送雲端；實際：\(polisher.calls.map(\.raw))")
        #expect(!history.exchanges.contains {
            $0.utteranceRaw.contains("1234") || ($0.outcomeText?.contains("1234") ?? false)
        }, "history_exchange 不得留明文；實際：\(history.exchanges)")
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("1234") },
                "asr_diagnostic 同樣不得留明文")
        #expect(!clipboard.texts.contains("我的密碼是1234"), "硬停不救剪貼簿")
    }

    /// 同上的 `.secureUnknown` 版——fail-closed 那半在 W1′ 也不受保險絲節制。
    @Test func withTheSwitchOffTheFallbackResendStillHardStopsOnASubroleUnknownField() async {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("Q", text: "", subroleUnknown: true)
        let polisher = GatedIntentService()
        polisher.outcome = .newContent("我的密碼是1234。")
        let clipboard = ClipboardSpy()
        let history = FakeHistory()
        let (c, _, hud) = makeStatefulController(env: env, polisher: polisher,
                                                 clipboard: clipboard, history: history)
        c.settings.rawAppendGateEnabled = false
        c.hotkeyPressed(at: 10.0)
        env.failInsertsRemaining = 1
        env.afterFieldGate = { [weak env] in
            guard env?.fieldGateCalls == 2 else { return }
            env?.focus("Q")
        }
        c.handleTranscript(.finalized("我的密碼是1234"), at: 10.5)
        c.tick(at: 12.4)
        await c.lastIntentTask?.value

        #expect(env.text(in: "Q") == "")
        #expect(env.text(in: "A") == "")
        #expect(!c.ledger.isActive)
        #expect(notices(hud).last == "密碼欄位不聽寫")
        #expect(!polisher.calls.contains { $0.raw.contains("1234") },
                "實際：\(polisher.calls.map(\.raw))")
        #expect(!history.diagnostics.contains { $0.finalizedText.contains("1234") })
        #expect(!clipboard.texts.contains("我的密碼是1234"))
    }
}
