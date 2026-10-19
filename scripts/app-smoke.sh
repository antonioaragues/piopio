#!/usr/bin/env bash
# Launches Piopio.app against a throwaway data folder with the scripted echo model, sends a markdown-heavy
# message, a follow-up, edits the follow-up (two versions), and writes a window snapshot. Usage: scripts/app-smoke.sh [out.png]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/apps/mac/App/build/smoke.png}"
app="$("$root/scripts/build-app.sh" | tail -1)"
home="$(mktemp -d -t piopio-smoke)"   # short path: Unix sockets allow 103 bytes
prompt=$'Here is **bold**, `code` and a [link](https://example.com).\n\n- one\n- two\n\n```swift\nlet answer = 42 // comment\n```\n\n> a quote\n\n| A | B |\n|---|---|\n| 1 | 2 |'
PIOPIO_HOME="$home" PIOPIO_FAUX=1 PIOPIO_DEMO_PROMPT="$prompt" PIOPIO_DEMO_FOLLOWUP="Second question" PIOPIO_DEMO_EDIT="Second question, edited" \
	PIOPIO_SNAPSHOT="$out" PIOPIO_SNAPSHOT_DELAY=9 PIOPIO_QUIT_AFTER_SNAPSHOT=1 \
	"$app/Contents/MacOS/Piopio" >/dev/null 2>&1 &
pid=$!
( sleep 60; kill "$pid" 2>/dev/null ) &
wait "$pid" || true
[[ -s "$out" ]] && echo "snapshot: $out" || { echo "no snapshot; engine log:"; tail -20 "$home/logs/engine.log"; exit 1; }
