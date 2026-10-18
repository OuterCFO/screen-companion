#!/usr/bin/env bash
# Unit tests for the pure voice-routing vocabulary and the compact-panel prompt modes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cat > "$OUT/main.swift" <<'SWIFT'
import CoreGraphics
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

// SpokenText
expect(SpokenText.normalizedSpokenCommandText("  Héllo,   WORLD!  ") == "hello world", "normalization folds case, accents, punctuation, and spaces")
expect(SpokenText.wordCount(in: "fix the build, then test") == 5, "word count ignores punctuation")
expect(SpokenText.normalizedCommandCandidate(from: "Hey, clicky, open Safari.") == "open Safari", "filler prefixes and trailing punctuation are stripped")
expect(SpokenText.normalizedCommandCandidate(from: "I asked you to check the logs") == "check the logs", "reported requests become the command")
expect(SpokenText.normalizedAgentTaskInstruction(from: "Can you update the README?") == "update the README", "polite requests become the instruction")
expect(SpokenText.normalizedAgentTaskInstruction(from: "tell an agent to run the tests") == "run the tests", "agent delegation becomes the instruction")
expect(SpokenText.cleanedAgentTaskInstruction(" - draft the email. ") == "draft the email", "instructions lose surrounding punctuation")
print("PASS: spoken transcript normalization and command candidates")

// VoiceRouter
expect(VoiceRouter.containsAgentWorkAction("please fix the login bug"), "fix is agent work")
expect(!VoiceRouter.containsAgentWorkAction("what time is it"), "a plain question is not agent work")
expect(VoiceRouter.containsDurableWorkTarget("update the readme in the repo"), "a repository is a durable target")
expect(!VoiceRouter.containsDurableWorkTarget("tell me a joke"), "a joke has no durable target")
expect(VoiceRouter.containsFreshResearchRequest("what is the latest news"), "latest news needs fresh research")
expect(VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest("delete all files in downloads"), "broad deletes need confirmation")
expect(VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest("rotate my api key"), "credential targets need confirmation")
expect(!VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest("summarize this page"), "summaries do not need confirmation")
expect(VoiceRouter.containsHybridForegroundCue("explain this error"), "explain is a foreground cue")
expect(VoiceRouter.containsHybridBackgroundCue("and also fix it in the background"), "background is a background cue")
expect(!VoiceRouter.containsHybridBackgroundCue("explain this error"), "explain alone has no background cue")
expect(VoiceRouter.containsNaturalBackgroundWorkCue("make sure the tests pass"), "make sure is natural background work")
expect(VoiceRouter.containsNaturalBackgroundWorkCue("make the app use claude"), "make ... use is natural background work")
expect(VoiceRouter.containsReferentialWorkTarget("fix this"), "this is a referential target")
expect(!VoiceRouter.containsReferentialWorkTarget("open safari"), "a named app is not referential")
print("PASS: agent-work, research, safety, hybrid, and referential routing cues")

// CompactPromptMode
expect(CompactPromptMode.chord(for: [.maskCommand, .maskAlternate]) == .screen, "Command+Option asks about the screen")
expect(CompactPromptMode.chord(for: [.maskCommand, .maskControl]) == .textOnly, "Control+Command asks without a screenshot")
expect(CompactPromptMode.chord(for: [.maskCommand, .maskSecondaryFn]) == .write, "Fn+Command writes and pastes")
expect(CompactPromptMode.chord(for: [.maskCommand]) == nil, "Command alone is not a chord")
expect(CompactPromptMode.chord(for: [.maskCommand, .maskAlternate, .maskAlphaShift]) == .screen, "untracked modifiers are ignored")

var tracker = CompactPromptMode.ChordTracker()
expect(tracker.flagsChanged([.maskCommand]) == nil, "pressing Command starts nothing")
expect(tracker.flagsChanged([.maskCommand, .maskAlternate]) == nil, "a chord does not fire on press")
expect(tracker.flagsChanged([.maskCommand]) == .screen, "the chord fires on release")
expect(tracker.flagsChanged([]) == nil, "the chord fires once")

tracker = CompactPromptMode.ChordTracker()
_ = tracker.flagsChanged([.maskCommand, .maskControl])
tracker.keyDown()
expect(tracker.flagsChanged([]) == nil, "a key press cancels the chord")

tracker = CompactPromptMode.ChordTracker()
_ = tracker.flagsChanged([.maskCommand, .maskSecondaryFn])
expect(tracker.flagsChanged([.maskCommand, .maskSecondaryFn, .maskShift]) == nil, "an extra modifier does not fire")
expect(tracker.flagsChanged([]) == nil, "an extra modifier cancels the chord")
print("PASS: compact prompt chords fire on release and cancel on keys or extra modifiers")

// WriteModePolicy
expect(WriteModePolicy.cleanedText("```\nHello there\n```") == "Hello there", "code fences are removed")
expect(WriteModePolicy.cleanedText("\"Thanks, see you soon\"") == "Thanks, see you soon", "surrounding quotes are removed")
expect(WriteModePolicy.cleanedText("\"a\" and \"b\"") == "\"a\" and \"b\"", "inner quotes are kept")
expect(WriteModePolicy.wordCount("one two  three") == 3, "write mode counts words")
expect(WriteModePolicy.doneMessage(wordCount: 1, appName: "Mail") == "Wrote 1 word into Mail. Press Command-Z there to undo.", "done message names the app")
expect(WriteModePolicy.doneMessage(wordCount: 4, appName: nil) == "Wrote 4 words. Press Command-Z there to undo.", "done message without an app")
print("PASS: write mode cleanup and done message")

if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
SWIFT

xcrun swiftc \
  "$ROOT/cursor-buddy/SpokenText.swift" \
  "$ROOT/cursor-buddy/VoiceRouter.swift" \
  "$ROOT/cursor-buddy/CompactPromptMode.swift" \
  "$ROOT/cursor-buddy/WriteModePolicy.swift" \
  "$OUT/main.swift" \
  -o "$OUT/check"
"$OUT/check"
