#!/usr/bin/env bash
# Regression: the reply bubble lets clicks through except on ×, and closing it with Escape keeps Escape from the app underneath.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/main.swift" <<'SWIFT'
import CoreGraphics
let panel = CGRect(x: 100, y: 100, width: 300, height: 120)
let close = ReplyBubblePlacement.closeButtonRect(panelFrame: panel)
precondition(close.contains(CGPoint(x: 382, y: 204)), "× is clickable")
precondition(!close.contains(CGPoint(x: 150, y: 150)) && !close.contains(CGPoint(x: 382, y: 120)), "text area lets clicks through")
let escape = EscapeInterceptor()
precondition(escape.shouldSwallow(type: .keyDown, keyCode: 53) == (false, false), "unarmed: Escape reaches the app")
escape.setArmed(true)
precondition(escape.shouldSwallow(type: .keyDown, keyCode: 12) == (false, false), "other keys pass")
precondition(escape.shouldSwallow(type: .keyDown, keyCode: 53) == (true, true), "first Escape closes the bubble only")
precondition(escape.shouldSwallow(type: .keyDown, keyCode: 53) == (true, false), "its auto-repeat is held too")
precondition(escape.shouldSwallow(type: .keyUp, keyCode: 53) == (true, false), "and its key-up")
precondition(escape.shouldSwallow(type: .keyDown, keyCode: 53) == (false, false), "the next Escape reaches the app")
precondition(escape.shouldSwallow(type: .keyUp, keyCode: 53) == (false, false))
print("PASS: bubble clicks pass through except ×, one Escape closes the bubble without reaching the app")
SWIFT
swiftc "$ROOT/cursor-buddy/ReplyBubblePlacement.swift" "$ROOT/cursor-buddy/EscapeInterceptor.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
