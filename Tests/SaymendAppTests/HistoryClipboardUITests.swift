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
}
