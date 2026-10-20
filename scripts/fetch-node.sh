#!/usr/bin/env bash
# Downloads the pinned Node runtime the app ships (arm64 only) and prints the path of its `node` binary.
# The checksum is pinned here, so a changed download fails instead of being bundled.
#   scripts/fetch-node.sh   → .cache/node/node-v<version>-darwin-arm64/bin/node
set -euo pipefail
version=24.22.0
sha256=75ddfb875bbd868ebe57536f4442225f54dd10f6d2178dd439de869a5c648dc3
root="$(cd "$(dirname "$0")/.." && pwd)"
name="node-v$version-darwin-arm64"
cache="$root/.cache/node"
node="$cache/$name/bin/node"
if [[ ! -x "$node" ]]; then
	mkdir -p "$cache"
	archive="$cache/$name.tar.xz"
	curl -fsSL "https://nodejs.org/dist/v$version/$name.tar.xz" -o "$archive.part"
	echo "$sha256  $archive.part" | shasum -a 256 -c --quiet - || { rm -f "$archive.part"; echo "fetch-node: checksum mismatch for $name" >&2; exit 1; }
	mv "$archive.part" "$archive"
	tar -xJf "$archive" -C "$cache" "$name/bin/node" "$name/LICENSE"
	rm "$archive"
fi
echo "$node"
