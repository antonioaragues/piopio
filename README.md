# Piopio

A native macOS app with a front-end for the [pi](https://pi.dev) agent harnesses (`pi-coding-agent` and `pi-durable`), with three areas:

- **Build**: projects and sessions, approvals, plans, diffs, rewind, git/worktrees, a terminal, MCP and subagents.
- **Chat**: chats, folders to chat about, and Notebooks (internally Spaces) that organize messages into topics with shared files and memory.
- **Agents**: local personal agents with schedules, reminders, memory, approvals, Mac-app abilities and agent-to-agent communication. Cloudflare hosting and Telegram/WhatsApp are planned; the cloud runtime is a local spike.

Models use connected providers, supported subscription sign-ins, or custom/local endpoints. OpenRouter is also required for the current web-search tool. Credentials stay in the macOS Keychain.

> Status: **personal alpha**. Build, Chat/Notebooks and local Agents are implemented (phases 1–4). Cloud is experimental. Real-provider compatibility, OS permissions and daily-use reliability still need broader validation.

See the full specification in [docs/spec](docs/spec/README.md).

## Repository

| Path | What |
|---|---|
| `apps/mac/App` | The SwiftUI app (`project.yml` → XcodeGen; the `.xcodeproj` is generated, not committed) |
| `apps/mac` | Swift package: `PiopioKit` (engine client, protocol types, Keychain, streaming markdown), `PiopioTranscript` (windowed TextKit 2 transcript), `piopio-cli`, and `TranscriptLab` (spike S2 benchmarks) |
| `packages/protocol` | Engine Protocol schemas (TypeBox → JSON Schema) |
| `packages/engine` | Local Engine: Node daemon hosting pi-durable (Threads) and pi-coding-agent (Build) behind JSON-RPC over a Unix socket |
| `packages/runtime` | Shared agent runtime, proactivity, safety and memory |
| `packages/extensions` | Build approvals, plans, checkpoints, todos, notifications and subagents |
| `packages/cloud` | Cloudflare Worker/Durable Object spikes; not a production cloud service |

## Development

Requirements: macOS 27, Xcode 27, XcodeGen (`brew install xcodegen`), Node ≥ 22.19, pnpm 11 (`corepack enable` provides it).

```bash
pnpm install
pnpm build
pnpm test          # engine, runtime, policy and cloud tests (scripted model; no key needed)
pnpm test:swift    # PiopioKit and PiopioTranscript tests
pnpm demo:s1       # Swift CLI ↔ engine, both runtimes, scripted model
scripts/build-app.sh   # builds the engine and Piopio.app (Debug); prints the .app path
scripts/release.sh 0.1.0   # Release app with bundled Node + engine → signed DMG (+ notarization, appcast); see docs/releasing.md
scripts/app-smoke.sh   # launches the app on a scratch data folder with the scripted model and saves a snapshot
```

Dev builds run the engine from `packages/engine/dist` with Node from Homebrew (`/opt/homebrew/bin/node`). On first launch the app lets you choose areas, connect a model provider and set up your first project, chat or agent. Set `PIOPIO_FAUX=1` (in the Xcode scheme) to use the scripted echo model instead.

To talk to a real model, store your OpenRouter key in the Keychain, then run the demo against OpenRouter:

```bash
apps/mac/.build/debug/piopio-cli key set openrouter
scripts/s1-demo.sh --real
```

Engine environment variables are documented in `packages/engine/src/main.ts`.

## Data and costs

Conversations and built-in memory are stored locally. Settings › Memory can export built-in memory as JSON and Markdown. Memory searches by words on this Mac by default; semantic search is opt-in and sends memory text and queries to the configured embeddings endpoint.

Local storage does not mean all processing stays on the Mac: remote models, web search, connected tools and auxiliary model requests can send content to external services. Auxiliary requests currently prefer OpenRouter when connected, independently of the conversation's model.

OpenRouter usage totals cover the API key, may include other apps and exclude other providers. They are not a complete total of Piopio's costs.

## License

[MIT](LICENSE)
