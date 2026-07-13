import CoreGraphics
import Foundation
import SpeeckinkCore

/// 全域熱鍵監聽（規格 §3.1）：CGEventTap 監聽 flagsChanged（修飾鍵）與 keyDown（Esc）。
/// 需要輔助功能權限。聽寫中吞掉 Esc，避免傳進目標 App。
final class HotkeyMonitor {
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onEscape: (() -> Void)?
    /// 使用者手動活動（非自家合成的 keyDown、滑鼠按下）；只在 isCapturing() 時發出
    var onUserActivity: ((TimeInterval) -> Void)?
    /// 判斷滑鼠事件位置（CG 全域座標，原點左上、Y 向下）是否落在自家 HUD 面板上。
    /// 落在自家 HUD 上的點擊要交給 HUD 的復原按鈕處理，不能當成使用者活動而把 session 封存
    /// （否則延續窗／鎖定聽寫下點「復原」會先觸發 archiveSession，隨後的 undoRequested 變 no-op，
    /// 直接違反規格 §3.3 HUD 常駐復原）。
    var isEventOnOwnHUD: ((CGPoint) -> Bool)?

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
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)   // 中鍵／側鍵（部分 App 支援中鍵貼上）
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

    /// 滑鼠按下是否算「使用者手動活動」：需在擷取中（聽寫或延續窗），且不是落在自家 HUD 上的點擊。
    /// 抽成獨立方法以利單元測試涵蓋「點自家 HUD 復原鈕不得觸發封存」這條接線。
    func shouldEmitUserActivityForMouse(at location: CGPoint) -> Bool {
        guard isCapturing() else { return false }
        if isEventOnOwnHUD?(location) == true { return false }
        return true
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
            // 自家合成事件不算使用者活動（Global Constraints：避免自我凍結）
            if event.getIntegerValueField(.eventSourceUserData) == KeystrokeInserter.syntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode, isCapturing() {
                DispatchQueue.main.async { self.onEscape?() }
                return nil   // 吞掉 Esc，不讓目標 App 收到
            }
            if isCapturing() {
                DispatchQueue.main.async { self.onUserActivity?(now) }
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if shouldEmitUserActivityForMouse(at: event.location) {
                DispatchQueue.main.async { self.onUserActivity?(now) }
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
