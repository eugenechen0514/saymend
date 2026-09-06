import AppKit
import CoreGraphics
import Testing
import SaymendCore
@testable import SaymendApp

/// Cmd+C 選取備援（issue #42 起走 ClipboardChannel）：合成 Cmd+C 由 FakeKeyEventChannel 攔下，
/// `onPost` 模擬目標 App 收到 key-up 後把選取寫進剪貼簿。等待注入成記錄器，不真的睡。
@Suite struct ClipboardSelectionReaderTests {
    private func makePasteboard(seed: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.saymend.tests.selection.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(seed, forType: .string)
        return pb
    }

    @Test func readSelectionReturnsWhatTheTargetCopiedAndRestoresTheClipboard() {
        let channel = FakeKeyEventChannel()
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        channel.onPost = { event in
            guard event.type == .keyUp else { return }
            #expect(pb.string(forType: .string) == nil, "送 Cmd+C 時剪貼簿必須已清空，否則讀到的是舊內容")
            pb.clearContents()
            pb.setString("目標 App 的選取", forType: .string)
        }
        var waited: [TimeInterval] = []
        let reader = ClipboardSelectionReader(channel: channel,
                                              clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()),
                                              wait: { waited.append($0) })
        #expect(reader.readSelection() == "目標 App 的選取")
        #expect(waited == [0.12], "送出 Cmd+C 後要等目標 App 寫入；實際 \(waited)")
        #expect(pb.string(forType: .string) == "使用者原本的剪貼簿", "讀完必須同步還原")
        #expect(channel.posted.count == 2)
        #expect(channel.posted.allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(channel.posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == KeystrokeInserter.syntheticMarker })
        #expect(channel.posted.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 8 })
    }

    @Test func readSelectionReturnsNilWhenTheTargetCopiedNothing() {
        let channel = FakeKeyEventChannel()
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        let reader = ClipboardSelectionReader(channel: channel,
                                              clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()),
                                              wait: { _ in })
        #expect(reader.readSelection() == nil)
        #expect(pb.string(forType: .string) == "使用者原本的剪貼簿")
    }

    @Test func readSelectionTreatsAnEmptyCopyAsNoSelection() {
        let channel = FakeKeyEventChannel()
        let pb = makePasteboard(seed: "使用者原本的剪貼簿")
        channel.onPost = { event in
            guard event.type == .keyUp else { return }
            pb.clearContents()
            pb.setString("", forType: .string)
        }
        let reader = ClipboardSelectionReader(channel: channel,
                                              clipboard: ClipboardChannel(pasteboard: pb, timer: FakeClipboardTimer()),
                                              wait: { _ in })
        #expect(reader.readSelection() == nil)
        #expect(pb.string(forType: .string) == "使用者原本的剪貼簿")
    }
}
