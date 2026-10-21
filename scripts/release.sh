#!/usr/bin/env bash
# Builds a distributable Piopio: Release app with the bundled engine → signed → DMG → notarized → appcast entry.
# See docs/releasing.md for the one-time setup.
#
#   scripts/release.sh <version>            e.g. scripts/release.sh 0.1.0
#
# Env (all optional; without them you get an ad-hoc signed DMG for local testing):
#   PIOPIO_SIGN_IDENTITY        "Developer ID Application: Name (TEAMID)"   (default "-": ad hoc)
#   PIOPIO_NOTARY_PROFILE       notarytool keychain profile (xcrun notarytool store-credentials)
#   PIOPIO_BUILD                CFBundleVersion (default: commit count, so it always grows)
#   PIOPIO_FEED_URL             overrides SPARKLE_FEED_URL from project.yml
#   PIOPIO_SPARKLE_PUBLIC_KEY   overrides SPARKLE_PUBLIC_KEY from project.yml
#   PIOPIO_SPARKLE_KEY_FILE     EdDSA private key file (default: the key generate_keys put in the login keychain)
#   PIOPIO_DOWNLOAD_URL_PREFIX  where the DMGs are served, for the appcast (e.g. a GitHub release download URL)
#
# Output in apps/mac/App/build/release/: Piopio.app, Piopio-<version>.dmg, and updates/ (every DMG + appcast.xml).
set -euo pipefail
version="${1:?usage: scripts/release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$root/apps/mac/App"
out="$app_dir/build/release"
identity="${PIOPIO_SIGN_IDENTITY:--}"
build="${PIOPIO_BUILD:-$(git -C "$root" rev-list --count HEAD)}"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app ]]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
step() { printf '› %s\n' "$*"; }

step "building Piopio $version ($build)"
overrides=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build")
[[ -n "${PIOPIO_FEED_URL:-}" ]] && overrides+=(SPARKLE_FEED_URL="$PIOPIO_FEED_URL")
[[ -n "${PIOPIO_SPARKLE_PUBLIC_KEY:-}" ]] && overrides+=(SPARKLE_PUBLIC_KEY="$PIOPIO_SPARKLE_PUBLIC_KEY")
(cd "$app_dir" && xcodegen generate --quiet)
xcodebuild -project "$app_dir/Piopio.xcodeproj" -scheme Piopio -configuration Release -derivedDataPath "$app_dir/build" \
	-destination "generic/platform=macOS" -quiet -skipPackagePluginValidation build "${overrides[@]}" 2>&1 | grep -v -e DVTPlugIn -e CoreSimulator -e CoreDevice -e '^Details:' || true
built="$app_dir/build/Build/Products/Release/Piopio.app"
[[ -x "$built/Contents/Helpers/node" ]] || { echo "release: the build has no bundled engine" >&2; exit 1; }

rm -rf "$out/Piopio.app"
mkdir -p "$out/updates"
ditto "$built" "$out/Piopio.app"
app="$out/Piopio.app"

# Inside out: nested code first, the app last. A Developer ID build gets the hardened runtime everywhere
# (notarization requires it). Ad hoc, only Node gets it: library validation would refuse to load the ad hoc
# Sparkle.framework (no Team ID), but Node's JIT entitlements still get exercised.
step "signing with ${identity/#-/ad hoc}"
flags=(--force --sign "$identity")
[[ "$identity" != "-" ]] && flags+=(--timestamp --options runtime)
sign() { codesign "${flags[@]}" "$@"; }
sign --options runtime --entitlements "$app_dir/Node.entitlements" "$app/Contents/Helpers/node"
sign "$app/Contents/MacOS/piopio-engine"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --entitlements "$app_dir/Piopio.entitlements" "$app"
codesign --verify --deep --strict "$app"

step "making the DMG"
dmg="$out/Piopio-$version.dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Piopio.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Piopio $version" -srcfolder "$stage" -fs HFS+ -format ULFO "$dmg"
codesign --force --sign "$identity" ${PIOPIO_SIGN_IDENTITY:+--timestamp} "$dmg"

if [[ -n "${PIOPIO_NOTARY_PROFILE:-}" ]]; then
	[[ "$identity" != "-" ]] || { echo "release: notarization needs PIOPIO_SIGN_IDENTITY (a Developer ID)" >&2; exit 1; }
	step "notarizing (this takes a few minutes)"
	xcrun notarytool submit "$dmg" --keychain-profile "$PIOPIO_NOTARY_PROFILE" --wait
	xcrun stapler staple "$dmg"
	spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
	step "skipping notarization (PIOPIO_NOTARY_PROFILE not set)"
fi

public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$public_key" ]]; then
	step "updating the appcast"
	cp "$dmg" "$out/updates/"
	appcast=("$app_dir/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast")
	[[ -n "${PIOPIO_SPARKLE_KEY_FILE:-}" ]] && appcast+=(--ed-key-file "$PIOPIO_SPARKLE_KEY_FILE")
	[[ -n "${PIOPIO_DOWNLOAD_URL_PREFIX:-}" ]] && appcast+=(--download-url-prefix "$PIOPIO_DOWNLOAD_URL_PREFIX")
	"${appcast[@]}" "$out/updates"
	echo "$out/updates/appcast.xml"
else
	step "skipping the appcast (no SUPublicEDKey in this build)"
fi
echo "$dmg"
