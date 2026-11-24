#!/usr/bin/env bash
# The side-conversation replay (docs/spec/24 SD3) against a real model: asks for an OpenRouter key without echoing it
# (or uses OPENROUTER_API_KEY if it's set), runs packages/engine/test/side-replay.test.ts, and prints the summary.
#   scripts/side-replay.sh [model,model…]   default: the default chat model
set -euo pipefail
cd "$(dirname "$0")/../packages/engine"
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
	read -rsp "OpenRouter key: " OPENROUTER_API_KEY
	echo
fi
[ -n "$OPENROUTER_API_KEY" ] || { echo "No key: nothing ran."; exit 1; }
export OPENROUTER_API_KEY PIOPIO_REPLAY=side
[ -n "${1:-}" ] && export PIOPIO_REPLAY_MODELS="$1"
npx vitest run test/side-replay.test.ts
unset OPENROUTER_API_KEY
for f in $(ls -t test/replay/results/side-*.json 2>/dev/null | head -"$(echo "${PIOPIO_REPLAY_MODELS:-x}" | tr ',' '\n' | wc -l)"); do
	node -e 'const d=require(process.argv[1]); console.log(`${d.model.id}: ${d.right}/${d.total} right · new tasks offered ${d.offeredNewTasks} · false offers ${d.falseOffers} · ${d.passes ? "passes" : "doesn\x27t pass"} · $${d.costUsd}`)' "$PWD/$f"
done
