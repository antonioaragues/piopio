# Releasing Piopio

A release is a signed, notarized DMG plus an entry in the Sparkle appcast. `scripts/release.sh` does all of it.

```bash
scripts/release.sh 0.1.0
```

Without any setup it still works: you get an **ad hoc** signed DMG that runs on this Mac (handy for testing packaging), with no notarization and no appcast.

## What's in the app

| Path in `Piopio.app/Contents` | What |
|---|---|
| `MacOS/Piopio` | The app |
| `MacOS/piopio-engine` | Launcher: runs `Helpers/node` on `Resources/engine/main.js`, logs to `logs/engine.log` |
| `Helpers/node` | Node 24 LTS, arm64, pinned with its checksum in `scripts/fetch-node.sh` |
| `Resources/engine/` | The engine bundled by esbuild (`packages/engine/scripts/bundle.mjs`): `main.js`, the image worker, pi's docs (`pi/`) and two `.wasm` files |
| `Library/LaunchAgents/app.piopio.engine.plist` | Background mode (Settings › Engines › Keep running when Piopio quits) |
| `Frameworks/Sparkle.framework` | Updates (Sparkle 2.10.0, pinned in `apps/mac/App/project.yml`) |

Release builds get the engine from the **Bundle engine** build phase. Debug builds run the repo's engine with Homebrew's Node; set `PIOPIO_BUNDLE_ENGINE=YES` to bundle there too. To run another engine build in a Debug app:

```bash
defaults write app.piopio.Piopio customEnginePath /path/to/packages/engine/dist/main.js
```

Release builds ignore `customEnginePath`: any program running as you could set it, and the app answers its engine with Keychain secrets and Apple tools.

## One-time setup

### 1. Developer ID and notarization

You need a paid Apple Developer account.

1. In Xcode › Settings › Accounts, create a **Developer ID Application** certificate. Check it with `security find-identity -v -p codesigning`.
2. Create an app-specific password at appleid.apple.com, then store the notary credentials in the Keychain:
   ```bash
   xcrun notarytool store-credentials piopio-notary --apple-id <you@example.com> --team-id <TEAMID>
   ```
3. Create a **Developer ID provisioning profile** for `app.piopio.Piopio`: developer.apple.com › Certificates, IDs & Profiles › Profiles › + › Developer ID, pick the App ID and your Developer ID certificate, and download it. A development build signed with your team (see "Development builds" below) registers the App ID first. The profile lets the app use its own keychain access group, so secrets live in the data protection keychain and macOS never asks for a password. Without it, macOS refuses to launch a Developer ID build that claims the group.
4. Release with all three:
   ```bash
   PIOPIO_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" PIOPIO_PROVISIONING_PROFILE=~/Downloads/Piopio_Developer_ID.provisionprofile PIOPIO_NOTARY_PROFILE=piopio-notary scripts/release.sh 0.1.0
   ```

The script checks that the profile belongs to the same team and App ID and embeds it as `Contents/embedded.provisionprofile`. It adds `com.apple.application-identifier`, `com.apple.developer.team-identifier` and `keychain-access-groups` (`<TEAMID>.app.piopio.Piopio`) to `Piopio.entitlements`. Then it signs from the inside out with the hardened runtime and a secure timestamp. Order: Node (with `apps/mac/App/Node.entitlements`, JIT for V8 and WebAssembly), the launcher, Sparkle's helpers, then the app. It then builds the DMG, signs it, notarizes it, staples it, and checks it with `spctl`.

### 2. Sparkle signing key

Updates are signed with an EdDSA key. Create it once; it goes into your login Keychain:

```bash
apps/mac/App/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Put the printed public key in `SPARKLE_PUBLIC_KEY` in `apps/mac/App/project.yml`. Back up the private key (`generate_keys -x <file>`): **if it's lost, existing installs can't be updated.**

### 3. Feed URL

Set `SPARKLE_FEED_URL` in `project.yml` to where `appcast.xml` will be served. For GitHub Releases, for example, that's `https://github.com/<owner>/piopio/releases/latest/download/appcast.xml`, with `PIOPIO_DOWNLOAD_URL_PREFIX=https://github.com/<owner>/piopio/releases/download/v<version>/`.

Until both the key and the feed URL are set, the app's updater stays off. "Check for Updates…" is disabled, and Settings › General says the build doesn't update itself.

### 4. Google sign-in secret

Piopio's Google client ID is in the code (`connectors/hub.ts`), but its secret is kept out of git. The release bundle reads it from `PIOPIO_GOOGLE_CLIENT_SECRET`, or else from the login keychain. Store it there once:

```bash
security add-generic-password -s "Piopio release" -a google-client-secret -w
```

It prompts for the secret: Google Cloud › Google Auth Platform › Clients › the Desktop client. Without it, the build prints a warning, and connecting Google Calendar needs Settings › Connectors › Developer setup.

### Development builds

Ad hoc builds keep secrets in the login keychain. macOS identifies an ad hoc build by its hash, so after every rebuild it asks for your password once per secret ("Always Allow" only lasts until the next build). Signing with your team fixes that:

```bash
scripts/setup-signing.sh <TEAMID>     # writes apps/mac/App/Signing.local.xcconfig (not committed)
scripts/build-app.sh
```

It needs your account in Xcode › Settings › Accounts. Xcode then makes the Apple Development certificate and a development profile with the keychain access group (`-allowProvisioningUpdates`). The app then uses the data protection keychain (`Keychain.usesDataProtection`): no prompts, items only on this Mac (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync, not in backups). Each secret still in the login keychain moves over the first time it's read, with one last prompt. `scripts/setup-signing.sh --remove` goes back to ad hoc.

`piopio-cli` can't carry a provisioning profile, so it keeps using the login keychain. Secrets moved to the data protection keychain aren't visible to it; give it its own with `piopio-cli key set openrouter`.

## Each release

```bash
# Optional release notes, shown in the update window:
echo "# Piopio 0.2.0 …" > apps/mac/App/build/release/updates/Piopio-0.2.0.md
PIOPIO_SIGN_IDENTITY=… PIOPIO_NOTARY_PROFILE=piopio-notary PIOPIO_DOWNLOAD_URL_PREFIX=… scripts/release.sh 0.2.0
```

- `CFBundleVersion` is the commit count (`PIOPIO_BUILD` overrides it). Sparkle compares it, so it has to grow.
- `apps/mac/App/build/release/updates/` keeps every DMG, so `generate_appcast` can make delta updates. Upload the new DMG, any `.delta` files and `appcast.xml`.
- The background engine (if on) is restarted by the app after an update: on launch, the app compares the engine's version with its own.

## Checking a build

```bash
scripts/app-smoke.sh /tmp/smoke.png Release   # runs the Release app on its bundled engine with the scripted model
```

Verified locally (2026-10-20, ad hoc signing):
- The DMG app runs its own engine on hardened-runtime Node.
- Sparkle found, downloaded (delta), verified and installed an update from a localhost feed.
- Background mode survived app quit, reattached on relaunch, restarted the engine after an in-place update, and unregistered cleanly.

Not yet verified: Developer ID signing, notarization and Gatekeeper, because they need the Apple account.
