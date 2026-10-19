#!/usr/bin/env bash
# Regression: a dictated paste handled after OpenSuperWhisper restored the clipboard inserts the transcription.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/main.swift" <<'SWIFT'
import AppKit
final class FakePasteboard: DictationPasteboard {
    var changeCount = 7
    var text: String? = "old copied text"
    func string(forType type: NSPasteboard.PasteboardType) -> String? { text }
    func write(_ value: String?) { changeCount += 1; text = value }
}
// OpenSuperWhisper writes, then restores before OpenClicky handles the paste.
var board = FakePasteboard()
var capture = DictationPasteCapture(pasteboard: board)
capture.start()
capture.poll()
precondition(capture.takeTranscription() == nil)
board.write("my dictated words")
capture.poll()
board.write("old copied text")
capture.poll()
precondition(capture.takeTranscription() == "my dictated words")
precondition(capture.takeTranscription() == nil, "used once")
// declareTypes bumps the count before the string exists: wait for it.
board = FakePasteboard(); capture = DictationPasteCapture(pasteboard: board); capture.start()
board.changeCount += 1; board.text = nil
capture.poll()
board.text = "late string"
capture.poll()
precondition(capture.takeTranscription() == "late string")
// Write and restore both happened between polls: never insert the restored old text.
board = FakePasteboard(); capture = DictationPasteCapture(pasteboard: board); capture.start()
board.write("missed"); board.write("old copied text")
capture.poll()
precondition(capture.takeTranscription() == nil)
board.write("next dictation")
capture.poll()
precondition(capture.takeTranscription() == "next dictation")
// Nothing captured after stop or timeout.
board = FakePasteboard(); capture = DictationPasteCapture(pasteboard: board); capture.start(timeout: -1)
board.write("too late"); capture.poll()
precondition(capture.takeTranscription() == nil)
print("PASS: dictated paste survives clipboard restore, waits for late strings, never inserts restored text, expires")
SWIFT
swiftc "$ROOT/cursor-buddy/DictationPasteCapture.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
