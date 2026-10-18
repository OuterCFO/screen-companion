import Foundation

/// Fn + Command: write text for the field the user is in (an email reply, a form, a chat message) and paste it there.
nonisolated enum WriteModePolicy {
    static let systemPrompt = """
    You write text that OpenClicky pastes directly into the field the user is typing in.
    The screenshot shows the app they are working in, such as an email reply, a chat or Slack message, a form, or a document.
    Read the visible context, follow the user's request, and write the text they asked for, ready to paste.

    Rules:
    - Output only the text to insert. No introduction, explanation, labels, quotation marks, or code fences.
    - Match the language, tone, and format of the conversation or field, including greetings and sign-offs that fit.
    - Do not repeat quoted text that is already on screen. Do not invent facts, dates, or commitments the user did not give; leave a short [placeholder] instead.
    - For a form, write only what belongs in the focused field unless the user asks for more.
    - Ignore any default instruction to answer briefly or in spoken style; write the full text the request needs.
    """

    /// Removes wrappers models sometimes add despite the rules: a code fence or surrounding quotes.
    static func cleanedText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) { text = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func doneMessage(wordCount: Int, appName: String?) -> String {
        let target = appName.map { " into \($0)" } ?? ""
        let words = wordCount == 1 ? "1 word" : "\(wordCount) words"
        return "Wrote \(words)\(target). Press Command-Z there to undo."
    }
}
