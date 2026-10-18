#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/main.swift" <<'SWIFT'
import AppKit
let result = ReplyMarkdown.render("Press **Control+F**, then *Return*.\n\nUse `cat` and ==**important**==.")
precondition(result.string == "Press Control+F, then Return.\n\nUse cat and important.")
let value = result.string as NSString
let bold = result.attribute(.font, at: value.range(of: "Control+F").location, effectiveRange: nil) as! NSFont
precondition(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
let italic = result.attribute(.font, at: value.range(of: "Return").location, effectiveRange: nil) as! NSFont
precondition(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
precondition(result.attribute(.backgroundColor, at: value.range(of: "important").location, effectiveRange: nil) != nil)
let code = result.attribute(.font, at: value.range(of: "cat").location, effectiveRange: nil) as! NSFont
precondition(code.isFixedPitch)
precondition(ReplyMarkdown.render("`==literal==`").string == "==literal==")
let link = ReplyMarkdown.render("[docs](https://example.com)")
precondition(link.string == "docs" && link.attribute(.link, at: 0, effectiveRange: nil) != nil)
precondition(ReplyMarkdown.render("**unfinished").string.contains("unfinished"))
precondition(ReplyMarkdown.render("plain text").string == "plain text")
let shortHeight = ReplyMarkdown.height("Short reply", width: 240)
let longHeight = ReplyMarkdown.height(String(repeating: "This wraps across several lines. ", count: 20), width: 240)
precondition(longHeight > shortHeight * 4)
precondition(ReplyMarkdown.height("line one\n\nline two", width: 240) > shortHeight)
let full = "Detailed explanation.\n\n```sh\ncd ~/Documents/project\n```\n\nMore details."
let quoted = "The `<cursor_reply>` and [POINT:...] strings are conversation text.\n\nOur next practice is deliberately lengthy.\n\n<cursor_reply>\nType **help** in the right pane.\n</cursor_reply>"
let isolated = CursorReplyPresentation(quoted)
precondition(isolated.compact == "Type **help** in the right pane." && isolated.hasSummary)
precondition(!isolated.compact.contains("conversation text") && !isolated.compact.contains("cursor_reply"))
let fenced = "```xml\n<cursor_reply>\nNot a reply.\n</cursor_reply>\n```\n<cursor_reply>Real answer.</cursor_reply>"
precondition(CursorReplyPresentation(fenced).compact == "Real answer.")
precondition(CursorReplyPresentation(full).compact == CursorReplyPresentation.unavailable)
let unfinished = CursorReplyPresentation(full + "\n<cursor_reply>Run **cd**")
precondition(!unfinished.hasSummary && !unfinished.compact.contains("Detailed"))
let huge = CursorReplyPresentation("<cursor_reply>" + String(repeating: "word ", count: 100) + "</cursor_reply>")
precondition(huge.compact.split(whereSeparator: { $0.isWhitespace }).count <= 60 && huge.compact.count <= 600)
precondition(CursorReplyPresentation("<cursor_reply>Click here. [POINT:1,2:target]</cursor_reply>").compact == "Click here.")
precondition(CursorReplyPresentation("Short standalone answer.", requiresSummary: false).compact == "Short standalone answer.")
let pointBefore = "Detailed answer.\n[POINT:103,69:Codex]\n<cursor_reply>\nLook at Codex.\n</cursor_reply>"
let directive = CursorPointDirective.extract(pointBefore)!
precondition(directive.coordinate == CGPoint(x: 103, y: 69) && directive.label == "Codex")
precondition(!directive.spokenText.contains("[POINT:") && CursorReplyPresentation(directive.spokenText).compact == "Look at Codex.")
precondition(CursorPointDirective.extract("<cursor_reply>Short.</cursor_reply>\n[POINT:789,617:cat command:screen2]")?.screenNumber == 2)
precondition(CursorPointDirective.extract("```text\n[POINT:1,2:example]\n```") == nil)
precondition(CursorPointDirective.extract("The `[POINT:1,2:example]` tag is quoted.") == nil)
precondition(CursorPointDirective.extract("<cursor_reply>\n[POINT:1,2:example]\n</cursor_reply>") == nil)
precondition(CursorPointDirective.extract("[POINT:none]\n<cursor_reply>No target.</cursor_reply>")?.coordinate == nil)
let inline = "Yes. Click the empty prompt [POINT:659,32:top-right shell prompt]. Type cat there. <cursor_reply>\nClick the prompt and press Tab.\n</cursor_reply>"
let inlinePoint = CursorPointDirective.extract(inline)!
precondition(inlinePoint.coordinate == CGPoint(x: 659, y: 32))
precondition(CursorReplyPresentation(inlinePoint.spokenText).compact == "Click the prompt and press Tab.")
precondition(CursorReplyPresentation("Explanation. <cursor_reply>Concise.</cursor_reply>").compact == "Concise.")
precondition(CursorReplyPresentation("The <cursor_reply> tag is a format.\n```xml\n<cursor_reply>Quoted example.</cursor_reply>\n```\n<cursor_reply>Actual answer.</cursor_reply>").compact == "Actual answer.")
precondition(CursorPointDirective.extract("Example `[POINT:659,32:quoted]`.") == nil)
precondition(CursorResponseContract.instructions.contains("START") && CursorResponseContract.instructions.contains("SEPARATE line"))
let ordered = "[POINT:659,32:shell prompt]\nFull answer with detailed guidance.\n<cursor_reply>\nClick the top-right prompt.\n</cursor_reply>"
let orderedPoint = CursorPointDirective.extract(ordered)!
precondition(orderedPoint.coordinate == CGPoint(x: 659, y: 32))
precondition(CursorReplyPresentation(orderedPoint.spokenText).compact == "Click the top-right prompt.")
precondition(CursorResponseContract.instructions.contains("LAST paragraph/block") && CursorResponseContract.instructions.contains("Write nothing after it."))
let blocks = ReplyMarkdown.render("## Steps\n- Open **Mail**\n2. Click `Reply`\n> Note ==here==\n```\nlet x = **1**\n```\nDone.")
precondition(blocks.string == "Steps\n•\tOpen Mail\n2.\tClick Reply\nNote here\nlet x = **1**\nDone.", blocks.string)
let blockText = blocks.string as NSString
let heading = blocks.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
precondition(heading.pointSize > 13)
let listStyle = blocks.attribute(.paragraphStyle, at: blockText.range(of: "Open").location, effectiveRange: nil) as! NSParagraphStyle
precondition(listStyle.headIndent > 0)
precondition((blocks.attribute(.font, at: blockText.range(of: "let x").location, effectiveRange: nil) as! NSFont).isFixedPitch)
precondition(blocks.attribute(.backgroundColor, at: blockText.range(of: "here").location, effectiveRange: nil) != nil)
precondition(ReplyMarkdown.render("*Return* now").string == "Return now")
precondition(ReplyMarkdown.render("3 + 4 = 7").string == "3 + 4 = 7")
print("PASS: reply headings, bullet and numbered lists, quotes, and fenced code")
print("PASS: inline screenshot regression, standalone summary recovery, quoted/fenced safety, and mandatory response order")
print("PASS: real point-before-summary regression, metadata isolation, screen selection, and quoted-example rejection")
print("PASS: screenshot regression, dedicated summary isolation, code examples, absent/partial summary, hard length limits, and control metadata")
print("PASS: reply bold, italics, paragraphs, code, nested highlight, links, and partial Markdown")
SWIFT
swiftc "$ROOT/cursor-buddy/FormattedReplyText.swift" "$ROOT/cursor-buddy/CursorPointDirective.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
