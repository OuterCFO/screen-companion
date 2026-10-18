import Foundation

/// Spoken-transcript normalization utilities shared by the routing brain and
/// the rest of the app. Pure, `nonisolated`, side-effect-free. These form a
/// closed cluster: the only functions they call are each other.
nonisolated enum SpokenText {

    /// Lowercased, diacritic-folded, punctuation-stripped, single-spaced form
    /// of a transcript — the canonical surface the routing predicates match.
    static func normalizedSpokenCommandText(_ transcript: String) -> String {
        transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Strips leading filler ("hey", "ok clicky", "i said to", "let's try that
    /// again") and trailing punctuation so a raw transcript becomes a clean
    /// command candidate.
    static func normalizedCommandCandidate(from transcript: String) -> String {
        var candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixPatterns = [
            #"(?i)^\s*(?:hey|ok|okay|right|so|yeah|yep|well)[\s,]+"#,
            #"(?i)^\s*(?:oh[\s,]+)?(?:no[\s,\.]+){1,3}"#,
            #"(?i)^\s*(?:clicky|openclicky)[\s,]+"#,
            #"(?i)^\s*i\s+(?:said|asked|told)\s+(?:for\s+you\s+to|you\s+to|to)\s+"#,
            #"(?i)^\s*(?:let's|lets)\s+try\s+(?:that|this)\s+again[\s,]+"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:do|use)\s+(?:the\s+)?computer[\s-]+use(?:\s+then)?\s+(?:to|and)\s+"#
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for pattern in prefixPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let match = regex.firstMatch(in: candidate, range: range),
                      let matchRange = Range(match.range, in: candidate) else { continue }
                candidate.removeSubrange(matchRange)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripPrefix = true
            }
        }

        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
    }

    /// Reduces a polite agent request ("can you...", "please...", "tell an
    /// agent to...") down to the bare instruction.
    static func normalizedAgentTaskInstruction(from instruction: String) -> String {
        let trimmedInstruction = normalizedCommandCandidate(from: instruction)
        guard !trimmedInstruction.isEmpty else { return trimmedInstruction }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+|please\s+|(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)(.+?)[\.\!\?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmedInstruction,
                range: NSRange(trimmedInstruction.startIndex..<trimmedInstruction.endIndex, in: trimmedInstruction)
              ),
              let taskRange = Range(match.range(at: 1), in: trimmedInstruction) else {
            return trimmedInstruction
        }

        return String(trimmedInstruction[taskRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    static func cleanedAgentTaskInstruction(_ instruction: String) -> String {
        instruction
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
