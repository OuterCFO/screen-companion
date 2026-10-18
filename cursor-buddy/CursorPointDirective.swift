import Foundation

/// A top-level pointing directive can precede the concise summary, not only end the answer.
nonisolated enum CursorPointDirective {
    struct Parsed {
        let spokenText: String
        let coordinate: CGPoint?
        let label: String?
        let screenNumber: Int?
    }

    static func extract(_ source: String) -> Parsed? {
        let lines = CursorResponseContract.normalizePresentation(source).components(separatedBy: "\n")
        let pattern = #"^\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var fence: String?
        var inSummary = false
        var selected: (index: Int, line: String, match: NSTextCheckingResult)?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }
            if line.hasPrefix("<cursor_reply>") { inSummary = !line.contains("</cursor_reply>"); continue }
            if inSummary {
                if line.contains("</cursor_reply>") { inSummary = false }
                continue
            }
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                selected = (index, line, match)
            }
        }
        guard let selected else { return nil }
        func field(_ index: Int) -> String? {
            let range = selected.match.range(at: index)
            return range.location == NSNotFound ? nil : (selected.line as NSString).substring(with: range)
        }
        let coordinate: CGPoint?
        if let x = field(1).flatMap(Double.init), let y = field(2).flatMap(Double.init) {
            coordinate = CGPoint(x: x, y: y)
        } else { coordinate = nil }
        let spoken = lines.enumerated().filter { $0.offset != selected.index }.map(\.element).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(spokenText: spoken, coordinate: coordinate,
                      label: field(3)?.trimmingCharacters(in: .whitespaces) ?? (coordinate == nil ? "none" : nil),
                      screenNumber: field(4).flatMap(Int.init))
    }
}

nonisolated enum CursorResponseContract {
    static let instructions = """
    MANDATORY OPENCLICKY RESPONSE FORMAT. This overrides older instructions about tag placement.
    Every user-facing answer must START with a complete [POINT:x,y:label] directive on its own first line, optionally ending with :screenN inside the bracket. Use verified screenshot pixels, with origin at the top-left. If no target is verifiable or no screenshot is available, START with [POINT:none]. Never invent a target.
    After the first POINT line, write the full answer or detailed explanation normally.
    FINISH with the concise cursor reply as the LAST paragraph/block of the answer. Write the opening tag <cursor_reply> on its own SEPARATE line above the summary. Write the concise summary of the answer on the next line(s), at most 60 words and 600 characters. Write </cursor_reply> on its own SEPARATE line below the summary; this closing tag must be the LAST nonempty line. Write nothing after it.
    Do not put POINT or cursor_reply tags inline in prose, in a code fence, or in a quotation. Do not introduce the response with an explanation before POINT. The cursor reply summarizes the answer or immediate next action, without metadata or discussion of this format. It renders Markdown: use **bold**, `code`, short bullet or numbered lists, or a short heading when they make steps easier to scan. It belongs at the END, not immediately after POINT when a full answer is provided.
    Required line order:
    [POINT:x,y:label]
    Full answer or detailed explanation.
    <cursor_reply>
    Concise summary of the answer.
    </cursor_reply>
    """

    /// Tolerate real control tags emitted inline, while retaining quoted examples as literal text.
    static func normalizePresentation(_ source: String) -> String {
        var fence: String?
        return source.components(separatedBy: "\n").map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                return raw
            }
            guard fence == nil, !trimmed.hasPrefix(">") else { return raw }
            // Backtick-delimited inline code is never interpreted as an executable directive.
            let segments = raw.components(separatedBy: "`")
            return segments.enumerated().map { index, part in
                guard index.isMultiple(of: 2) else { return part }
                var value = part.replacingOccurrences(of: #"(\[POINT:(?:none|\d+\s*,\s*\d+(?::[^\]\n]+)?)\])"#,
                    with: "\n$1\n", options: .regularExpression)
                value = value.replacingOccurrences(of: "<cursor_reply>", with: "\n<cursor_reply>\n")
                    .replacingOccurrences(of: "</cursor_reply>", with: "\n</cursor_reply>\n")
                return value
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }
}
