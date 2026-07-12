import CoreGraphics
import Foundation
import SpeeckinkCore

/// 全域熱鍵監聽（規格 §3.1）：CGEventTap 監聽 flagsChanged（修飾鍵）與 keyDown（Esc）。
/// 需要輔助功能權限。聽寫中吞掉 Esc，避免傳進目標 App。
final class HotkeyMonitor {
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onEscape: (() -> Void)?

    private let hotkey: () -> HotkeyChoice
    private let isCapturing: () -> Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    private static let escapeKeyCode: Int64 = 53

    init(hotkey: @escaping () -> HotkeyChoice, isCapturing: @escaping () -> Bool) {
        self.hotkey = hotkey
        self.isCapturing = isCapturing
    }

    enum HotkeyError: Error { case tapCreationFailed }

    func start() throws {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            throw HotkeyError.tapCreationFailed   // 幾乎必是輔助功能權限未授予
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = Date().timeIntervalSinceReferenceDate
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // 系統暫停 tap 時自動復活
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let choice = hotkey()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == choice.keyCode else { return Unmanaged.passUnretained(event) }
            let downNow = event.flags.contains(choice.flagMask)
            if downNow, !isDown {
                isDown = true
                DispatchQueue.main.async { self.onPress?(now) }
            } else if !downNow, isDown {
                isDown = false
                DispatchQueue.main.async { self.onRelease?(now) }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode, isCapturing() {
                DispatchQueue.main.async { self.onEscape?() }
                return nil   // 吞掉 Esc，不讓目標 App 收到
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
