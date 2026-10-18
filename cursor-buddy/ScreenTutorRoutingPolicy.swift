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

    /// Added to compact-panel answers: the model decides when a request needs a background agent.
    static let agentHandoffNote = """
    BACKGROUND TASKS: You answer from the screen and the conversation. When the request needs real work you cannot do in this reply, such as reading or changing files, running commands, checking email, calendar, or messages, live web research, or multi-step work in apps, hand it to a background agent instead of answering or refusing.
    To hand off, put one line exactly [AGENT: <a complete, self-contained task instruction>] right after the POINT line, then only a cursor_reply block saying you started it. OpenClicky starts the agent and shows its result later.
    Never claim you started, ran, or checked something without this line. Do not hand off questions you can answer from the screen or your knowledge.
    """

    /// The task instruction from a top-level `[AGENT: ...]` line, ignoring quoted or fenced examples.
    static func agentHandoffInstruction(fromAnswer answer: String) -> String? {
        var insideFence = false
        for line in answer.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { insideFence.toggle(); continue }
            guard !insideFence, trimmed.hasPrefix("[AGENT:"), trimmed.hasSuffix("]") else { continue }
            let instruction = trimmed.dropFirst("[AGENT:".count).dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            return instruction.split(separator: " ").count >= 2 ? instruction : nil
        }
        return nil
    }

    /// Hides a handoff directive (complete or still streaming) from the visible reply.
    static func removingAgentHandoff(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[AGENT") }
            .joined(separator: "\n")
    }

    static func handoffStartedMessage(instruction: String) -> String {
        let brief = instruction.count > 90 ? String(instruction.prefix(87)) + "…" : instruction
        return "Started a background task: \(brief) Its result will appear here when it finishes."
    }
}
