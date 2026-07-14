import AppKit
import ScreenCaptureKit
import Vision
import os
import os.log

/// OCR 備援上下文（規格 §4.7 OCRReader）：AX 讀不到前後文時，截取聚焦欄位附近小區域
/// →Vision 辨識（純本地）→文字入 LLM 語境。
/// 鐵律：需螢幕錄製權限；未授權則**靜默停用**（不彈窗、不報錯——CGPreflight 只查不問）。
/// 任何一步失敗＝回 nil。截圖範圍＝欄位框外擴 80pt、夾在所屬螢幕內（小區域，非全螢幕）。
@MainActor
final class OCRContextReader {
    private static let logger = Logger(subsystem: "io.speeckink.app", category: "ocr")
    static let maxCharacters = 600
    static let expansion: CGFloat = 80

    func captureText() async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }   // 未授權：靜默停用
        guard let element = AXFieldAccess.focusedElement(),
              let frame = AXFieldAccess.elementFrame(element) else { return nil }
        guard let image = await Self.capture(around: frame) else { return nil }
        return await Self.recognize(image)
    }

    /// ScreenCaptureKit 截圖：找到含 rect 的顯示器，sourceRect 用「顯示器內相對座標」
    private static func capture(around rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) })
                    ?? content.displays.first else { return nil }
            let expanded = rect.insetBy(dx: -expansion, dy: -expansion)
                .intersection(display.frame)
            guard !expanded.isEmpty else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: expanded.origin.x - display.frame.origin.x,
                                       y: expanded.origin.y - display.frame.origin.y,
                                       width: expanded.width, height: expanded.height)
            config.width = Int(expanded.width) * 2      // Retina 兩倍取樣供 OCR
            config.height = Int(expanded.height) * 2
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            logger.debug("OCR 截圖失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func recognize(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            // 單次 resume 守門（終審 finding）：Vision 正常保證 completion 與 perform-throw 互斥，
            // 但 withCheckedContinuation 重複 resume 是致命 trap——不賭框架行為，自己鎖一道。
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: (String?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let joined = lines.joined(separator: "\n")
                let trimmed = joined.count > maxCharacters ? String(joined.prefix(maxCharacters)) : joined
                resumeOnce(trimmed.isEmpty ? nil : trimmed)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch {
                    resumeOnce(nil)
                }
            }
        }
    }
}
