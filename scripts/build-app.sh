#!/usr/bin/env bash
# Builds Piopio.app (Debug by default): the TypeScript engine, the Xcode project (XcodeGen), and the app.
#   scripts/build-app.sh [Debug|Release]     → apps/mac/App/build/Build/Products/<config>/Piopio.app
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-Debug}"
# Use Xcode even when xcode-select still points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app ]]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
(cd "$root" && corepack pnpm -r build >/dev/null)
cd "$root/apps/mac/App"
xcodegen generate --quiet
xcodebuild -project Piopio.xcodeproj -scheme Piopio -configuration "$config" -derivedDataPath build -quiet build
echo "$root/apps/mac/App/build/Build/Products/$config/Piopio.app"
