import AppKit
import CoreGraphics

/// Starts/stops the user's external local dictation app after compact-input focus.
@MainActor
final class OpenSuperWhisperDictation {
    private static var triggering = false
    private static let bundleID = "ru.starmel.OpenSuperWhisper"

    static func trigger() async throws {
        guard !triggering else { return }
        triggering = true
        defer { triggering = false }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw DictationError("Install OpenSuperWhisper and configure its recording shortcut first.")
        }
        let preferences = UserDefaults(suiteName: bundleID)
        guard let shortcut = ExternalDictationShortcut.decode(preferences?.string(forKey: "KeyboardShortcuts_toggleRecord")) else {
            throw DictationError("Set OpenSuperWhisper's recording shortcut to a key combination, such as Control + Option + R.")
        }
        guard preferences?.bool(forKey: "holdToRecord") != true else {
            throw DictationError("Turn off Hold to record in OpenSuperWhisper so the shortcut starts and stops hands-free recording.")
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            try await Task.sleep(for: .milliseconds(700))
        }
        // Do not combine the synthetic dictation shortcut with still-held invocation keys.
        for _ in 0..<60 {
            if NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            throw DictationError("Release Command + Option before dictation starts.")
        }
        // A canceled/closed input must never inject a shortcut into another application.
        guard NSApp.isActive, NSApp.keyWindow?.isVisible == true else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else {
            throw DictationError("Could not create the OpenSuperWhisper shortcut events.")
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        try Task.checkCancellation()
        DictationPasteCapture.shared.start()
        down.post(tap: .cghidEventTap)
        // Always release the key even if the input is canceled during this delay.
        try? await Task.sleep(for: .milliseconds(80))
        up.post(tap: .cghidEventTap)
    }

    private struct DictationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

nonisolated struct ExternalDictationShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static func decode(_ value: String?) -> Self? {
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["carbonKeyCode"] as? Int, (0...127).contains(code),
              let modifiers = object["carbonModifiers"] as? Int else { return nil }
        var flags: CGEventFlags = []
        if modifiers & 256 != 0 { flags.insert(.maskCommand) }
        if modifiers & 512 != 0 { flags.insert(.maskShift) }
        if modifiers & 2048 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 4096 != 0 { flags.insert(.maskControl) }
        guard !flags.isEmpty else { return nil }
        return Self(keyCode: CGKeyCode(code), flags: flags)
    }
}
