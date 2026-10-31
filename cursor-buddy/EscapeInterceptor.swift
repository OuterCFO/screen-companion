import CoreGraphics
import Foundation

/// While the reply bubble is showing, the first Escape closes it and is kept from the app underneath,
/// so dismissing the bubble never also cancels what the user is doing there.
/// Runs its own event tap on a background thread so a busy main thread never delays typing.
nonisolated final class EscapeInterceptor: @unchecked Sendable {
    static let shared = EscapeInterceptor()
    static let escapeKeyCode: Int64 = 53

    private let lock = NSLock()
    private var armed = false
    private var swallowing = false
    private var tap: CFMachPort?
    private var onIntercept: (@Sendable () -> Void)?

    /// Armed while the bubble is visible; Escape passes through untouched otherwise.
    func setArmed(_ value: Bool) {
        lock.lock(); armed = value; lock.unlock()
    }

    /// Decides whether one key event is held back. Swallowing one Escape press also swallows its
    /// auto-repeats and key-up, and disarms, so the next Escape reaches the app.
    func shouldSwallow(type: CGEventType, keyCode: Int64) -> (swallow: Bool, dismiss: Bool) {
        guard keyCode == Self.escapeKeyCode else { return (false, false) }
        lock.lock(); defer { lock.unlock() }
        switch type {
        case .keyDown where swallowing:
            return (true, false)
        case .keyDown where armed:
            armed = false
            swallowing = true
            return (true, true)
        case .keyUp where swallowing:
            swallowing = false
            return (true, false)
        default:
            return (false, false)
        }
    }

    /// Starts once; needs the Accessibility permission. Without it Escape keeps passing through.
    func start(onIntercept: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onIntercept = onIntercept
        let alreadyStarted = tap != nil
        lock.unlock()
        guard !alreadyStarted else { return }
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "openclicky.escape-interceptor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func runTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<EscapeInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        lock.lock(); self.tap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = self.tap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let decision = shouldSwallow(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        if decision.dismiss {
            lock.lock(); let onIntercept = self.onIntercept; lock.unlock()
            if let onIntercept { DispatchQueue.main.async(execute: onIntercept) }
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
