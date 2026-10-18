#!/usr/bin/env bash
# Runs the Swift package tests. With only the Command Line Tools installed (no Xcode),
# SwiftPM does not find the swift-testing macro plugin, so point at it explicitly.
set -euo pipefail
cd "$(dirname "$0")/../apps/mac"
plugin=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools && -d "$plugin" ]]; then
	exec swift test -Xswiftc -plugin-path -Xswiftc "$plugin" "$@"
fi
exec swift test "$@"
