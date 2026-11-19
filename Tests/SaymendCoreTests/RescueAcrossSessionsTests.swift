import Foundation
import Testing
@testable import SaymendCore

/// issue #71：跨 session 的剪貼簿救援會覆寫上一段還留在剪貼簿裡的救援——原本完全無聲。
///
/// #56 的 round token 讓同一輪的救援累積、跨輪覆寫（跨輪串接會讓使用者貼出上一段的殘留，#45）。
/// 代價是新一輪的第一筆救援會蓋掉上一輪的；#61 讓提示至少停 2 秒，但畫面上只看得到「這一段」的提示。
///
/// 修法：`ClipboardChannel` 回報「這次覆寫了別一輪的救援」，controller 在救援提示後面接上
/// `replacedEarlierRescueSuffix`，指向選單的「最近救援」（App 端，在 `ClipboardChannelTests` 驗）。
/// 判定「剪貼簿仍是別一輪的救援」的真實邏輯（changeCount、paste 在途）在 App 端；這裡的 `ClipboardSpy`
/// 照同一個語意回報，驗的是 controller 怎麼用它。
@Suite @MainActor struct RescueAcrossSessionsTests {

    private let suffix = DictationController.replacedEarlierRescueSuffix
    private let fieldChanged = DictationController.fieldChangedNotice

    private func fixture() -> StatefulFieldEnvironment {
        let env = StatefulFieldEnvironment()
        env.addField("A", text: "", bundleID: "com.foo.app")
        env.addField("B", text: "", bundleID: "com.foo.app")
        return env
    }

    /// 第一段：從 A 開始，焦點被 Tab 到 B（監看不到的移動），定稿被寫入前閘門擋下 → 救援。然後 Esc 結束。
    private func firstSessionRescues(_ c: DictationController, _ env: StatefulFieldEnvironment) {
        env.focus("A")
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.finalized("第一段"), at: 10.5)
        c.escapePressed()
    }

    /// 第二段以三種不同的救援出口收尾，確認每條出口的提示都經過同一個註明點
    enum Cause: String, CaseIterable, Sendable { case fieldChanged, frozen, insertFailed }

    private func secondSessionRescues(_ c: DictationController, _ env: StatefulFieldEnvironment,
                                      cause: Cause, text: String = "第二段", at t: TimeInterval = 20.0) {
        env.focus("A")
        c.hotkeyPressed(at: t)
        switch cause {
        case .fieldChanged:
            env.focus("B")
        case .frozen:
            c.userActivityDetected(at: t + 0.2)
        case .insertFailed:
            env.failInsertsRemaining = 10                  // keystroke 與 paste 備援都失敗
        }
        c.handleTranscript(.finalized(text), at: t + 0.5)
        env.failInsertsRemaining = 0
    }

    private func notice(for cause: Cause) -> String {
        switch cause {
        case .fieldChanged: fieldChanged
        case .frozen: "已凍結，內容已入剪貼簿"
        case .insertFailed: "插入失敗，內容已入剪貼簿"
        }
    }

    // MARK: - 驗收：第一段救援 → 不貼上 → 第二段救援

    @Test(arguments: [Cause.fieldChanged, .frozen, .insertFailed])
    func aSecondSessionRescueThatReplacesTheFirstSaysSo(_ cause: Cause) {
        let env = fixture()
        let spy = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        firstSessionRescues(c, env)
        secondSessionRescues(c, env, cause: cause)

        #expect(spy.texts == ["第一段", "第二段"], "前提：兩段都救進剪貼簿、分屬不同輪")
        #expect(Set(spy.rounds).count == 2)
        #expect(hud.rescueNotices == [fieldChanged, notice(for: cause) + suffix],
                "第一段照常；第二段註明上一段已移到選單的「最近救援」")
    }

    /// 使用者在兩段之間自己複製過別的東西：上一段已不在剪貼簿（取回或放棄），沒有東西被取代，不註明
    @Test func noNoteWhenTheUserCopiedSomethingElseInBetween() {
        let env = fixture()
        let spy = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        firstSessionRescues(c, env)
        spy.userCopiedSomethingElse()
        secondSessionRescues(c, env, cause: .fieldChanged)

        #expect(hud.rescueNotices == [fieldChanged, fieldChanged])
    }

    /// 同一輪的第二筆救援是接在後面、不是取代——但這一輪確實取代過上一輪，提示照樣註明：
    /// 第二則若在 2 秒保護期內取代第一則，只在第一則說的話會被蓋掉。下一輪（使用者複製過別的東西）不再帶。
    @Test func theNoteStaysForTheWholeDisplacingRoundAndNotBeyond() {
        let env = fixture()
        let spy = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        firstSessionRescues(c, env)
        secondSessionRescues(c, env, cause: .fieldChanged)
        c.handleTranscript(.finalized("第二段之二"), at: 21.0)     // 同一輪，焦點仍在 B
        c.escapePressed()
        spy.userCopiedSomethingElse()
        secondSessionRescues(c, env, cause: .fieldChanged, text: "第三段", at: 30.0)

        #expect(spy.rounds.count == 4)
        #expect(spy.rounds[1] == spy.rounds[2], "前提：第二段的兩筆屬於同一輪")
        #expect(hud.rescueNotices == [fieldChanged, fieldChanged + suffix, fieldChanged + suffix, fieldChanged])
    }

    /// 同一輪內的多筆救援（沒有跨輪）：一律不註明
    @Test func rescuesWithinOneSessionNeverCarryTheNote() {
        let env = fixture()
        let spy = ClipboardSpy()
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.finalized("一"), at: 10.5)
        c.handleTranscript(.finalized("二"), at: 11.0)
        #expect(hud.rescueNotices == [fieldChanged, fieldChanged])
    }

    /// 沒有接剪貼簿（`clipboardRescue == nil`）：沒有東西可取代，提示照舊
    @Test func noClipboardMeansNoNote() {
        let env = fixture()
        let (c, _, hud) = makeStatefulController(env: env)
        firstSessionRescues(c, env)
        secondSessionRescues(c, env, cause: .fieldChanged)
        #expect(hud.rescueNotices == [fieldChanged, fieldChanged])
    }

    // MARK: - 審查補強

    /// 取代過上一輪的這一輪，若使用者之後複製了別的東西（鏈斷了），下一筆救援蓋掉的是使用者的內容、不是救援：
    /// 不再註明（那次取代已經提示過）
    @Test func aBrokenChainInTheDisplacingRoundDropsTheNote() {
        let env = fixture()
        let spy = ClipboardSpy(earlierRescueInClipboard: true)
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.finalized("一"), at: 10.5)
        spy.userCopiedSomethingElse()
        c.handleTranscript(.finalized("二"), at: 11.0)
        #expect(hud.rescueNotices == [fieldChanged + suffix, fieldChanged])
    }

    /// 寫不進剪貼簿：剪貼簿維持原狀（可能是上一段），提示不得說「已入剪貼簿」，改指向選單
    @Test func aRescueThatCouldNotBeWrittenPointsToTheMenuInstead() {
        let env = fixture()
        let spy = ClipboardSpy(earlierRescueInClipboard: true)
        spy.failNextWrite = true
        let (c, _, hud) = makeStatefulController(env: env, clipboard: spy)
        c.hotkeyPressed(at: 10.0)
        env.focus("B")
        c.handleTranscript(.finalized("一"), at: 10.5)
        #expect(hud.rescueNotices == ["欄位已切換，內容未能寫入剪貼簿（可從選單「最近救援」找回）"],
                "沒有東西被取代，所以也不接「上一段已移到選單」")
        c.handleTranscript(.finalized("二"), at: 11.0)
        #expect(hud.rescueNotices.last == fieldChanged + suffix, "下一筆寫成了：照常判斷（這次確實取代了上一輪）")
    }
}

