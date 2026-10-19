#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/main.swift" <<'SWIFT'
import CoreGraphics
let shortcut = ExternalDictationShortcut.decode(#"{"carbonKeyCode":15,"carbonModifiers":6144}"#)!
precondition(shortcut.keyCode == 15)
precondition(shortcut.flags == [.maskControl, .maskAlternate])
precondition(ExternalDictationShortcut.decode(nil) == nil)
precondition(ExternalDictationShortcut.decode("invalid") == nil)
precondition(ExternalDictationShortcut.decode(#"{"carbonKeyCode":900,"carbonModifiers":6144}"#) == nil)
precondition(ExternalDictationShortcut.decode(#"{"carbonKeyCode":15,"carbonModifiers":0}"#) == nil)
print("PASS: configured external dictation shortcut and malformed-setting rejection")
SWIFT
swiftc "$ROOT/cursor-buddy/OpenSuperWhisperDictation.swift" "$ROOT/cursor-buddy/DictationPasteCapture.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
