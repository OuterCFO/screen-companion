import Foundation

nonisolated enum ScreenTutorRoutingPolicy {
    static func shouldStayInTutor(_ text: String) -> Bool {
        let normalized = text.lowercased()
        guard normalized.range(of: #"\b(screen|page|heading|button|menu|field)\b"#, options: .regularExpression) != nil else { return false }
        // Explicit agent work and actual interaction keep their existing routes.
        guard normalized.range(of: #"\b(agent|run|execute|delete|type|open)\b"#, options: .regularExpression) == nil else { return false }
        return normalized.range(of: #"\b(point (?:at|to)|highlight|draw (?:a |an )?(?:box|rectangle|circle))\b"#, options: .regularExpression) != nil
    }

    /// The compact panel stays a screen tutor, so it starts a background agent only on explicit phrasing:
    /// "start an agent to …", "have an agent …", "agent: …", or "new task: …". Returns the task instruction.
    static func explicitAgentInstruction(_ text: String) -> String? {
        let filler = #"(?:(?:ok(?:ay)?|so|hey|please|uh|um|go|and|now|can you|could you|would you|i want you to|i'd like you to)[\s,]+)*"#
        let pattern = #"^\s*"# + filler + #"(?:(?:start|run|launch|spin up|create|use|kick off|send)\s+(?:an?\s+|the\s+|a\s+new\s+)?(?:background\s+)?(?:agent|task)\s*(?:to|that|and|for|:|-|,)?\s+|(?:ask|have|get|let)\s+(?:an?\s+|the\s+)?agent\s+(?:to\s+)?|(?:agent|new task)\s*[:\-]\s*)(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let instruction = text[range].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        // Require a real instruction so phrases like "start an agent framework" are not treated as tasks.
        return instruction.split(separator: " ").count >= 2 ? instruction : nil
    }

    /// Added to compact-panel answers so the model never claims a handoff that did not happen.
    static let noAutomaticAgentNote = """
    THIS TURN CANNOT START BACKGROUND WORK: nothing you say starts Agent Mode or any other task. Never say you started, launched, queued, or handed off an agent or task. Answer directly from the screen and your knowledge. If the request needs background work such as files, code, commands, or live research, say that the user can type "start an agent to" followed by the task.
    """
}