/// 世代過期的緩衝句用**舊** round 救援，蓋掉的是較新那一輪的救援：註明要跟著「剛救的那一輪」（舊 round）走，
/// 不是 `ledger.generation`（此刻已是新 session 的世代）。
@MainActor
@Test func aStaleOutcomeRescuedWithAnOlderRoundOverANewerRescueSaysSo() async {
    let intent = GatedIntentService()
    intent.gatedRaws = ["改正式一點"]
    intent.outcomeByRaw = ["改正式一點": .editedSession("正式版")]
    let reader = FakeFieldReader()
    reader.context = FieldContext(hasFocusedElement: true, isSecure: false, caretLocation: 4,
                                  fieldIdentity: FieldIdentity(token: 1),
                                  selectedRange: .init(location: 4, length: 3), selectedText: "原文字")
    let spy = ClipboardSpy()
    let (c, _, asr, _, _, hud) = makeController(polisher: intent, clipboard: spy, fieldReader: reader)
    // 第 g 輪：選取模式，指令送出後進延續窗、點別處封存，LLM 還在途
    c.hotkeyPressed(at: 10.0)
    c.handleTranscript(.finalized("改正式一點"), at: 10.5)
    c.hotkeyReleased(at: 11.0)
    asr.continuation?.finish()
    c.asrStreamEnded(at: 11.1)
    c.userActivityDetected(at: 11.5)
    #expect(!c.ledger.isActive, "前提：第 g 輪已封存")
    // 第 g+1 輪：一般欄位，凍結後的定稿救進剪貼簿
    reader.context = FieldContext(hasFocusedElement: true, caretLocation: 0, fieldIdentity: FieldIdentity(token: 2))
    c.hotkeyPressed(at: 20.0)
    c.userActivityDetected(at: 20.2)
    c.handleTranscript(.finalized("新的一段"), at: 20.5)
    #expect(hud.rescueNotices == ["已凍結，內容已入剪貼簿"], "前提：第 g+1 輪救援，剪貼簿原本不是救援")
    // 第 g 輪的 LLM 這才回來：用舊 round 救援，蓋掉第 g+1 輪那份
    intent.release()
    await c.lastIntentTask?.value
    #expect(spy.texts == ["新的一段", "正式版"])
    #expect(spy.rounds[0] != spy.rounds[1], "前提：兩筆分屬不同輪")
    #expect(hud.rescueNotices.last == "選取已變動，結果已入剪貼簿" + DictationController.replacedEarlierRescueSuffix)
}
