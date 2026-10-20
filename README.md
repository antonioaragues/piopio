# Piopio

A native macOS app with a front-end for the [pi](https://pi.dev) agent harnesses (`pi-coding-agent` and `pi-durable`), with three modes:

- **Build**: an agent-first development environment (projects → sessions, diffs, approvals, git/GitHub).
- **Chat**: threads, folder projects, and Spaces where an organizer agent routes your messages to topics.
- **Agents**: personal agents that are proactive, live in Telegram/WhatsApp, run on schedules, talk to each other, and run 24/7 on your own Cloudflare account.

Models come through OpenRouter (bring your own key).

> Status: **Phase 1, milestone 1.1**: the Mac app runs Chat threads end to end (dev builds only).

See the full specification in [docs/spec](docs/spec/README.md).

## Repository

| Path | What |
|---|---|
| `apps/mac/App` | The SwiftUI app (`project.yml` → XcodeGen; the `.xcodeproj` is generated, not committed) |
| `apps/mac` | Swift package: `PiopioKit` (engine client, protocol types, Keychain, streaming markdown), `PiopioTranscript` (windowed TextKit 2 transcript), `piopio-cli`, and `TranscriptLab` (spike S2 benchmarks) |
| `packages/protocol` | Engine Protocol schemas (TypeBox → JSON Schema) |
| `packages/engine` | Local Engine: Node daemon hosting pi-durable (Threads) and pi-coding-agent (Build) behind JSON-RPC over a Unix socket |
| `packages/runtime`, `packages/cloud`, `packages/extensions` | Placeholders for later phases |

## Development

Requirements: macOS 27, Xcode 27, XcodeGen (`brew install xcodegen`), Node ≥ 22.19, pnpm 11 (`corepack enable` provides it).

```bash
pnpm install
pnpm build
pnpm test          # engine tests (scripted model, no key needed)
pnpm test:swift    # PiopioKit tests
pnpm demo:s1       # Swift CLI ↔ engine, both runtimes, scripted model
scripts/build-app.sh   # builds the engine and Piopio.app (Debug); prints the .app path
scripts/release.sh 0.1.0   # Release app with bundled Node + engine → signed DMG (+ notarization, appcast); see docs/releasing.md
scripts/app-smoke.sh   # launches the app on a scratch data folder with the scripted model and saves a snapshot
```

Dev builds run the engine from `packages/engine/dist` with Node from Homebrew (`/opt/homebrew/bin/node`). On first launch the app asks for your OpenRouter key and stores it in the Keychain. Set `PIOPIO_FAUX=1` (in the Xcode scheme) to use the scripted echo model instead.

To talk to a real model, store your OpenRouter key in the Keychain, then run the demo against OpenRouter:

```bash
apps/mac/.build/debug/piopio-cli key set openrouter
scripts/s1-demo.sh --real
```

Engine environment variables are documented in `packages/engine/src/main.ts`.

## License

[MIT](LICENSE)
