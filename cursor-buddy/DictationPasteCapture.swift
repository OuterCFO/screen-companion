import AppKit

/// What the capture needs from a pasteboard; `NSPasteboard` in the app, a fake in tests.
nonisolated protocol DictationPasteboard: AnyObject {
    var changeCount: Int { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: DictationPasteboard {}

/// OpenSuperWhisper pastes a transcription by writing it to the clipboard, pressing Command+V,
/// and restoring the previous clipboard 100 ms later. When OpenClicky's main thread is busy for
/// longer than that, the paste reads the restored clipboard and inserts old copied text.
/// This watches the clipboard off the main thread from the moment dictation starts and keeps the
/// first text written after that, so the compact input can insert it however late the paste is handled.
nonisolated final class DictationPasteCapture: @unchecked Sendable {
    static let shared = DictationPasteCapture(pasteboard: NSPasteboard.general)

    private let pasteboard: DictationPasteboard
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "openclicky.dictation-paste-capture", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var baseline = 0
    private var expiresAt = Date.distantPast
    private var captured: String?

    init(pasteboard: DictationPasteboard) { self.pasteboard = pasteboard }

    /// Starts watching; call just before the dictation shortcut is sent.
    func start(timeout: TimeInterval = 180) {
        lock.lock()
        baseline = pasteboard.changeCount
        expiresAt = Date().addingTimeInterval(timeout)
        captured = nil
        let isRunning = timer != nil
        lock.unlock()
        guard !isRunning else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        lock.lock(); self.timer = timer; lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        captured = nil
        lock.unlock()
        timer?.cancel()
    }

    /// The transcription to insert instead of the current clipboard, used once.
    func takeTranscription() -> String? {
        lock.lock()
        let value = captured
        captured = nil
        lock.unlock()
        if value != nil { stop() }
        return value
    }

    /// One polling step; internal so tests can drive it without a timer.
    func poll() {
        lock.lock()
        defer { lock.unlock() }
        guard Date() < expiresAt else { stopLocked(); return }
        guard captured == nil else { return }
        let count = pasteboard.changeCount
        guard count != baseline else { return }
        if count == baseline + 1, let text = pasteboard.string(forType: .string), !text.isEmpty {
            captured = text
        } else if count > baseline + 1 {
            // Missed the write: the clipboard now likely holds the restored old text, which must
            // never be inserted. Wait for the next write; a normal paste is the fallback.
            baseline = count
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        captured = nil
    }
}
