# 02 — Architecture

## 1. Component overview

```
┌──────────────────────────── Piopio.app (SwiftUI, macOS 27+) ────────────────────────────┐
│  UI: Build · Chat · Agents · Settings · Quick Chat panel · Menu bar extra               │
│  PiopioKit (Swift package): EngineClient, generated protocol types, stores (@Observable)│
└──────────────┬───────────────────────────────────────────────────────┬──────────────────┘
               │ JSON-RPC 2.0 over Unix domain socket                    │ JSON-RPC 2.0 over WSS
               ▼                                                         ▼
┌──────────── Local Engine (Node, bundled) ──────────┐   ┌──────── Cloud Engine (user's Cloudflare) ────────┐
│ engine-core: catalog DB, routing, approvals, FTS   │   │ Worker "piopio-cloud"                             │
│ ├─ BuildRuntime   → pi-coding-agent SDK            │   │ ├─ Gateway: auth, Engine Protocol over WS         │
│ ├─ ThreadRuntime  → pi-durable (Node SQLite)       │   │ ├─ Channel webhooks (Telegram, WhatsApp)          │
│ ├─ SpaceRuntime   → pi-durable (Node SQLite)       │   │ ├─ RegistryDO (agents, routing, secrets, deploys) │
│ ├─ AgentRuntime   → pi-durable (Node SQLite) [dev] │   │ ├─ AgentDO × N → PiHarness (pi-durable)           │
│ ├─ Git/GitHub, FS watch, checkpoints               │   │ └─ R2 (attachments), optional Sandbox/Containers  │
│ └─ CloudLink: deploy + proxy to Cloud Engine       │   └───────────────────────────────────────────────────┘
└────────────────────────────────────────────────────┘
          ▲ shared TS package: @piopio/runtime (Spaces/Agents logic, runs in Node AND Workers)
```

## 2. Repository layout (monorepo)

```
piopio/
├─ apps/mac/                 Xcode project: Piopio.app, PiopioKit (SPM), QuickChat, MenuBar
├─ packages/
│  ├─ protocol/              Engine Protocol schemas (TypeBox) → JSON Schema → Swift codegen
│  ├─ runtime/               Isomorphic: Space organizer, Agent runtime, channel adapters, memory, schedules
│  ├─ engine/                Local Engine (Node daemon)
│  ├─ cloud/                 Cloud Engine (Worker + DOs, wrangler config, deploy bundle)
│  └─ extensions/            Pi extensions shipped by Piopio (approvals, checkpoints, plan, todos…)
├─ docs/spec/
└─ scripts/                  build, bundle node, codegen, release
```

- TypeScript side: **pnpm** workspaces (the pi-durable samples use pnpm 11), Node ≥ 22.19, `tsup`/`esbuild` bundling, Vitest.
- Swift side: Swift 6 with strict concurrency, SwiftUI + Observation, SPM for dependencies.

## 3. Mac app (Swift)

### 3.1 Layers
- **PiopioKit**
  - `EngineClient`: a JSON-RPC client with request/response correlation, notification fan-out, reconnect with backoff, and backpressure. One client per engine (local, cloud).
  - `Protocol` types: **generated** from `packages/protocol` JSON Schema (CI fails if they drift).
  - Stores: `@Observable` classes (`CatalogStore`, `SessionStore`, `ApprovalStore`, `ModelStore`, `AgentStore`…). They hold **projections** of engine state. The engine is the source of truth.
- **UI**: SwiftUI views, with AppKit bridges where SwiftUI falls short: the **transcript is a TextKit 2 document** (Spike S2), plus text input with completion and the terminal.

### 3.2 Key libraries (to validate in Phase 0)
| Need | Candidate | Notes |
|---|---|---|
| Markdown rendering (streaming) | `PiopioKit.MarkdownStream` (block splitter) + Foundation inline markdown → `NSAttributedString` in a **TextKit 2** `NSTextView` | Decided in Spike S2 (docs/spikes/s2) |
| Code highlighting | tree-sitter (SwiftTreeSitter) or Highlightr | Prefer tree-sitter for diffs too |
| Terminal | SwiftTerm | Local PTY in v1 (see 05-build) |
| Diff view | Custom, on top of tree-sitter highlighting | Side-by-side + unified |
| Auto-update | Sparkle 2 | |
| Global hotkey | KeyboardShortcuts (sindresorhus) | |
| Keychain | Security framework wrapper | |

