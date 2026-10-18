# Piopio

A native macOS app with a front-end for the [pi](https://pi.dev) agent harnesses (`pi-coding-agent` and `pi-durable`), with three modes:

- **Build**: an agent-first development environment (projects → sessions, diffs, approvals, git/GitHub).
- **Chat**: threads, folder projects, and Spaces where an organizer agent routes your messages to topics.
- **Agents**: personal agents that are proactive, live in Telegram/WhatsApp, run on schedules, talk to each other, and run 24/7 on your own Cloudflare account.

Models come through OpenRouter (bring your own key).

> Status: **Phase 0**: foundations and spikes. Nothing is usable yet.

See the full specification in [docs/spec](docs/spec/README.md).

## Repository

| Path | What |
|---|---|
| `apps/mac` | Swift package: `PiopioKit` (engine client, protocol types, transcript, streaming markdown), `piopio-cli`, and `TranscriptLab` (rendering benchmarks, spike S2). The SwiftUI app target comes in Phase 1 and needs Xcode. |
| `packages/protocol` | Engine Protocol schemas (TypeBox → JSON Schema) |
| `packages/engine` | Local Engine: Node daemon hosting pi-durable (Threads) and pi-coding-agent (Build) behind JSON-RPC over a Unix socket |
| `packages/runtime`, `packages/cloud`, `packages/extensions` | Placeholders for later phases |

## Development

Requirements: macOS 27, Node ≥ 22.19, pnpm 11 (`corepack enable` provides it), Swift 6.2+ (Command Line Tools are enough for now).

```bash
pnpm install
pnpm build
pnpm test          # engine tests (scripted model, no key needed)
pnpm test:swift    # PiopioKit tests
pnpm demo:s1       # Swift CLI ↔ engine, both runtimes, scripted model
```

To talk to a real model, store your OpenRouter key in the Keychain, then run the demo against OpenRouter:

```bash
apps/mac/.build/debug/piopio-cli key set openrouter
scripts/s1-demo.sh --real
```

Engine environment variables are documented in `packages/engine/src/main.ts`.

## License

[MIT](LICENSE)
