#!/usr/bin/env bash
# Non-invasive checks. Native app builds remain in Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git diff --check
python3 scripts/check-publication.py
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
if [[ "$(uname -s)" != Darwin ]]; then
  echo "macOS Swift checks require macOS; Python checks passed."
  exit 0
fi
for target in cursor-buddy cursor-buddyTests; do
  find "$target" -name '*.swift' -print0 | xargs -0 xcrun swiftc -parse
done
scripts/run-provider-catalog-tests.sh
bash "$ROOT/scripts/run-claude-code-cli-tests.sh"
bash "$ROOT/scripts/run-answer-provider-tests.sh"
bash "$ROOT/scripts/run-companion-conversation-tests.sh"

bash "$ROOT/scripts/run-reply-markdown-tests.sh"

bash "$ROOT/scripts/run-external-dictation-tests.sh"

bash "$ROOT/scripts/run-voice-routing-tests.sh"

bash "$ROOT/scripts/run-dictation-paste-tests.sh"
