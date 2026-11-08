# DeepSeek Harness: what Piopio could take (2026-11-08)

**Built on 2026-11-08:** everything in §1 and §2; see [As built](#as-built-2026-11-08) at the end.

A read of [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`, MIT, commit `fcc0ad46` of 2026-11-04), looking for things to bring into Piopio. Their *Exploring Super-agent Design* article already became [17-dispatch](../spec/17-dispatch.md); this note covers the code.

## What it is

A developer-preview agent harness from DeepSeek: a Node host with a Web UI, an Electron desktop app, a headless runner, a TypeScript/Python SDK and an ACP server. It's built on **Cordis**, where every part is a plugin, including the agent loop, the session log and the model adapter. There are about 300 packages: `core/`, `llm/`, `session/`, `compaction/`, `sandbox/`, `subagent/`, `goal/`, `schedule/`, `workflow/`, ~60 `client/ui-*` packages and an `experimental/` tree.

Two facts matter for us:
- **It uses pi too.** `llm-pi-ai` routes requests through `@earendil-works/pi-ai`, and the repo patches pi-ai 1.3.0 (see §1.3).
- **Its main rule is "model-visible means logged".** Anything the model sees (time, sandbox policy, injected context) is a session event, so any request can be rebuilt from the log.

## 1. Take now (small, high value)

### 1.1 A real OS sandbox for Build's shell
`sandbox/sandbox-local/src/profiles.ts` is about 60 lines. On macOS it runs commands through `sandbox-exec` with a Seatbelt profile: `(allow default) (deny file-write*)`, then allows writes to `/dev/null` and to the workspace roots. On top of that:
- **Modes:** `read-only` (the fail-safe default), `workspace-write` (plus `additionalWritableRoots`), and full access. The mode is chosen per session, recorded in the log, and survives a restart.
- **Fails loud:** with no usable runner it returns `SANDBOX_UNAVAILABLE` and never runs the command unconfined. Each run reports `full` or `partial` enforcement.
- **The model is told the policy** before each request, so it doesn't spend steps finding the limits by trial and error.
- **Permission presets** (`interaction/permission-presets`) pair sandbox and approval in one named mode. A combination no preset matches shows as "Custom".

**For Piopio:** this closes the gap that [status.md](../status.md) states ("Build policy is an approval aid, not an OS sandbox") and the "OS sandbox for Build" item in Later. Wrap pi's bash tool in `sandbox-exec` under Auto-edit, so a command you approved can only write inside the project or worktree, and escalate to an approval when it needs to write elsewhere. pi also ships `examples/extensions/sandbox` as a starting point. Caveat: `sandbox-exec` is deprecated but still works, and Codex and Claude Code use it the same way.

### 1.2 Repeated-tool-call reminder
`guard/repeat-tool-reminder`: when the model calls the same tool with the same arguments 3, 5 or 8 times, it gets a note asking it to look at the last result and either try something else or finish. The note never blocks the call. Counts are kept per agent and reset on your next message. It fits in a short pi extension (`tool_call` / `context` events).

**For Piopio:** cheap protection for agents and Build sessions running unattended, and a first signal for the Watchdog and off-track check (DP1, DP6).

### 1.3 The pi-ai patch
The patch does two things:
1. **It removes `parseStreamingJson` on every tool-call delta** (Anthropic, OpenAI completions/responses, Bedrock, Mistral, pi-messages). Re-parsing the whole growing JSON on every chunk is quadratic, and it gets slow when the model writes a large file in one `write` call. Piopio's pinned **pi-ai 1.4.0 still does this** (`dist/api/anthropic-messages.js` ~L588).
2. **It keeps Gemini's `thought_signature`** when a tool call is replayed over an OpenAI-compatible endpoint. That matters only for Gemini through a custom OpenAI-compatible endpoint, not for pi's `google` provider.

**For Piopio:** check whether anything shows *partial* tool arguments while they stream. The timeline builder reads `arguments` from finished messages. If nothing does, apply (1) as a `pnpm patch`, and better, report it upstream to pi. (2) can wait until someone uses that route.

### 1.4 A real clock for the model
`context/time-context` adds a short reading on eligible steps: the current time, the user's time zone, and how long it has been since the last message. It's added at most every 10 minutes and logged.

**For Piopio:** today the agent core (`runtime/src/agents/core.ts:570`) and web tools (`engine/src/tools/web.ts:62`) add `Today is ${new Date().toISOString().slice(0,10)}`. That has two problems:
- **It's the UTC date.** In Spain, between midnight and 01:00 (02:00 in summer) the model is told it's still yesterday, which matters for "remind me tomorrow".
- **It has no time and no gap.** A pi-durable agent or project chat picked up three days later doesn't know three days passed. Give it local date, time and zone, plus "last message 3 days ago", for Agents and long-lived chats.

## 2. Worth designing (medium)

### 2.1 Goals that keep going on their own
`goal/goal` + `goal-round-driver` + `tool-goal`: one durable objective per session ("make the test suite pass"). While the agent is idle and the goal is active, the driver gives it another turn. A round cap (256 by default) limits the runs. The agent can mark the goal **complete** or **blocked** with a code and a plain-language reason. Edits are compare-and-set, so a stale view can't overwrite a newer one. Nothing is scheduled: rounds only run while the host is up.

**For Piopio:** it's the missing piece for Dispatch workers (17-dispatch), and a "work until done" switch for a Build session ("Keep going until: …" in the composer). Show the goal, its rounds and the block reason in the session header. It reuses the budgets Agents already have.

### 2.2 Referencing another conversation, and letting the model search history
`context/session-reference`: `@conversation` in the composer adds a **bounded, read-only snapshot** of that conversation as context. The snapshot can't change after capture and carries a fixed warning that the model must not follow instructions, permission claims or tool requests inside it. Suggestions rank conversations from the same folder first.
`experimental/tool-session-query`: five read-only tools that let the model search earlier sessions, allowed only when the target has the same working directory.

**For Piopio:** we already have global search (`engine/src/search.ts`) and memory. "What did we decide about X in the other chat?" is the natural next step. Scoping by project and the untrusted-snapshot warning are the parts to copy.

### 2.3 Auto review
`experimental/auto-review`: before each tool call, the session's own model judges the pending action. An allowed call runs with full access; a denied one asks you. They ship it off and label it experimental, since it costs tokens and can be wrong either way.

**For Piopio:** a possible fourth approval mode between Auto-edit and Full, using the background-model plumbing we already have. Only worth it together with the sandbox (§1.1) as the hard limit, and in Build, where approval prompts are what wears you down.

### 2.4 Claude Code / Codex / ACP as subagents
`subagent-claude-code`, `subagent-codex`, `subagent-acp`: a delegated task runs as a fresh, unattended Claude Code, Codex or ACP session in the same workspace. Only the final answer comes back; the native login and settings stay in charge.

**For Piopio:** a `task` backend that uses the user's existing subscriptions (D2), and a natural worker type for Dispatch. The cost is a dependency on external CLIs. Let it detect `claude` / `codex` on PATH rather than bundle them.

### 2.5 Deliverables
`deliverables/tool-present`: the model calls `present` to declare final files, including files made by shell commands, and the UI shows them as cards that open the file.

**For Piopio:** we have the file viewer (D8). A `present` tool in Chat and Agents ("here's the PDF") feeds the agent Library idea from [grok-bot.md](grok-bot.md). Build already shows changed files per turn, so it gains little there.

### 2.6 Oversized tool output
`spill/spill-policy` and `compaction-tool-result-pruner`: an over-budget result keeps its head and tail, and the model gets the path to a file with the full result. Text and images share one token budget. `compaction-image-offload` replaces old images with their file paths when a route rejects a request for too many images, then retries.

**For Piopio:** pi already truncates bash and read output. The gap is our own tools (MCP, `web_fetch`, connectors) and image-heavy chats. Apply the head/tail + path rule to the MCP bridge.

## 3. Skip, or keep for later

| Item | Why not now |
|---|---|
| Cordis "everything is a plugin" | Huge flexibility at a huge cost (~300 packages, generated docs, i18n for every file). Piopio is a product with one Swift app and one engine; pi extensions are plugin enough. |
| Versioned session format and migration chain | pi and pi-durable own the session format. The **principle** is worth adopting: anything Piopio adds to what the model sees (memory, about-me, time, policy) should be logged so a turn can be replayed. |
| `workflow` / PTC (`run_code` programs that fan out subagents) | Powerful, but they gate it behind explicit requests, and Dispatch covers the need in a way you can see. Revisit for big agent jobs. |
| Agent Teams task board | Only after Dispatch; members share one checkout, while our workers use worktrees. |
| Forge (PR/MR provider) | Useful detail for G6–G8 / DP5: one shared polling loop per PR whose interval follows CI, mergeability and state. Not a package to port. |
| Liveshare | Needs a hosted server; we stay local. |
| Claude Code hooks compatibility | Niche: it runs your `hooks.json` from Claude Code inside dsh. |
| Office skills + LibreOffice | A heavy bundle. Skills can arrive through D9 if needed. |
| Voice input (SenseVoice) | For D5, Apple's on-device speech recognition is the better fit on macOS. |
| Chain-of-thought translation, action cards, creation recommendations | Piopio already has follow-up chips; low value. |
| Schedule | We have it. One rule to check against ours: after a restart a recurring task runs **only its latest** missed occurrence. |

## Suggested order

1. Sandbox for Build's shell (§1.1). It closes a stated boundary and is small.
2. The time fix (§1.4) and the repeat reminder (§1.2), each a short task.
3. The pi-ai streaming patch, after checking that nothing uses partial arguments (§1.3).
4. Goals (§2.1), designed as part of Dispatch DP2–DP4.

## As built (2026-11-08)

| Idea | What Piopio does now | Where |
|---|---|---|
| §1.1 Sandbox | Build's `bash` runs in a Seatbelt profile in Ask and Auto-edit: writes only in the project/worktree, its git folder, temp folders, `/dev` and package caches. A blocked write tells the model about `outside_project: true`, which always asks. Fails loud. Settings › Approvals › "Keep commands inside the project" (default on). | `extensions/src/sandbox.ts`, spec 05 AP5 |
| §1.2 Repeat nudge | 3rd, 5th, 8th identical call since your last message: a note on that result. Chats, agents and Build. | `runtime/src/context/repeats.ts` |
| §1.3 pi-ai patch | Per-chunk re-parse of tool-call JSON removed (Anthropic, OpenAI completions/responses, Bedrock, Mistral, pi-messages). The Gemini `thought_signature` part was left out (no route uses it). | `patches/`, `pnpm-workspace.yaml` |
| §1.4 Clock | A user message after a 15-minute pause, on a new local day, hourly, or the first one, starts with `[Sent Sun 8 Nov 2026, 14:05 (Europe/Madrid), 3 days after the previous message]`, worked out from timestamps (no new state; cache-stable). "Today is" now uses the local date. Build had no date before. | `runtime/src/context/clock.ts` |
| §2.1 Goals | `/goal`, `update_goal`, rounds as their own runs (pi's `agent_settled` + a displayed custom message), 25 rounds, Stop pauses. Build only. | `extensions/src/goal.ts` |
| §2.2 Earlier conversations | `search_conversations` / `read_conversation` (Build: the same project; chats without a project: each other; agents: none), framed as untrusted background. In Build, `@` also suggests the project's sessions; `@conversation:<id>` adds a bounded snapshot as a displayed note kept in the session. | `engine/src/tools/history.ts`, `Composer.swift` |
| §2.3 Auto review | Auto-edit only, commands only, session's own model, default off. | `extensions/src/review.ts`, spec 05 AP6 |
| §2.4 Claude Code / Codex | `task` takes `agent: "claude" | "codex"` when the CLI is found; Claude Code through `-p --output-format stream-json`, Codex through `exec --output-last-message`; their permission mode follows the session's. | `engine/src/external-agents.ts`, spec 05 AP7 |
| §2.5 Deliverables | `present_files` in Build: a card per file that opens in the viewer; missing files say so. | `extensions/src/present.ts`, `ItemRenderer.fileCard` |
| §2.6 Oversized output | Chats and agents: a result over 40,000 characters or 1,800 lines keeps its start and end (pi-durable alone kept only the start). Build already had pi's bound with a full-output file. | `runtime/src/context/spill.ts` |

**Sandbox trial (2026-11-08):** real runs through the same profile, one project each: npm (a native module, `npx`), pnpm (`add`, `dlx`), Go (modules, build, test, vet), pip in a venv, SwiftPM (`build`, `test`, `run`), `xcodebuild` (a package's build and test, Piopio's own `scripts/build-app.sh`), git, brew and the repo's typecheck. No new cache folder was needed. Writes outside the project were blocked as meant (`pip install --user`, a file in the home folder). One thing broke: SwiftPM and `xcodebuild` start their own sandbox for manifests and plugins, and macOS refuses one inside another (`sandbox_apply: Operation not permitted`). Confined commands now find `swift` and `xcodebuild` through wrappers that turn theirs off (`--disable-sandbox`, two Xcode settings and `XBS_DISABLE_SANDBOXED_BUILDS`), and any other tool that hits it gets its own hint instead of the one about `outside_project`. Not tried: cargo (not installed here).

**Not verified:** a real Claude Code run (the arguments match `claude --help` 2.1; the tests use a stand-in), any Codex run (not installed here), and auto review with a real model. **Not done:** goals, `present_files` and `@conversation` in chats and agents; a goal indicator outside the transcript.
