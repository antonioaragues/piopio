# Continuous integration

[`.github/workflows/checks.yml`](../.github/workflows/checks.yml) runs on every push and pull request, and on demand (`gh workflow run Checks`).

| Job | Runs on | What it proves |
|---|---|---|
| `typescript` | GitHub's `ubuntu-latest` | The engine, runtime, extensions and cloud packages build, type-check and pass their scripted tests. No provider keys, no macOS. |
| `typescript-macos` | your own Mac (self-hosted) | The same TypeScript suites on macOS, where the tests that skip themselves elsewhere run: the sandbox (Seatbelt), the network filter in Build, ports. |
| `swift` | your own Mac (self-hosted) | `scripts/swift-test.sh`: `PiopioKit` and `PiopioTranscript` tests. |
| `app` | your own Mac (self-hosted) | `scripts/build-app.sh`: engine bundle, generated Xcode project and `Piopio.app`, left in `apps/mac/App/build/Build/Products/Debug/` on that Mac. |

**Pull requests never run the jobs on your Mac** (`typescript-macos`, `swift`, `app`). A pull request is unreviewed code, and the runner is the personal Mac. They only run on `main` (pushes) and on a manual dispatch — including a dispatch on `main`, which is the way to try a new runner without enabling anything.

## Why the Swift jobs are off by default

The app needs macOS 27, Xcode 27 and XcodeGen, which GitHub's hosted runners don't have. The jobs are gated by the repository variable `PIOPIO_SWIFT_CI`: without a registered runner they would sit in the queue forever, so they are skipped until the variable is `true`. A manual `workflow_dispatch` runs them anyway.

## Registering the runner (once)

On the Mac that builds the app (Apple silicon, macOS 27, Xcode 27, `brew install xcodegen`, Node 24):

```bash
# 1. A registration token (needs admin on the repository).
TOKEN=$(gh api -X POST repos/antonioaragues/piopio/actions/runners/registration-token --jq .token)

# 2. Install the runner with the label the workflow asks for.
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -O -L https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz
./config.sh --url https://github.com/antonioaragues/piopio --token "$TOKEN" \
  --labels piopio-macos-27 --name piopio-mac --unattended

# 3. Run it as a service, so it survives a reboot and a logout.
./svc.sh install
./svc.sh start
```

The workflow asks for `runs-on: [self-hosted, macOS, ARM64, piopio-macos-27]`; `macOS` and `ARM64` are automatic labels, `piopio-macos-27` is the one set above. `Check` in the runner log shows the labels if a job queues and never starts.

Then turn the jobs on for `main`:

```bash
gh variable set PIOPIO_SWIFT_CI --body true
```

Or leave it off and start them by hand with `gh workflow run Checks` until you trust the setup.

## What CI does not cover

- **The GUI.** `scripts/app-smoke.sh` and `scripts/recovery-smoke.sh` open a real window and take a snapshot; they need a logged-in GUI session on that Mac and stay manual. Do not put them in a job that runs while you're working: they steal focus.
- **The OS permission prompts** (notifications, Calendar, Reminders, Full Disk Access) and **VoiceOver**. Both are in the acceptance checklist in [status.md](status.md).
- **Real providers.** Live OpenRouter and provider sign-in tests are opt-in and need keys; they are not in CI.

## Running the same checks locally

```bash
corepack pnpm build && corepack pnpm typecheck && corepack pnpm test   # what the typescript job does
scripts/swift-test.sh                                                  # what the swift job does
scripts/build-app.sh                                                   # what the app job does
```

## The protocol between the engine and the app

The protocol is defined once, in `packages/protocol` (TypeBox); the app's Swift types in
`apps/mac/Sources/PiopioKit/Protocol.generated.swift` are generated from it by `corepack pnpm schema`
(`packages/protocol/src/swift.ts`, docs/spec/03-engine-protocol.md "Swift types"). Three checks hold them together:

- `packages/protocol/test/schema.test.ts` (in `pnpm test`): `schema/protocol.schema.json` and
  `schema/protocol.samples.json` are what the protocol says now. A change to the protocol fails here until
  `corepack pnpm schema` is run and both files are committed with it.
- `packages/protocol/test/swift.test.ts` (in `pnpm test`): the generated Swift is current, and every exported schema
  is named after itself. The generator itself fails on a `swift-names.ts` entry that names nothing, and on a Swift
  type shared by methods it doesn't fit.
- `apps/mac/Tests/PiopioKitTests/ProtocolContractTests.swift` (in `scripts/swift-test.sh`): every sample of every
  definition decodes into its generated type with the app's decoder and encodes back, and every
  `client.call("m", P(…), as: R.self)` in the app uses m's own params and result types (`ProtocolTypes`).

So a protocol change is: `packages/protocol/src/index.ts`, `corepack pnpm schema` (commit the three files it writes),
the app's call sites if the compiler asks, then `pnpm test` and `scripts/swift-test.sh`.

`pnpm test` clears ambient `PIOPIO_*` variables first ([`vitest.setup.ts`](../vitest.setup.ts)), so a shell that has a built `Piopio.app` on `PATH` (or `PIOPIO_FM` set) gives the same answers as CI.
