#!/usr/bin/env bash
# Dev-only: compile the helper, run the maths fixtures, validate the manifest,
# and run the marketplace preflight scan.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m py_compile helper/collect.py
python3 tools/check-math.py
python3 tools/check-images.py
python3 tools/check-issues.py
omarchy plugin validate . >/dev/null && echo "manifest: ok"
if [ -x "$HOME/.claude/skills/omarchy-plugin/scripts/preflight.sh" ]; then
  bash "$HOME/.claude/skills/omarchy-plugin/scripts/preflight.sh" . | tail -8
fi
