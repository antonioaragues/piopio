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
| **S1** Engine skeleton | ✅ with the scripted model: `piopio-cli` streams from pi-durable Threads and pi-coding-agent Build sessions over UDS JSON-RPC (`scripts/s1-demo.sh`). Fixtures recorded. The pi-durable thread path is verified against OpenRouter through the app (Phase 1.1). **Pending:** Build sessions against OpenRouter, and real-model fixtures (`RECORD_FIXTURES=real`). |
| Protocol package | ✅ TypeBox schemas + JSON Schema export. **Swift codegen pending:** Swift types are hand-written for the S1 subset. |
| **S2** Native transcript | ✅ Decision: **TextKit 2 transcript** (one `NSTextView`, custom layout fragments + attachment views for cards). SwiftUI `LazyVStack`/`List` hitch while scrolling at 2,000 items; TextKit 2 had 0 hitches. See [docs/spikes/s2](../spikes/s2/README.md). |
| **S2b** Card chrome, attachments, progressive load | ✅ Card fragments + tool-card attachment views (AppKit or SwiftUI, same cost) stay at 0–8 ms/s hitch. Prepending into a large document is O(text after the insert), so the transcript is a **windowed document** (newest 300 items, 10-item pages on demand, ~9 ms each, 0 anchor drift); tail on screen in ~140 ms for 2,000 items. 120 Hz still untested. |
| **S4** PiHarness on Cloudflare | ✅ locally (2026-10-19), in workerd via Miniflare with the faux model: `packages/cloud` (Worker + SQLite `AgentDO` on `PiHarness`, hibernatable WS with `engine.hello`/`sessions.subscribe`/`sessions.submit`). Verified: hibernation + wake on a WS message, alarm-driven resume after eviction, reconnect → fresh snapshot, OpenRouter request path from workerd (dummy key → clean 401). Token deploy script (`scripts/deploy.ts`, Cloudflare REST API) is tested against a fake API only. **Pending:** first deploy to a real account, a real OpenRouter answer (opt-in test exists), and a run longer than 15 min. See [packages/cloud](../../packages/cloud/README.md). |
| **S5** Packaging | ✅ locally (2026-10-20), ad hoc signed: a DMG installs and runs on its bundled Node + engine, and background mode (SMAppService LaunchAgent) keeps the engine running after quit. See milestone 1.5. **Pending:** Developer ID signing and notarization (needs the Apple account). |
| S3 OpenRouter details | ⏳ Not started |
| CI | ⏳ Not started (needs a macOS 27 runner for the Swift side) |

**S1 findings**
- pi 1.3.0 SDK and pi-durable share event *names* but not *shapes* (deltas in `assistantMessageEvent` vs `changes[]`, messages vs committed entries). Hence one builder with two adapters.
- pi-durable commits partial answers every 100 ms (`settings.progress`), so very short answers arrive with no deltas. Clients must render a completed message even if they never saw a delta.
- pi-durable entry ids are numbers. The protocol stringifies them.
- In SDK mode, pi still discovers user-level skills (`~/.agents/skills`) even with a custom `agentDir`. Engine tests are therefore not fully hermetic, and the fixture recorder strips system prompts.
- One `InMemoryCredentialStore`, filled on demand via the `secrets.get` reverse request, serves both pi-ai `Models` (pi-durable) and `ModelRuntime` (SDK).
- With only the Command Line Tools installed, `swift test` needs an explicit swift-testing plugin path (`scripts/swift-test.sh`). The SwiftUI app target will need Xcode.

**S4 findings**
- PiHarness runs on a plain `DurableObject` (`Lifecycle.install(this).use(harness).use(webSockets)`). The `Agent` class isn't needed.
- **Needs the `no_nodejs_global_timers` compatibility flag.** Under `nodejs_compat`, workerd timers have a no-op `unref()`. pi-durable's `unref`'d 10-minute document-sweep timer then pins the object, so it never hibernates. Without Node timers, pi-durable uses its Workers path (no timer). Worth reporting upstream.
- pi event streams are memory-only. Subscriptions are kept in the socket attachment, and every wake reopens the streams and sends a `resnapshot` (seq continues). Reconnects get a full snapshot. There is no cursor.
- An eviction mid-run aborts the alarm PiHarness awaits the run in. workerd retried it at once and pi finished the run, with the 30 s heartbeat alarm as fallback. The 15-min alarm limit is handled by a 10-min wait budget per alarm (from the source; not testable locally).
- pi-ai's OpenRouter provider runs unchanged in workerd (a dummy key reached OpenRouter and got a clean 401; a real answer is untested). Bundle: 3.3 MB, 540 KB gzipped.
- wrangler 4.151 ships Miniflare 5 (beta, new options shape: `convertV4MiniflareOptions`). `@cloudflare/vitest-pool-workers` needs vitest 4, so tests drive Miniflare from Node.

## Phase 1 — Chat: Threads (first daily driver)

