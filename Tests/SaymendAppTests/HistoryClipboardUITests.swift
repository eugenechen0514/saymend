import AppKit
import SwiftUI
import Testing
import SaymendCore
@testable import SaymendApp

/// History 分頁的複製按鈕（issue #42）：文案釘死、按鈕在畫面上、複製走 ClipboardChannel。
@Suite struct HistoryClipboardUITests {
    @Test func overwriteConfirmationCopyOnlyClaimsWhatChangeCountCanTell() {
        #expect(HistoryClipboardText.copyButton == "複製最終文字")
        #expect(HistoryClipboardText.overwriteRescueTitle == "剪貼簿裡還是上次聽寫救援的內容")
        #expect(HistoryClipboardText.overwriteRescueMessage ==
            "那段文字自救援後還沒被別的內容取代。若你已經貼過了，可以放心覆蓋。")
        #expect(HistoryClipboardText.overwrite == "覆蓋")
        #expect(HistoryClipboardText.cancel == "取消")
    }

    @MainActor @Test func copyButtonShowsItsLabelAndCarriesTheAlertCopy() {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.history.\(UUID().uuidString)"))
        let button = HistoryCopyButton(text: "最終文字",
                                       clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()))
        let texts = ViewTreeInspection.unhiddenTextStrings(in: button.body)
        #expect(texts.contains(HistoryClipboardText.copyButton))
        #expect(texts.contains(HistoryClipboardText.overwriteRescueMessage), "alert 的說明文字要掛在按鈕上")
    }

    // MARK: 真的按下去——分支邏輯要被鎖住，不能只驗文案在樹裡

    private func makeChannel(seed: String, timer: FakeClipboardTimer = FakeClipboardTimer()) -> (NSPasteboard, ClipboardChannel) {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.history.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(seed, forType: .string)
        return (pb, ClipboardChannel(pasteboard: pb, timer: timer))
    }

    @MainActor @Test func pressingCopyWithoutARescueCopiesImmediately() throws {
        let (pb, channel) = makeChannel(seed: "U")
        let button = HistoryCopyButton(text: "最終文字", clipboard: channel)
        let action = try #require(ViewTreeInspection.firstButtonAction(in: button.body))
        action()
        #expect(pb.string(forType: .string) == "最終文字")
    }

    @MainActor @Test func pressingCopyWhileARescueIsInClipboardDoesNotOverwriteIt() throws {
        let (pb, channel) = makeChannel(seed: "U")
        channel.rescue("救援 R")
        let button = HistoryCopyButton(text: "最終文字", clipboard: channel)
        let action = try #require(ViewTreeInspection.firstButtonAction(in: button.body))
        action()
        #expect(pb.string(forType: .string) == "救援 R", "要先確認，不得直接覆寫")
        #expect(channel.rescueStillInClipboard == "救援 R")
    }

    /// 救援正被在途 paste 暫時擠開：此刻 `rescueStillInClipboard` 是 nil，按鈕仍不得跳過確認。
    @MainActor @Test func pressingCopyWhileAPasteDisplacesTheRescueStillAsksFirst() throws {
        let timer = FakeClipboardTimer()
        let (pb, channel) = makeChannel(seed: "U", timer: timer)
        channel.rescue("救援 R")
        try channel.withTransientWrite("A") {}
        timer.now = 0.1
        let button = HistoryCopyButton(text: "最終文字", clipboard: channel)
        let action = try #require(ViewTreeInspection.firstButtonAction(in: button.body))
        action()
        #expect(pb.string(forType: .string) == "救援 R", "先收尾（放回 R）再判斷，然後停下來確認")
        #expect(timer.waits.count == 1)
    }

    /// 「（未定稿）」的 session 沒有最終文字：不得用空字串寫剪貼簿，更不得因此洗掉救援。
    @MainActor @Test func pressingCopyWithEmptyTextWritesNothing() throws {
        let (pb, channel) = makeChannel(seed: "U")
        let button = HistoryCopyButton(text: "", clipboard: channel)
        let action = try #require(ViewTreeInspection.firstButtonAction(in: button.body))
        action()
        #expect(pb.string(forType: .string) == "U")
    }
}
