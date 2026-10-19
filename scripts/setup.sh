#!/usr/bin/env bash
# One-command setup for a fresh clone: checks tools, writes Config/Local.xcconfig,
# prepares the Codex runtime, and opens the project in Xcode.
# Usage: scripts/setup.sh [--team TEAM_ID] [--bundle-prefix com.yourname] [--no-codex] [--no-open]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM=""
PREFIX=""
WITH_CODEX=1
OPEN_XCODE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --bundle-prefix) PREFIX="$2"; shift 2 ;;
    --no-codex) WITH_CODEX=0; shift ;;
    --no-open) OPEN_XCODE=0; shift ;;
    -h|--help) sed -n 2,4p "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ok() { echo "  ok    $1"; }
warn() { echo "  note  $1"; }
fail() { echo "  error $1" >&2; exit 1; }

echo "Checking requirements"
[[ "$(uname -s)" == Darwin ]] || fail "OpenClicky is a macOS app; run this on a Mac."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 26 )) || fail "macOS 26 or later is required (this Mac has $(sw_vers -productVersion))."
ok "macOS $(sw_vers -productVersion)"
developer_dir="$(xcode-select -p 2>/dev/null || true)"
[[ "$developer_dir" == *Xcode*.app* ]] || fail "Install Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
ok "Xcode at ${developer_dir%%/Contents/*}"
command -v python3 >/dev/null || fail "python3 is missing; install Xcode's command line tools."
command -v git >/dev/null || fail "git is missing; install Xcode's command line tools."
ok "python3 and git"

echo "Signing configuration"
if [[ -f Config/Local.xcconfig ]]; then
  ok "Config/Local.xcconfig already exists; leaving it unchanged"
else
  if [[ -z "$TEAM" ]]; then
    # The team ID is the OU field of an Apple Development certificate, if one is installed.
    TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
  fi
  if [[ -z "$PREFIX" ]]; then
    PREFIX="com.$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  fi
  {
    echo "// Created by scripts/setup.sh. Ignored by Git."
    echo "OPENCLICKY_DEVELOPMENT_TEAM = ${TEAM}"
    echo "OPENCLICKY_BUNDLE_ID_PREFIX = ${PREFIX}"
  } > Config/Local.xcconfig
  ok "wrote Config/Local.xcconfig (bundle ID ${PREFIX}.openclicky)"
  if [[ -z "$TEAM" ]]; then
    warn "no Apple Development certificate found: sign in under Xcode > Settings > Accounts,"
    warn "then set OPENCLICKY_DEVELOPMENT_TEAM in Config/Local.xcconfig (or rerun with --team)."
  else
    ok "development team ${TEAM}"
  fi
fi

echo "AI providers"
if command -v claude >/dev/null; then
  ok "Claude Code found; pick a Claude model in OpenClicky Settings to use your Claude plan"
else
  warn "Claude Code not found (optional): https://docs.anthropic.com/claude-code"
fi
if (( WITH_CODEX )); then
  python3 scripts/prepare-codex-runtime.py
  ok "Codex runtime ready (sign in with: AppResources/OpenClicky/CodexRuntime/bin/codex login)"
else
  warn "skipped the Codex runtime; Codex models stay unavailable until you run scripts/prepare-codex-runtime.py"
fi

echo "Dictation"
if [[ -d /Applications/OpenSuperWhisper.app ]]; then
  ok "OpenSuperWhisper installed"
else
  warn "OpenSuperWhisper not found (optional, for local dictation): https://github.com/Starmel/OpenSuperWhisper"
fi

echo
echo "Next: in Xcode choose the cursor-buddy scheme and My Mac, press Command+B,"
echo "copy OpenClicky.app from Products to /Applications, launch it, and grant"
echo "Screen Recording and Accessibility. Full guide: docs/SETUP.md"
if (( OPEN_XCODE )); then open cursor-buddy.xcodeproj; fi
