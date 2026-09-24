#!/bin/bash
# Build the app source with the entry point compiled out, link the tests, run them.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/speakhud-tests"
swiftc -D TESTING speak-hud.swift tests/*.swift -o "$OUT"
"$OUT"
