import CoreGraphics

/// What a compact-panel prompt does with the question, chosen by the shortcut that opened it.
nonisolated enum CompactPromptMode: String, Sendable {
    /// Command + Option: answer about what is on screen (screenshot attached).
    case screen
    /// Control + Command: answer from the question alone, without a screenshot, for a faster reply.
    case textOnly
    /// Fn + Command: write text for the field the user was in and paste it there.
    case write

    static let trackedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    /// Modifier-only chords: press and release exactly these keys with no other key in between.
    static func chord(for flags: CGEventFlags) -> CompactPromptMode? {
        let modifiers = flags.intersection(trackedModifiers)
        switch modifiers {
        case [.maskCommand, .maskAlternate]: return .screen
        case [.maskCommand, .maskControl]: return .textOnly
        case [.maskCommand, .maskSecondaryFn]: return .write
        default: return nil
        }
    }

    /// Follows modifier changes and reports a chord once it is released.
    /// Adding another modifier, or pressing any key, cancels it.
    struct ChordTracker {
        private var candidate: CompactPromptMode?
        private var candidateModifiers: CGEventFlags = []

        mutating func keyDown() { candidate = nil }

        mutating func flagsChanged(_ flags: CGEventFlags) -> CompactPromptMode? {
            let modifiers = flags.intersection(CompactPromptMode.trackedModifiers)
            if let chord = CompactPromptMode.chord(for: modifiers) {
                candidate = chord
                candidateModifiers = modifiers
                return nil
            }
            defer { candidate = nil }
            guard let chord = candidate, candidateModifiers.isStrictSuperset(of: modifiers) else { return nil }
            return chord
        }
    }
}
