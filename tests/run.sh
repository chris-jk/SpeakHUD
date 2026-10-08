#!/bin/bash
# Build the app source with the entry point compiled out, link the tests, run them.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/speakhud-tests"
swiftc -D TESTING speak-hud.swift tests/*.swift -o "$OUT"
"$OUT"
# The phone page's script has to parse: a broken one serves fine and shows a dead page.
# Then the page itself is run, in a stand-in browser against a fake Mac (tests/page).
if command -v node >/dev/null; then node --check phone/app.js; node --check phone/mic.js; node tests/page/run.js; fi
# The AskUserQuestion hook, against a fake HUD (Python: it never touches the app code).
python3 tests/read_question_test.py
