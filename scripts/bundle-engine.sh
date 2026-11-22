#!/usr/bin/env bash
# Puts the engine and the pinned Node runtime inside a built Piopio.app (Xcode build phase, Release builds).
#   scripts/bundle-engine.sh <Piopio.app> <version>
#     Contents/Helpers/node            Node (scripts/fetch-node.sh)
#     Contents/Resources/engine/…      the bundled engine (packages/engine/scripts/bundle.mjs), with cloud-worker/
# Signing happens afterwards: Xcode signs ad hoc, scripts/release.sh re-signs for distribution.
set -euo pipefail
app="${1:?usage: bundle-engine.sh <Piopio.app> <version>}"
version="${2:?usage: bundle-engine.sh <Piopio.app> <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# Xcode runs build phases with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

node="$("$root/scripts/fetch-node.sh")"
(cd "$root" && corepack pnpm --filter "@piopio/engine..." build >/dev/null)
# Piopio's Worker, which the engine deploys to your Cloudflare account (cloud-worker/ next to the engine).
(cd "$root" && corepack pnpm --filter @piopio/cloud build >/dev/null)
# Google's OAuth client secret (docs/spec/12 §2): from the environment, else the login keychain (docs/releasing.md).
# Without it, Connect for Google needs Developer setup.
if [[ -z "${PIOPIO_GOOGLE_CLIENT_SECRET:-}" ]]; then
	PIOPIO_GOOGLE_CLIENT_SECRET="$(security find-generic-password -s "Piopio release" -a google-client-secret -w 2>/dev/null || true)"
fi
[[ -n "$PIOPIO_GOOGLE_CLIENT_SECRET" ]] || echo "warning: no Google client secret; Google Calendar will need Developer setup" >&2
PIOPIO_GOOGLE_CLIENT_SECRET="$PIOPIO_GOOGLE_CLIENT_SECRET" node "$root/packages/engine/scripts/bundle.mjs" "$app/Contents/Resources/engine" "$version" >/dev/null
cp "$(dirname "$node")/../LICENSE" "$app/Contents/Resources/engine/NODE-LICENSE"
mkdir -p "$app/Contents/Helpers"
cp "$node" "$app/Contents/Helpers/node"
