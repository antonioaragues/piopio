#!/usr/bin/env bash
# End-to-end failed-send and offline backup/restore check. Uses only a scripted model and scratch data.
# Usage: scripts/recovery-smoke.sh [path/to/Piopio.app] (otherwise builds Debug)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-}"
if [[ -z "$app" ]]; then app="$("$root/scripts/build-app.sh" | tail -1)"; fi
scratch="$(mktemp -d /tmp/pp-recovery.XXXXXX)"
report="$scratch/report.json"
PIOPIO_HOME="$scratch/data" PIOPIO_FAUX=1 PIOPIO_PI_SESSION_DIR="$scratch/pi-sessions" \
  PIOPIO_PI_AGENT_DIR="$scratch/pi-agent" PIOPIO_AGENTS_DIR="$scratch/AgentDefinitions" \
  PIOPIO_QUIT_AFTER_SNAPSHOT=1 PIOPIO_RECOVERY_REPORT="$report" "$app/Contents/MacOS/Piopio" >"$scratch/app.log" 2>&1 &
smoke_pid=$!
trap 'kill "$smoke_pid" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<120; attempt++)); do
  [[ -f "$report" ]] && break
  kill -0 "$smoke_pid" 2>/dev/null || break
  sleep 1
done
if [[ ! -f "$report" ]]; then
  tail -25 "$scratch/app.log"
  echo "No recovery report. Scratch files: $scratch" >&2
  exit 1
fi
for ((attempt=0; attempt<10; attempt++)); do
  kill -0 "$smoke_pid" 2>/dev/null || break
  sleep 1
done
cat "$report"
node -e 'process.exit(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).ok ? 0 : 1)' "$report"
echo "Recovery report: $report"