**Status (2026-10-19): milestone 1.1 done.** The app (SwiftUI + XcodeGen) starts or attaches to the engine and keeps the sidebar live via `catalog.changed` (rename/delete). Threads stream into the windowed TextKit 2 transcript (`PiopioTranscript`). It has a composer (Enter send/queue, ⇧Enter newline, Esc stop), a searchable model picker per thread, a default model setting, a cost display, OpenRouter key onboarding (Keychain), and plain-text auto titles. Verified with the scripted model (`scripts/app-smoke.sh`) and by the author against OpenRouter (2026-10-19: model switch to `deepseek/deepseek-v4.1-flash`, streaming answer, cost display).
**Milestone 1.2 done (2026-10-19).**
- **Versions:** Edit and Regenerate fork the pi-durable conversation just before the user message (or start a fresh one for the first message), and a "‹ 2 / 3 ›" switcher appears under messages that have versions. Switching lands on the most recently used continuation of that version. Fork copies the thread up to an answer into a new thread (`VACUUM INTO`).
- **Thinking:** a level menu for reasoning models.
- **Queue:** the queue list shows text, and items can be removed or cleared. ⌥Enter steers the running answer.
- **Errors:** provider errors become friendly messages with a kind (auth, credits, model, rate limit, provider, network, context) and Retry / Open Settings / Details links. The duplicate "Not answered" notice is gone.
- **Reconnect:** the engine connection is restored automatically.
- The transcript has action links (Copy, Edit, Regenerate, Fork) and model/cost footers.

**Milestone 1.3 done (2026-10-19).**
- **Attachments:** images are downscaled to JPEG ≤ 2048 px by the app; PDFs are sent as text via PDFKit, and text files as-is. They're sent as content blocks with the words last, and shown as chips through a `piopio.user` display entry. Edits keep the attachments, and images need a vision model.
- **Web tools:** `web_search` uses OpenRouter's web plugin on a cheap model (`PIOPIO_SEARCH_MODEL`) and returns `url_citation` sources. `web_fetch` returns page markdown, refusing private and local addresses even through redirects. Both can be toggled per thread (globe button). Search cost isn't counted in the thread cost yet.
- **Export:** Markdown, HTML and JSONL for the active branch, plus Copy as Markdown.
- Not verified against live OpenRouter: the web plugin response format is per its docs, and the parser is unit-tested on that shape.

**Milestone 1.4 done (2026-10-20).**
- **Global search:** SQLite FTS5 (Node's built-in SQLite) in `search.db` holds titles, your messages and finished answers of each thread's active branch. It's kept current from session events, rebuilt on branch switches, and backfilled for older threads at engine start. Matching is by word prefix and ignores accents.
- **⌘K palette:** commands, threads by title and message hits in one list. ⇧⌘F opens message search; choosing a hit opens the thread, pages in older history if needed, and flashes the message.
- **Quick Chat:** a floating non-activating panel on a global hotkey (Carbon; ⌥Space by default, configurable or off). The last quick thread is reused for 10 minutes, and ⌘↩ opens it in the main window. With Quick Chat on, the app keeps running when its window closes.
- **Notifications:** sent when an answer finishes or fails while you're elsewhere; clicking opens the thread. Can be turned off in Settings.
- Not verified: the notification permission prompt and banners. Automation can't click them.

**Milestone 1.5 done (2026-10-20)**, except for notarization. See [docs/releasing.md](../releasing.md).
- **Engine bundle:** esbuild makes one ESM file (15 MB) using pi's bundled-Node mode (`PI_BUNDLED_NODE`, so user extensions get pi's packages as virtual modules). Alongside it ship the files pi reads from disk: its docs (`PI_PACKAGE_DIR`), the Photon image worker, and the Photon and QuickJS `.wasm` files.
- **Node:** 24.22.0 LTS, arm64, pinned by checksum, in `Contents/Helpers/node`. Re-signed with JIT entitlements. The app is 146 MB; the DMG is 47 MB.
- **Launcher:** `Contents/MacOS/piopio-engine` execs Node on the engine. The app runs it as a child. In background mode launchd runs it, because a LaunchAgent can only name bundle-relative programs.
- **Background mode:** Settings › Engines › Keep running when Piopio quits (off by default until Agents ships locally) registers `SMAppService.agent`. After an update, the app restarts a background engine whose version differs from its own.
- **Updates:** Sparkle 2.10.0 with EdDSA and deltas, via "Check for Updates…" and Settings › General. Updates stay off until `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY` are set.
- **Release script:** `scripts/release.sh <version>` builds, signs from the inside out, makes the DMG, notarizes and staples (with a notary profile), and runs `generate_appcast`.
- Verified with ad hoc signing: the DMG app on its bundled engine, and a full Sparkle update 0.1.0 → 0.1.1 from a localhost feed (delta download, signature check, install on quit). Ad hoc builds keep the hardened runtime off for the app, because library validation rejects an ad hoc Sparkle.framework with no Team ID; Node keeps it.
- Not verified: Developer ID, notarization and Gatekeeper. Also not shipped in the bundle: pi's codemode worker, which Build doesn't use yet.

Next: Phase 1 acceptance (a week of daily use), then Phase 2 (Build).

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