### 3.3 App lifecycle
- The app starts or attaches to the Local Engine at launch.
- **Background mode** (setting, default ON once Agents ships locally): the engine is registered as a **LaunchAgent via `SMAppService.agent`**, so schedules and local agents keep running after the app quits. Otherwise the engine lives and dies with the app.
- Menu bar extra: running sessions, pending approvals, agent status, quick chat entry point.

## 4. Local Engine (Node)

### 4.1 Packaging
- A pinned Node runtime (≥ 22.19, **arm64 only**: Piopio supports Apple silicon only) is shipped in `Piopio.app/Contents/Resources/engine/node`, plus a single bundled `engine.mjs` and native deps (e.g. `better-sqlite3` if `node:sqlite` isn't enough).
- Code-signed and notarized with the app (hardened runtime, JIT entitlement for Node).
- Users can point to a **custom engine build** (dev setting) to hack on the engine without rebuilding the app.

### 4.2 Transport & auth
- JSON-RPC 2.0, newline-delimited, over a **Unix domain socket** at `~/Library/Application Support/Piopio/engine.sock` (mode 0600). Swift side uses Network.framework (`NWEndpoint.unix`).
- On connect, the client sends `engine.hello` with a token read from `engine.token` (0600). This guards against other local processes on the same user account to the extent the file permissions allow.
- **Single owner:** one engine process per user. A lock file prevents two engines (pi-durable storage allows only one owner process per storage).

### 4.3 Internal modules
| Module | Responsibility |
|---|---|
| `catalog` | SQLite DB (`catalog.db`): projects, threads, spaces, agents, session index, settings, model cache, cost ledger, FTS5 index |
| `runtimes/build` | Wraps `createAgentSession` per Build session. Event normalization. Approval bridging. |
| `runtimes/thread`, `runtimes/space` | Open/close pi-durable harnesses lazily, with an LRU of open harnesses (default max 16) |
| `runtimes/agent` | Same `@piopio/runtime` agent code the cloud uses, on Node SQLite storage; local "simulator" channel |
| `approvals` | Central queue of pending approvals across all runtimes. Policy evaluation. |
| `models` | OpenRouter catalog fetch/cache, pricing, capability flags, key access |
| `git` | git CLI wrapper, worktrees, diff, status, shadow-repo checkpoints |
| `github` | `gh` passthrough or REST/GraphQL via device-flow token |
| `fswatch` | FSEvents (via `fsevents`/chokidar) for open projects |
| `indexer` | Feeds FTS5 from normalized timeline items |
| `cloudlink` | Cloudflare API deploys, Cloud Engine connection, proxying of cloud sessions for the app |
| `secrets` | Requests secrets from the app (Keychain lives in the app, see §7) |

### 4.4 Event normalization
pi-coding-agent and pi-durable emit different event shapes. The engine maps both into one **Timeline** model (03-engine-protocol §4), so the app has a single transcript renderer. Mappers are pure functions with fixture-based tests recorded from real sessions.

## 5. Cloud Engine (Cloudflare)

### 5.1 Topology (one deployment per user)
- **Worker `piopio-cloud`** (a prebuilt bundle shipped inside the app, versioned with the app).
  - `GET /v1/ws`: Engine Protocol over WebSocket (hibernatable). Auth: owner bearer token.
  - `POST /v1/channels/telegram/:agentId`: Telegram webhook (secret-token header verified).
  - `GET|POST /v1/channels/whatsapp`: Meta webhook (verify token + `X-Hub-Signature-256`).
  - `POST /v1/triggers/:agentId/:triggerId`: generic webhook triggers (HMAC).
- **`RegistryDO`** (singleton): agent list, active definition versions, channel routing table (`telegram bot → agent`, `wa phone_number_id → agent`), contacts, encrypted channel credentials, deploy history.
- **`AgentDO`** (one per agent, keyed by agent id): `PiHarness` with pi-durable on DO SQLite. Holds the conversations, memory docs, schedules and run log for that agent.
- **R2 bucket** `piopio-files`: attachments, media from channels, exports.
- **Optional:** Cloudflare Sandbox/Containers for heavy tools (later). AI Gateway for logging/caching (optional).

### 5.2 Deploy model
- **Infrastructure deploy** (rare: first setup and app updates). The app uses the Cloudflare API with a user-provided API token (scopes: Workers Scripts edit, Durable Objects, R2, Workers Routes optional) to upload the Worker bundle, migrations and bindings, and to set secrets (`OWNER_TOKEN`, `MASTER_KEY`, `OPENROUTER_API_KEY`).
- **Agent deploy** (frequent). Agent definitions are **data, not code**: pushing an agent is an authenticated RPC (`agents.deploy`) to the Worker. No Worker redeploy.
- Custom agent tooling is limited to what can run safely without redeploying code: built-in tools, remote MCP servers, HTTP tool, codemode (sandboxed JS). See 06-agents.

### 5.3 Limits to design around (from the PiHarness docs)
- An alarm invocation runs at most 15 min, and the harness hands off every 10 min. Model streams over 15 min can be cut off.
- Event streams can't resume from a cursor, so a reconnect gets a fresh snapshot.
- No built-in tool approval. We implement approvals ourselves (06-agents §9).
- Sessions can't be deleted yet. Agent deletion is done by tombstoning plus wiping DO storage (`deleteAll`).
- Background task completion may be detected up to ~30 s late.

## 6. Storage layout (local)

```
~/Library/Application Support/Piopio/
├─ catalog.db                      app catalog + FTS + cost ledger
├─ engine.sock / engine.token / engine.lock
├─ threads/<threadId>.sqlite       pi-durable session per thread
├─ spaces/<spaceId>.sqlite         pi-durable session per space
├─ spaces/<spaceId>/files/         space knowledge files
├─ agents/<agentId>/               local agent workspace (definition repo + dev session db)
├─ checkpoints/<projectId>.git     shadow git dirs for checkpoints
├─ worktrees/<projectId>/<sessionId>/
└─ logs/
~/.pi/agent/sessions/…             Build sessions (pi CLI-compatible, owned by pi)
~/Piopio/Agents/<slug>/            (optional, user-visible) agent definitions as files, git-versioned
```

All formats are SQLite or JSONL/JSON/Markdown, so everything stays inspectable and exportable.

## 7. Security model

- **Secrets** live in the **macOS Keychain**, owned by the app. The engine asks for them over the protocol (`secrets.get`, scoped and cached in memory only). Inherited env vars are never logged. For the cloud, secrets are pushed as Worker secrets or encrypted (AES-GCM, `MASTER_KEY`) in RegistryDO.
- **Local tool execution** (Build) runs as the user, with approval modes (05-build §6). OS sandboxing (Seatbelt profiles) is later.
- **Cloud auth:** a single owner token (256-bit), generated at infra deploy and stored in Keychain. Rotatable. A future iOS app pairs by QR code with the owner token.
- **Channel security:** verify every webhook signature. Contacts are allowlisted: unknown senders get a configurable reply ("I don't talk to strangers") and are logged for the owner to approve.
- **Prompt-injection posture:** content from channels, the web and email is untrusted. Sensitive tools need approval regardless of who asked (06-agents §9).

## 8. Observability
- Engine logs: structured JSON, rotated, viewable in the app (Settings › Advanced › Logs).
- Cost ledger: every model call records `{container, model, tokens in/out/cache, $}`, using pi usage docs (`pi.usage`) and OpenRouter's returned cost.
- Cloud: run log per agent in AgentDO, streamed to the app when it's connected.

## 9. Testing strategy
- **Protocol:** schema snapshot tests; Swift decoding tests generated from fixtures.
- **Event mappers:** recorded pi/pi-durable event fixtures → expected Timeline items.
- **Runtime:** pi-durable storage conformance is already upstream. Our Space/Agent logic is tested with a fake model provider and fake clock (pi-durable supports overriding `now`/`setTimer`).
- **Cloud:** `wrangler dev` / Miniflare integration tests for webhooks, alarms and DO RPC.
- **App:** snapshot tests for transcript components, UI tests for core flows.

## 10. Risks & mitigations
| Risk | Mitigation |
|---|---|
| pi-durable API churn (experimental) | Pin versions. All pi-durable calls go through `@piopio/runtime` adapters. Upgrade deliberately. |
| Native streaming markdown performance on long transcripts | Spike S2 early. Fallback: a WKWebView transcript behind a protocol. |
| Bundled Node size (~100 MB) | Acceptable for a dev tool. Revisit Node SEA or Bun later. |
| WhatsApp policy (24h window, templates) | Telegram is the primary proactive channel. WhatsApp templates are supported (06-agents §5.3). |
| Cloudflare limits (15-min alarms, no bash) | Long work split into durable tasks. Heavy work → Sandbox/Containers (later) or Mac Bridge. |
