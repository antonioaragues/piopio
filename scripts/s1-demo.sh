#!/usr/bin/env bash
# Spike S1: the Swift CLI streams answers from both runtimes through the Local Engine.
#
#   scripts/s1-demo.sh            # scripted echo model (no key needed)
#   scripts/s1-demo.sh --real     # OpenRouter; key from the Keychain (piopio-cli key set openrouter)
#
# Uses a throwaway PIOPIO_HOME so it never touches your real data.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
real=0; [[ "${1:-}" == "--real" ]] && real=1

echo "› building engine and CLI"
(cd "$root" && corepack pnpm -r build >/dev/null)
(cd "$root/apps/mac" && swift build -q 2>/dev/null)
cli="$root/apps/mac/.build/debug/piopio-cli"

export PIOPIO_HOME="$(mktemp -d -t piopio-s1)"
workdir="$(mktemp -d -t piopio-s1-project)"
echo "hello from a file" > "$workdir/notes.txt"
[[ $real == 0 ]] && export PIOPIO_FAUX=1

node "$root/packages/engine/dist/main.js" 2> "$PIOPIO_HOME/engine.log" &
engine=$!
trap 'kill $engine 2>/dev/null; wait $engine 2>/dev/null || true' EXIT
for _ in $(seq 50); do [[ -S "$PIOPIO_HOME/engine.sock" ]] && break; sleep 0.1; done

echo; echo "› thread (pi-durable)"
"$cli" chat "In one sentence, what is a durable object?"
echo; echo "› build session (pi-coding-agent) in $workdir"
"$cli" chat --build "$workdir" "Read notes.txt and tell me what it says."
echo; echo "› sessions"
"$cli" list
