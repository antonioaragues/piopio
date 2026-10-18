# 09 — Roadmap

Solo developer, no deadline (X9). **Start with the easiest mode.** Each phase ends with something usable every day.

## Why Chat Threads first
- **Smallest UI surface:** no file system, git, diffs or safety model.
- It still builds **most of the shared foundation**: app shell, Local Engine sidecar, Engine Protocol, transcript renderer, composer, model picker, cost tracking, search.
- It exercises **pi-durable locally from day one**. That's the riskiest dependency, and Spaces and Agents both depend on it.
- Build comes next. It reuses the transcript and adds tool renderers. Spaces and Agents reuse the pi-durable runtime.

## Phase 0 — Foundations & spikes
| Spike | Question it answers | Done when |
|---|---|---|
| **S1** Engine skeleton | Can a bundled Node sidecar host pi-durable (Node SQLite) and pi-coding-agent and talk to Swift over UDS JSON-RPC? | A Swift CLI sends `sessions.submit` and prints streamed deltas from both runtimes. Event names are recorded as fixtures. |
| **S2** Native transcript | Can SwiftUI/TextKit 2 render streaming markdown + code at 60 fps with 2,000 items? | A prototype list with recorded streams. If not, decide on a WKWebView fallback. |
| **S3** OpenRouter via pi-ai | Model list, streaming, tool calls, reasoning, cost reporting via OpenRouter in both runtimes | One call per runtime with usage + cost captured |
| **S4** PiHarness on Cloudflare | pi-durable in a DO with an OpenRouter model, hibernation, alarm wake, WS reconnect → snapshot | Deployed via API token from a script (not wrangler) |
| **S5** Packaging | Signed + notarized app with embedded Node, launch as an `SMAppService` agent | A DMG installs and the engine survives app quit |

Also: monorepo scaffold, protocol package + Swift codegen, CI (lint, tests, Swift build), MIT license, README.

### Phase 0 status (2026-10-18)
| Item | Status |
|---|---|
| Monorepo scaffold, MIT license, README | ✅ |
| **S1** Engine skeleton | ✅ with the scripted model: `piopio-cli` streams from pi-durable Threads and pi-coding-agent Build sessions over UDS JSON-RPC (`scripts/s1-demo.sh`). Fixtures recorded. **Pending:** a run against OpenRouter (`scripts/s1-demo.sh --real`, plus `RECORD_FIXTURES=real` for real fixtures). |
| Protocol package | ✅ TypeBox schemas + JSON Schema export. **Swift codegen pending:** Swift types are hand-written for the S1 subset. |
| **S2** Native transcript | ✅ Decision: **TextKit 2 transcript** (one `NSTextView`, custom layout fragments + attachment views for cards). SwiftUI `LazyVStack`/`List` hitch while scrolling at 2,000 items; TextKit 2 had 0 hitches. See [docs/spikes/s2](../spikes/s2/README.md). Follow-up **S2b**: card chrome, off-main-thread building, 120 Hz. |
| S3 OpenRouter details, S4 PiHarness on Cloudflare, S5 Packaging | ⏳ Not started |
| CI | ⏳ Not started (needs a macOS 27 runner for the Swift side) |

**S1 findings**
- pi 1.3.0 SDK and pi-durable share event *names* but not *shapes* (deltas in `assistantMessageEvent` vs `changes[]`, messages vs committed entries). Hence one builder with two adapters.
- pi-durable commits partial answers every 100 ms (`settings.progress`), so very short answers arrive with no deltas. Clients must render a completed message even if they never saw a delta.
- pi-durable entry ids are numbers. The protocol stringifies them.
- In SDK mode, pi still discovers user-level skills (`~/.agents/skills`) even with a custom `agentDir`. Engine tests are therefore not fully hermetic, and the fixture recorder strips system prompts.
- One `InMemoryCredentialStore`, filled on demand via the `secrets.get` reverse request, serves both pi-ai `Models` (pi-durable) and `ModelRuntime` (SDK).
- With only the Command Line Tools installed, `swift test` needs an explicit swift-testing plugin path (`scripts/swift-test.sh`). The SwiftUI app target will need Xcode.

## Phase 1 — Chat: Threads (first daily driver)
Scope: 04-chat §1 (T1–T12), Quick Chat (§4), 07-shared §1 (models, costs), §8 onboarding, 08-app-shell core (window, sidebar, transcript, composer, ⌘K, ⌘⇧F, notifications).
**Acceptance:** for a week the author uses Piopio instead of a web chat app. 1,000-message threads stay smooth. Forking and edit/regenerate work. Costs match OpenRouter's dashboard within 2%.

## Phase 2 — Build MVP
Scope: 05-build §1–7, §9, plus G1–G3 (local git). Bundled extensions: approvals, checkpoints, todos, notify, subagents (plan mode as opt-in). MCP in Build.
**Acceptance:** the author does real work on Piopio itself in Piopio. CLI interop works both ways. Approvals never lose a pending request across app restart. Checkpoint restore is correct on a repo with untracked files.

## Phase 3 — Chat: Projects lens + Spaces
Scope: 04-chat §2–3 (organizer, topics, routing link cards, memory, files, Thread → Space suggestion S11). Global memory (07 §5). MCP for pi-durable runtimes.
**Acceptance:** one real Space (e.g. a home project) with 5+ topics. Routing is right ≥ 90% of the time on a 50-message replay set. Rerouting works and is learned.

## Phase 4 — Agents (local)
Scope: 06-agents §2–4, §6–9, §11 local part. In-app channel + simulator, schedules, heartbeat, triggers (local URL via tunnel optional), memory partitions, **agent-to-agent**, approvals, budgets. Background mode.
**Acceptance:** two local agents run for a week on the author's Mac. Schedules fire with the app closed. Agent-to-agent delegation with loop guards is tested.

## Phase 5 — Agents (cloud) + channels
Scope: Cloud Engine (02 §5), cloud setup wizard, deploy/rollback, Telegram, WhatsApp (Cloud API + template), approvals over channels, cloud cost ledger sync, live view.
**Acceptance:** two agents live 24/7 with the Mac off. Telegram + WhatsApp both work. Owner approvals via Telegram buttons work. Agent-to-agent works in the cloud.

## Phase 6 — 1.0 polish
GitHub PR/CI loop (G4–G8), worktrees UX, usage page, export everything, accessibility pass, Sparkle + Homebrew cask, docs site.

## Later (unordered)
Mac Bridge · cloud Threads/Spaces · iOS companion · direct providers + local models + subscription logins · artifacts/canvas · code execution in Chat · email/Slack/Discord channels · group chats & agent rooms · cloud Build sessions · web preview · semantic search · OS sandbox for Build.

---

## Open questions

**None open** as of 2026-10-18. The resolved ones are below. New questions found during the Phase 0 spikes get added here.

| ID | Question | Decision |
|---|---|---|
| D5 | License | MIT |
| OQ1 | Support Intel Macs? | No, Apple silicon only |
| CQ1 | How routed topic replies appear in Main | Link card only (04-chat S1) |
| CQ2 | Suggest moving threads into a matching Space? | Yes, ships with Spaces (04-chat S11) |
| CQ3 | Web search provider | OpenRouter web plugin + optional key |
| BQ1 | Default approval mode | Auto-edit |
| BQ2 | Worktree location | App support folder |
| BQ3 | Default-on extensions | todos, notify, subagents. Plan mode off |
| AQ1 | Telegram | One bot per agent |
| AQ2 | WhatsApp | One number for a single front agent in v1 |
| AQ3 | Identity across channels | One conversation per person |
| AQ4 | Converge Spaces and Agents? | No, kept separate |
