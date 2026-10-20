#!/usr/bin/env bash
# Puts the engine and the pinned Node runtime inside a built Piopio.app (Xcode build phase, Release builds).
#   scripts/bundle-engine.sh <Piopio.app> <version>
#     Contents/Helpers/node            Node (scripts/fetch-node.sh)
#     Contents/Resources/engine/…      the bundled engine (packages/engine/scripts/bundle.mjs)
# Signing happens afterwards: Xcode signs ad hoc, scripts/release.sh re-signs for distribution.
set -euo pipefail
app="${1:?usage: bundle-engine.sh <Piopio.app> <version>}"
version="${2:?usage: bundle-engine.sh <Piopio.app> <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# Xcode runs build phases with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

node="$("$root/scripts/fetch-node.sh")"
(cd "$root" && corepack pnpm --filter "@piopio/engine..." build >/dev/null)
node "$root/packages/engine/scripts/bundle.mjs" "$app/Contents/Resources/engine" "$version" >/dev/null
cp "$(dirname "$node")/../LICENSE" "$app/Contents/Resources/engine/NODE-LICENSE"
mkdir -p "$app/Contents/Helpers"
cp "$node" "$app/Contents/Helpers/node"
