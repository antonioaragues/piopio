# Setting up Piopio

Everything needed to build, run, sign, release and connect Piopio, in one place, so none of it has to be
remembered. Details that already have their own page are linked rather than repeated: [releasing.md](releasing.md),
[ci.md](ci.md), [backup.md](backup.md).

## Where things stand (2026-11-22)

| Piece | State | Section |
|---|---|---|
| Development tools on this Mac | Done | [1](#1-the-mac) |
| Dev builds signed with your team (no Keychain prompts) | Done (`Signing.local.xcconfig`) | [3](#3-signing-development-builds) |
| Google OAuth app | Registered, **in Testing**; tried with a real account | [7](#7-google-oauth-app) |
| Google's review (so anyone can sign in) | **Pending**: needs a homepage and privacy policy on a verified domain | [7.4](#74-googles-review-pending) |
| Microsoft OAuth app (Outlook) | **Pending**: needs a free Azure account first | [8](#8-microsoft-oauth-app-pending) |
| Developer ID signing and notarization | **Not verified** (needs the paid Apple account set up) | [9](#9-releases) |
| Sparkle updates (key and feed URL) | **Not set** (`SPARKLE_*` empty in `project.yml`) | [9](#9-releases) |
| Self-hosted CI runner for the Swift jobs | See [ci.md](ci.md) | [10](#10-ci) |

Update this table when something changes.

## 1. The Mac

- macOS 27 and Xcode 27, with your Apple account in Xcode › Settings › Accounts.
- Homebrew, then `brew install xcodegen node`. Node must be 22.19 or newer. Dev builds run the engine with
  `/opt/homebrew/bin/node`.
- pnpm 11 via Corepack: `corepack enable`. If `pnpm` isn't on the PATH, `corepack pnpm …` works.
- `gh` (GitHub CLI), signed in, for CI and releases.

## 2. Build and run

```bash
pnpm install
pnpm build
scripts/build-app.sh   # engine + Xcode project (XcodeGen) + Piopio.app (Debug); prints the .app path
```

- The Xcode project isn't committed: `apps/mac/App/project.yml` is the source and `build-app.sh` regenerates it.
- **Debug builds** run the repo's engine (`packages/engine/dist/main.js`) with Homebrew's Node. **Release builds**
  bundle their own Node and engine. `PIOPIO_BUNDLE_ENGINE=YES` bundles in Debug too.
- **The engine outlives the app** (background mode). After rebuilding the engine, quit the app *and* its engine,
  or the app reconnects to the old one ("Unknown method"). Find it with `pgrep -fl engine/dist/main.js`.
- **Your real data** is in `~/Library/Application Support/Piopio/`. Agents are in `~/Piopio/Agents/`, teams in
  `~/Piopio/Teams/`, and projects anywhere.
- **A throwaway run** uses another data folder. Keep the path short, because the engine's socket path is limited
  to 103 bytes. Set the agent and team folders too:
  ```bash
  home="$(mktemp -d -t piopio)"; PIOPIO_HOME="$home" PIOPIO_AGENTS_DIR="$home/agents" PIOPIO_TEAMS_DIR="$home/teams" PIOPIO_FAUX=1 <path to Piopio.app>/Contents/MacOS/Piopio
  ```
- **The scripted model**: `PIOPIO_FAUX=1` (also in the Xcode scheme) answers without any API key.
- **Engine environment variables** are listed at the top of `packages/engine/src/main.ts`.

## 3. Signing development builds

Without signing, macOS asks for your password for each secret after every rebuild. Signing with your team stops
that, and secrets move to the data protection keychain.

```bash
scripts/setup-signing.sh <TEAMID>   # writes apps/mac/App/Signing.local.xcconfig (not committed)
scripts/build-app.sh
scripts/setup-signing.sh --remove   # back to ad hoc
```

The Team ID is at developer.apple.com › Membership. One consequence: `security find-generic-password -s Piopio`
no longer sees the app's secrets. Read them through the app.

## 4. Secrets: where each one lives

| Secret | Where | How it gets there |
|---|---|---|
| OpenRouter key (and other providers) | The app's Keychain | First launch, or Settings › Models |
| Connector sign-ins (Google, Outlook, MCP apps) | The app's Keychain, `connector.<app>.<account>` | Settings › Connectors › Connect |
| A development OAuth client's secret | The app's Keychain, `connector.<app>.clientSecret` | Settings › Connectors › *app* › Developer setup… |
| **Google client secret for releases** | Login keychain, service `Piopio release`, account `google-client-secret` | `security add-generic-password -s "Piopio release" -a google-client-secret -w` (it prompts) |
| Notarization credentials | Login keychain profile `piopio-notary` | `xcrun notarytool store-credentials` ([releasing.md](releasing.md)) |
| Sparkle EdDSA private key | Login keychain | Sparkle's `generate_keys`. **Back it up**: losing it means installed copies can't update |
| Cloudflare API token (cloud agents) | The app's Keychain | Settings › This Mac & cloud ([spec 30](spec/30-cloud-target.md)) |
| `piopio-cli`'s own OpenRouter key | Login keychain | `apps/mac/.build/debug/piopio-cli key set openrouter` |

Nothing in this table goes in git. The repo is public, so before pushing anything unusual, check it for secrets.

## 5. Tests and checks

```bash
pnpm build && pnpm typecheck
pnpm test              # engine, runtime, policy and cloud (scripted model, no key)
pnpm test:swift        # PiopioKit and PiopioTranscript
scripts/app-smoke.sh   # the app on a scratch folder with the scripted model; saves a snapshot
scripts/recovery-smoke.sh   # failed send and offline backup/restore
```

One engine file: `cd packages/engine && npx vitest run test/<file>.test.ts`.

## 6. When something goes wrong

- **App logs:** subsystem `app.piopio` (Keychain choices, failures; never values).
  ```bash
  /usr/bin/log show --last 10m --info --predicate 'subsystem == "app.piopio"'
  ```
  Use `/usr/bin/log`: in zsh, plain `log` is a builtin and prints nothing.
- **Engine log:** `~/Library/Application Support/Piopio/logs/`.
- **What a real model was sent** (tools, reasoning): run the engine in-process from a throwaway vitest file with
  `PIOPIO_ALLOW_ENV_SECRETS=1` and wrap `globalThis.fetch` to save the request body.
- **Screen captures of the app** (`PIOPIO_SNAPSHOT`, `PIOPIO_DEMO_*`) fail silently while the display sleeps.
  Run `caffeinate -du -t 70 &` first. Sheets need `PIOPIO_SNAPSHOT_WINDOW=sheet`.
- **Two copies of the app** share the bundle ID and so share their preferences. Capture from a copy with its own ID
  if your own Debug build is open.

## 7. Google OAuth app

Lets anyone connect Google Calendar without a Google Cloud project of their own ([spec 12](spec/12-connectors.md)).

### 7.1 What's registered

- Google Cloud project **Piopio**. Audience **External**, publishing status **Testing**.
- **Google Calendar API** enabled. Scopes on the consent screen: `openid`, `email`, `calendar.readonly` and
  `calendar.events`. These are "sensitive", which means a review but no security audit.
- A **Desktop app** client. Its ID is in `BUILT_IN_CLIENTS` in `packages/engine/src/connectors/hub.ts`. Its
  secret is kept out of git: release builds take it from `PIOPIO_GOOGLE_CLIENT_SECRET` or the login keychain
  (section 4). A Debug build uses the one you entered in Developer setup.
- Desktop clients accept `http://127.0.0.1:<any port>` as the redirect, which is what the engine uses, so there
  are no redirect URIs to register.

### 7.2 How it was set up (to redo it, or for another project)

1. console.cloud.google.com → new project.
2. APIs & Services › Library → enable the API.
3. Google Auth Platform › **Get started** (if the menu isn't there yet), then:
   - **Branding:** name, support email, logo. Homepage, privacy policy and authorized domain come later, for the
     review.
   - **Audience:** External. Add every account that should sign in as a **test user**. Even the project owner
     gets `Error 403: access_denied` without it.
   - **Data access:** the scopes above.
   - **Clients › Create client** → Desktop app. Copy the secret right away.
4. Test it: Settings › Connectors › Google Calendar › **Developer setup…** → paste the ID and secret → Sign in.
   - Google warns that it "hasn't verified this app": click Advanced › Go to Piopio.
   - **Tick the calendar boxes.** Google lets users grant each scope separately.

### 7.3 Testing mode limits

- Only test users can sign in (up to 100), and they see the "unverified app" warning.
- **Sign-ins expire after 7 days.** Connectors then show Reconnect.

### 7.4 Google's review (pending)

1. A domain of your own, verified in Google Search Console.
2. A homepage and a privacy policy on that domain. GitHub Pages is enough.
3. Fill them in under Branding and add the domain as authorized.
4. Audience › **Publish app**, then Verification centre. It asks for:
   - why each scope is needed;
   - a YouTube video, which can be unlisted, showing the consent screen and Piopio reading and creating events.

   It usually takes days to a few weeks.

### 7.5 Later scopes

- **Gmail** (`gmail.readonly`, `gmail.modify`, `gmail.compose`) and **Drive** (`drive`, `drive.readonly`,
  `drive.metadata.readonly`) are **restricted**: they need a yearly paid security audit (CASA). Keep them out of
  the Calendar review and submit them in a round of their own. Adding scopes to a verified app only reviews the new
  ones.
- Enabling an API costs nothing and needs no review. Only the scopes on the consent screen are reviewed.
- For Drive in apps, the synced `~/Library/CloudStorage/` folder works today with no OAuth at all.

### 7.6 Rotating the secret

Google Cloud › Clients → the Desktop client → add a new secret, then delete the old one. Then:
```bash
security delete-generic-password -s "Piopio release" -a google-client-secret
security add-generic-password -s "Piopio release" -a google-client-secret -w
```
Finally, update Developer setup in your Debug build.

## 8. Microsoft OAuth app (pending)

For Outlook calendar and mail. Microsoft has no review like Google's.

1. **A directory first.** A personal Microsoft account can't register apps on its own: the portal says the
   account "does not exist in tenant 'Microsoft Services'". Create a free account at azure.microsoft.com/free with
   it. You get a "Default Directory" where you're the admin. It asks for a card and a phone number to verify you,
   and charges nothing unless you upgrade.
   - Don't register it under a company's work account: the app would belong to that company.
2. portal.azure.com → **Microsoft Entra ID › App registrations › New registration**:
   - Name: Piopio.
   - Supported accounts: **any organizational directory and personal Microsoft accounts**. The engine signs in
     through `/common`.
   - Redirect: **Public client/native (mobile & desktop)**, `http://localhost`. Any port is accepted.
3. Copy the **Application (client) ID**. There's no secret: it's a public client with PKCE.
4. **API permissions › Microsoft Graph › Delegated:** `User.Read`, `Calendars.ReadWrite`, `Mail.ReadWrite`,
   `Mail.Send`, `offline_access`, `openid`, `email`. Don't grant admin consent; each user consents at sign-in.
5. **Branding & properties:** logo, homepage, privacy policy.
6. Test it with Settings › Connectors › Outlook › Developer setup…, then add the ID to `BUILT_IN_CLIENTS` as
   `outlook`.
7. **Later: publisher verification.** It's free, through Microsoft's Cloud Partner Program, and needs the domain.
   Without it, many companies block their staff from consenting to the app. Personal accounts aren't affected.
8. **Later scopes**, in the same registration: OneDrive (`Files.Read.All`), SharePoint (`Sites.Read.All`, which
   needs an admin in companies), Teams (`Chat.Read`).

## 9. Releases

All in [releasing.md](releasing.md). The one-time steps:

1. Developer ID certificate.
2. `piopio-notary` notarization profile.
3. Developer ID provisioning profile.
4. Sparkle key and feed URL.
5. The Google secret in the keychain (section 4).

Each release:

```bash
PIOPIO_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
PIOPIO_PROVISIONING_PROFILE=<file>.provisionprofile PIOPIO_NOTARY_PROFILE=piopio-notary \
PIOPIO_DOWNLOAD_URL_PREFIX=… scripts/release.sh <version>
```

Without any of these variables, it makes an ad hoc DMG that only runs on this Mac.

## 10. CI

GitHub Actions runs the TypeScript checks on every push. The Swift and app jobs run on a self-hosted runner on
this Mac, only for `main`, and only once the repository variable `PIOPIO_SWIFT_CI` is `true`. Registering the
runner is described in [ci.md](ci.md).

## 11. Cloud and channels

- **Cloud agents:** Settings › This Mac & cloud, with one Cloudflare API token made from the "Edit Cloudflare
  Workers" template. Piopio deploys its own Worker. See [spec 30](spec/30-cloud-target.md).
- **Telegram:** make a bot with @BotFather (`/newbot`) and paste its token in the agent's chat. Piopio connects
  it and answers with a pairing link.

## 12. Backups

Settings › Backup. What's included and what isn't (Keychain secrets aren't) is in [backup.md](backup.md).
