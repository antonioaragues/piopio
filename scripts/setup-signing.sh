#!/usr/bin/env bash
# Signs development builds with your Apple Developer team, so Piopio keeps secrets in the data protection keychain
# (no password prompts). Needs your account in Xcode › Settings › Accounts; Xcode makes the certificate and profile.
#   scripts/setup-signing.sh <TEAMID>     writes apps/mac/App/Signing.local.xcconfig (not committed)
#   scripts/setup-signing.sh --remove     back to ad hoc
set -euo pipefail
file="$(cd "$(dirname "$0")/.." && pwd)/apps/mac/App/Signing.local.xcconfig"
team="${1:?usage: scripts/setup-signing.sh <TEAMID> | --remove}"
if [[ "$team" == --remove ]]; then rm -f "$file"; echo "Ad hoc signing (removed $file)"; exit 0; fi
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "setup-signing: a Team ID is 10 letters and digits (developer.apple.com › Membership)" >&2; exit 1; }
cat > "$file" <<XCCONFIG
// Written by scripts/setup-signing.sh; not committed.
DEVELOPMENT_TEAM = $team
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_ENTITLEMENTS = Keychain.entitlements
XCCONFIG
echo "Signing with team $team ($file). Build with scripts/build-app.sh."
