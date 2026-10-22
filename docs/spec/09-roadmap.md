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

Milestones (each one usable on its own):
| | Scope |
|---|---|
| **2.1** Projects & sessions | Add a folder as a Project (BP1). Sessions per project, with pi CLI sessions discovered on disk and resumable (BP2, BP3). Session view with tool cards: read, edit/write with inline diff, bash with output and exit code, generic (BR1). Context meter (BR7). |
| **2.2** Approvals | `piopio-approvals` with the three modes, approval card, rules, deny-list, "waiting for you" (§6). `piopio-notify` (`ask_user`). Pending approvals survive an app restart. |
| **2.3** Checkpoints & review | Shadow-git checkpoints, checkpoint dividers and restore (§7). Inspector: Changes, Checkpoints, Context, spend. Diff review with comment-on-diff (BR2, BR3, 4c). |
| **2.4** Git & new session | Git status, branch switcher, commit with a generated message, push/pull (G1–G3). New-session sheet (7a) with worktrees (BP5) and merge/discard. |
| **2.5** Composer & extensions | @-mentions, /commands, prompt templates and skills (BR5). `piopio-todos`, `piopio-subagents`, `piopio-plan`. Session tree (BR6). |
| **2.6** Terminal & MCP | Terminal drawer (§9, 6b). MCP in Build. File viewer and Open in editor (BR4). |

**Milestone 2.1 done (2026-10-20).**
- **Projects:** `projects.add/list/remove` (in `projects.json`, keyed by real path) with the git branch (read from `.git/HEAD`, worktrees too), `AGENTS.md`/`CLAUDE.md` and `.pi/` detection. Add a project with ⌘O, the sidebar +, or by dropping a folder on the Build empty state.
- **pi CLI interop (BP3):** sessions are read from pi's own folder for each project (`~/.pi/agent/sessions/--path--`), on add, at engine start, and live through a recursive file watcher. Sessions started with `pi` show up, titled by their name or first message, and resume in Piopio. Moving a session to the Trash moves its file to `~/.Trash`, because otherwise it would be found again. Imported sessions start on Piopio's default model.
- **Tool cards (BR1):** `edit` shows pi's unified patch and `write` the new file, both as diff rows (open by default, with the first 12 lines and "N more lines"). `bash` shows the command, terminal-styled output, and the exit code (red when nonzero). `read` shows path:lines; `grep`, `find` and `ls` get plain titles. Details are rebuilt from the session file on reopen (the exit code is parsed from the output there). Cards keep the reader's open/closed choice while a tool updates.
- **Context meter (BR7):** `SessionState.context` from pi's `getContextUsage()`, shown as a chip in the composer.
- Build transcripts hide Edit/Regenerate/Fork (pi's session tree comes in 2.5). Dropping a file in the composer inserts its project-relative path.
- The scripted model can drive tools (`$ cmd`, `read:`, `write:`, `edit:` lines) for tests and captures.
- Verified: engine tests (project add/import/watch/delete/forget; scripted read/edit/write/bash with details surviving a restart) and app captures with the scripted model, light and dark. **Not verified:** a real model doing Build work in the app, and a live `pi` CLI session appearing while the app is open (the same path is covered by the engine test).

**Milestone 2.2 done (2026-10-20).**
- **`@piopio/pi-extensions`** (`packages/extensions`): `approvalsExtension` (pi `tool_call` hook) and `notifyExtension` (`ask_user`, `notify_user`). They also work in the pi CLI through pi's dialogs. The policy is pure and unit-tested: modes per §6, rules (command prefix, where every part of a compound command must match; tool; path glob), and a deny-list that always asks (sudo, force-push, `curl | sh`, keychain, credential folders, `rm -rf` outside the project).
- **Engine:** a prompt broker per Build session. Pending approvals, questions and extension dialogs live in `SessionState.prompts`, and the session status is `waiting_approval` while any are open. `sessions.respond` answers, and a stop cancels them (the tool shows as stopped). Denials reach the agent with your note, and tool cards show "denied" after a reload too. Extensions get a `ctx.ui` bridge (confirm/select/input/notify become prompts and notes; terminal-only UI shows a one-time notice) and now receive `session_start` through `bindExtensions`.
- **Modes and rules:** per session (`sessions.configure`) and per project default (`projects.configure`). The global default is Auto-edit. "Always for …" adds a project rule. Settings › Approvals edits defaults and removes rules.
- **App:** the approval card above the composer (2a: accent halo, command, reason when the deny-list applies, Deny with an optional note, Always for …, Allow once ⌘↩). There's a question card (options and a free answer), confirm/select/input cards, the mode pill in the header, an amber status dot and "waiting for you", and tool cards that read waiting, denied or stopped. Notifications fire when a session waits for you or calls `notify_user` while you're elsewhere (engine `session.attention`). A quit warning appears when sessions are working or waiting, unless the engine runs in the background.
- **Acceptance note:** a pending request survives an app restart while the engine keeps running (background mode, or the app reconnecting to it). If the engine itself stops, the request is cancelled and the tool shows as stopped; the quit warning says so.
- Verified: 19 policy tests, 4 engine tests (always-rule reused by a new session, a second client seeing the pending prompt, deny-list in full auto with a note and "denied" after restart, ask mode, mode switch, ask_user, stop while waiting), and app captures with the scripted model. **Not verified:** the approval flow with a real model, and the notification banners.

**Milestone 2.3 done (2026-10-20).**
- **Checkpoints (CK1–CK3):** a shadow git repository per folder (`<data>/checkpoints/<hash>.git`, work tree = the project; the user's repo is never touched). Untracked files are included; `.gitignore`, a default list (node_modules, .build, DerivedData, venvs…) and a 20 MB per-file cap keep it light. It's isolated from the user's git config and hooks, and retains the newest 50 plus anything from the last 14 days. `checkpointsExtension` snapshots before the first `edit`/`write`/`bash` of each run ("Session start", then "Before turn N").
- **Timeline:** `checkpoint` items, persisted as pi custom entries (not sent to the model) and placed before the change they precede, live (`item.added` with `before`) and on reload. In the transcript a hairline divider with "Restore…".
- **Changes and restore:** `sessions.changes` (whole session or last turn, with line counts), `sessions.diff`, and `sessions.restore` (dry run, all files or some). A restore first checkpoints "Before restore", then puts files back (deleting files created since), and tells the agent which files changed through a displayed custom message that the model sees.
- **App:** the inspector (2a): Changes with totals and per-file revert, Checkpoints with "Restore to here…", Context bar and session spend, toggled from the header. A restore confirmation lists the exact files. Diff review (4c) replaces the transcript: Whole session / Last turn, file list with counts, Unified/Split with line numbers, Restore checkpoint…, and click a line to comment → "Ask agent ↩" sends a follow-up quoting the file, line and code.
- Not in this milestone: Stage and Commit (2.4, with git).
- Verified: checkpoint store test (untracked, ignored and excluded files, partial and full restore, the user's repo untouched, a missing checkpoint), an engine test (placement live and after restart, changes since session/turn, diff, dry run, restore with note), a diff parser test, and app captures. **Not verified:** a large repository's snapshot time, and real-model sessions.

**Milestone 2.4 done (2026-10-20).**
- **Git (G1–G3):** `git.status` (porcelain v2: branch, upstream, ahead/behind, files incl. untracked and conflicts), `git.branches`, `git.checkout` (switch or create, with branch-name validation), `git.commit` (all changes, or chosen files with `--only`; amend), `git.sync` (push creates the upstream on first push; pull is fast-forward only; fetch). Git runs with the user's own config and credential helpers, never prompts (clear errors suggest `gh auth login` or SSH keys), and only in project folders and session worktrees.
- **Commit messages:** `git.message` writes one from the diff of the chosen files (read-only: the user's index isn't touched) and the repo's recent subjects, using the utility model (Claude Haiku 5.5 on OpenRouter, `PIOPIO_UTILITY_MODEL` to change). The scripted model gets a plain "Update …" summary.
- **Worktrees (BP5):** `sessions.create` takes `workOn` (current, a new branch in the project, or a worktree at `<data>/worktrees/<project>/<session>` on a new branch from the current one) and an approval mode. `sessions.finish` merges into the base (requires a clean worktree and the project on the base branch; aborts on conflicts) or discards, removes the worktree and its branch, and the session goes on in the project folder. Worktree sessions use their project's approval rules.
- **App:** the branch pill is a git menu (ahead/behind, changed count, Commit…, Push/Pull/Fetch, switch or create a branch, Merge into base… / Discard worktree… for worktree sessions), with results shown under the header. The inspector has Commit…. The commit sheet has file checkboxes, ✨ Generate, Amend, Commit and Commit & Push/Publish. The new session sheet (7a) opens from ⌘N in Build, the project menu or the empty state: prompt first, Work on New branch / Worktree / Current branch with a suggested `piopio/…` name, permissions, model, and context chips; per-project defaults. Worktree sessions are marked in the sidebar, and finished ones show a note.
- Not in this milestone: Create PR and GitHub auth (G4–G8, Phase 6). Commit messages from a real model are untested.
- Verified: 3 engine tests (worktree session edit → commit → merge with cleanup; discard; new branch; status, partial commit, first push with upstream, branches, invalid names, folder guard) and app captures.

**Milestone 2.5 done (2026-10-20).**
- **@-mentions (BR5):** `projects.files`: git's file list when it's a repository (so .gitignore applies), else a bounded walk; folders included; fuzzy match favoring file names and word starts. The composer suggests as you type `@…` (↑↓, ↩/⇥ to insert `@path`).
- **/commands (BR5):** `sessions.commands` lists pi prompt templates, skills (`/skill:name`) and extension commands; they're sent as typed and pi expands them. Piopio's own commands run in the app: /plan, /compact, /model, /tree, /review, /commit, /new.
- **`piopio-todos`:** the agent's checklist, shown as a card and in the inspector (`SessionState.todos`, also after a reopen).
- **`piopio-plan`:** plan mode per session (Plan chip, /plan, `sessions.configure planMode`). Edits, writes and commands that aren't read-only are refused with a reason. `propose_plan` shows a plan card (numbered steps, Keep planning with a note, Approve and build ⌘↩); approving turns plan mode off.
- **`piopio-subagents`:** `task` runs a child Build session (same folder, model and approval mode; one level deep; at most 3 at a time per session). Its progress shows on the task card, with Open to see the child, which is nested under its parent in the sidebar. Its final answer goes back to the parent, and its cost counts toward the parent's spend.
- **Session tree (BR6):** `sessions.tree` (your messages, indented at branch points, current path marked) and `sessions.navigate` (pi's navigateTree; the message's text comes back to the composer, so sending branches). A header button and /tree open it. `sessions.compact`. The timeline is rebuilt after a compaction or a jump, so ids stay consistent.
- Verified: 5 engine tests (todos across a reopen; plan mode refusals, read-only commands, approval turning it off; a subagent's child session; tree navigation and branching; commands and fuzzy file search), the read-only command policy test, and app captures. **Not verified:** pi project prompt templates and skills from `.pi/` (pi may want the project trusted first), and real-model behavior with these tools.

**Milestone 2.6 done (2026-10-20). Phase 2's scope is complete;** its acceptance (real work on Piopio in Piopio) is next.
- **MCP in Build:** sessions load pi's built-in `mcp`, `codemode` and `tool-search` extensions like the pi CLI does, reading the same `~/.pi/agent/mcp.json` and the project's `.pi/mcp.json`. MCP tools reach the model through codemode by default (or directly, per pi's `exposure`). The release bundle now includes pi's codemode worker. MCP and codemode cards get readable titles. Settings › MCP servers lists global and project servers, enables, disables, removes and adds them (command or URL), writing those files.
- **Project trust:** sessions now resolve pi project trust like the CLI (the closest saved decision in `~/.pi/agent/trust.json`, else `defaultProjectTrust`). Before this milestone the SDK silently trusted every project. Untrusted projects don't load their `.pi` extensions, settings, MCP servers, prompts or skills. A banner asks when a project has such resources and no decision; Settings › Approvals changes it. The decision is shared with the pi CLI.
- **File viewer (BR4):** `projects.readFile`/`writeFile` (limited to the project or worktree, text only, 2 MB). Opens from read/edit/write cards ("Open", at the read's line). Line numbers, highlighting, quick edit with ⌘S, and Open in the installed editors.
- **Open in editor:** Zed, VS Code, Cursor (at the line through URL schemes), Xcode and Sublime Text. A header pill opens the project; Settings › General chooses the editor.
- **Terminal drawer (§9, 6b):** SwiftTerm (1.11.2; 1.12+ needs the Metal toolchain) login shells in the session's folder. ⌃\` or the header button toggles it, with several tabs, Send to agent (selection or last 60 lines into the composer) and Stop ⌃C. Terminals live per folder for the app's lifetime and close on quit.
- Verified: 3 engine tests (a real stdio MCP server reached by a Build session plus the mcp.json edits; trust gating `.pi` prompts and saved in pi's trust.json; file read/write and the outside-path guard), MCP through the bundled engine, and app captures. **Not verified:** codemode with a real model, OAuth MCP servers (sign-in happens in pi's browser flow), and the drawer's resizing.

## Phase 3 — Chat: Projects lens + Spaces
Scope: 04-chat §2–3 (organizer, topics, routing link cards, memory, files, Thread → Space suggestion S11). Global memory (07 §5). MCP for pi-durable runtimes.
**Acceptance:** one real Space (e.g. a home project) with 5+ topics. Routing is right ≥ 90% of the time on a 50-message replay set. Rerouting works and is learned.

Milestones:
| | Scope |
|---|---|
| **3.1** Projects in Chat | Project lenses (P1: detected, switchable, both). Chat profile for sessions: no bash, web tools, knowledge-assistant prompt (P2). Chat sidebar Projects section. File browser, preview pane (markdown, PDF, images) and changed files (P3). |
| **3.2** Spaces core | Space = one pi-durable session: Main (organizer) + topic conversations. Organizer tools route/create/answer; link cards with live status; topic view; sidebar with nested topics and unread dots; `@topic`, `/new`, `/main`; reroute that's learned (S1–S4, S6, S10). |
| **3.3** Memory, files, housekeeping | Space memory doc with history and editor (S8), `update_memory` / `propose_memory`, `ask_topic`, `search_space`, rename/archive/merge, topic summaries, Space files and settings, header (S7, S9, §3.5–3.6). |
| **3.4** Conversions and suggestion | Convert threads to a Space (S5), Promote topic to thread, Thread → Space suggestion (S11), global memory (07 §5), MCP for pi-durable runtimes, the 50-message routing replay set. |

**Milestone 3.1 done (2026-10-20).**
- **Lenses (P1):** a project has `lenses` (build, chat or both). New projects get the detected one (a `.git` folder or code files → build, otherwise chat) plus the mode they were added from. The Build and Chat sidebars show their own projects; the context menu shows a project in the other mode too, or only in this one.
- **Chat profile (P2):** `sessions.create profile: "chat"` gives a session read, write, edit, grep, find and ls, but no bash, plus `web_search` and `web_fetch` (the same tools as Threads), with a knowledge-assistant section in the system prompt. Sessions are tagged with their profile and appear under their project in both modes; Build-profile sessions show a hammer in Chat.
- **Chat lens UI (P3):** the Chat sidebar has a Projects section (add a folder, new session). The session view drops the terminal, git and editor pills. The inspector has Files (a lazy tree from `projects.listDir`) and Changes. Picking a file opens a preview: markdown in the transcript's style, PDF, images, or other text, with "Ask about this" (an @-mention in the composer) and "Open in".
- Verified: 2 engine tests (lens detection and switching; a chat-profile session reaches grep and web_fetch and has no bash; listDir), and app captures. **Not verified:** the knowledge-assistant prompt with a real model, and large folders in the file tree.

**Milestone 3.2 done (2026-10-21).**
- **Space runtime:** one pi-durable session per Space (`spaces/<id>.sqlite`). Main, the root conversation, runs the organizer extension (`piopio-space-organizer`: `route_to_topic`, `create_topic`, plus the web tools). Its prompt has the Space's instructions, the topic index and the corrections you made. Topics are ownerless conversations with a topic section (title, brief, Space instructions). The `piopio.space` session doc holds the topics, the moved messages and the routing hints.
- **Main is a switchboard (S1):** a routed message shows as a routing card, not the reply. The card has the topic, the reason, a live status (thinking → replying → replied, or failed) and one line of the reply, with Open → (jumps to the reply in the topic) and Wrong topic…. Statuses come back after a restart.
- **Wrong topic (S2):** `spaces.reroute` sends the message to another topic or a new one, updates the card ("You moved this from …") and records a hint the organizer reads from then on.
- **Explicit control (S3):** `@Topic …` routes without the organizer, `/new Title` (the message on the next lines) starts a topic, and `/main …` makes the organizer answer in Main. The composer suggests topics after `@` and the two commands after `/`. Messages typed in a topic get a "direct" badge (S4).
- **Sidebar and view (S6, 2b):** a Spaces section with topics nested under the open Space, newest activity first, with unread dots (cleared when you look, `spaces.markRead`) and a running spinner. The Space view has the topic capsules (Main first, + Topic), a header menu (rename, instructions, delete) and the composer. New Space (⌘⇧N, the empty state, the sidebar +) asks for a name and optional instructions.
- Verified: 2 engine tests (organizer create/route by title, Main answering, the topic transcript and reply id, unread and markRead; `@topic`, `/new`, `/main`, direct badges, Wrong topic to a new topic, everything after an engine restart), and app captures with the scripted model. **Not verified:** routing quality and the S10 latency with real models (the organizer uses the Space's model; a cheaper organizer model comes with Space settings in 3.3). The "needs you" status is in the protocol, but nothing produces it yet: topics can't ask you questions. Space conversations aren't in search yet.

**Milestone 3.3 done (2026-10-21).**
- **Memory (S8):** a `piopio.space-memory` session doc: markdown (`## Section`, `- fact`) with up to 40 revisions, each saying who changed what (organizer, a topic, you). The organizer's `update_memory` shows a memory card in Main with Undo, which takes that change back and keeps later ones. A topic's `propose_memory` shows a card with Save and Dismiss. Every agent reads the memory (the first 4,000 characters) in its prompt. The memory editor edits the text and lists the history, with Restore. It can be turned off per Space.
- **Organizer and topic tools:** `ask_topic` asks a question on a fork of another topic, owned by the call, so the topic doesn't change. `search_space` does substring search over Main, every topic and the memory. `space_files_list/read/search` read the Space's files. `rename_topic`, `archive_topic` and `merge_topics` act only with auto-tidy on; otherwise the organizer is told to suggest them.
- **Housekeeping (S9):** rename, merge (a summary of the topic joins the other's brief, written by the utility model, or the brief and summary with the scripted model; the topic is archived) and archive/unarchive (`spaces.topics.*`), plus Export as Markdown. All are in the topic's menu in the sidebar and on its capsule; archived topics are under the Space's menu.
- **Topic summaries (§3.5):** after each reply, routed or direct, the utility model writes where the topic stands in one line. The organizer's topic index and the inspector show it.
- **Files and settings (§3.2, §3.6):** `spaces/<id>/files/`, added from the Files sheet. PDFs are stored with the text the app extracted. Space Settings has the instructions, the organizer model (separate from Main's, default the Space's model), the topic model (applied to every topic), memory and auto-tidy.
- **Header and inspector (S7, 2b):** "Space · N topics · N memories · N files · $cost" with Memory and Files buttons. The inspector lists the topics with their summaries, then the recent memory changes.
- Verified: 2 more engine tests (memory: organizer save, Undo, a topic proposal saved, your edit and Restore, with authors; tools: ask_topic leaves the topic unchanged, search_space, files with a PDF's extracted text, auto-tidy gating, rename/merge/unarchive, summaries, settings, memory off), and app captures. **Not verified:** the quality of memory, summaries and merges with real models, the memory editor and the files and settings sheets beyond the build, and large Spaces (search scans the transcripts each time).

**Milestone 3.4 done (2026-10-21). Phase 3's scope is built;** its acceptance (a real Space with 5+ topics, ≥ 90% routing on the replay set) is next.
- **Conversions (S5, S9):** `spaces.importThreads` copies a thread's messages (its shown branch) into a new topic named after it, or into an existing topic, as `piopio.imported` entries the model and the transcript both see. Then the thread is deleted (or kept). In the app: a thread's menu has Move to Space › (as a new topic, or into a topic), and New Space can bring in threads. Promote to Thread (`spaces.topics.promote`) copies a topic out into a new thread and leaves the topic.
- **Thread → Space suggestion (S11):** after a thread's first exchange, and again after its fifth, the utility model compares it with every Space's topics. Above 0.75 confidence, a banner offers Move to topic, Move as new topic and Dismiss. Dismissals are remembered per thread, and Settings › Chat turns suggestions off. With the scripted model, a keyword match stands in.
- **About me (07-shared §5, GM1–GM2):** a markdown doc with a revision history, edited in Settings › Chat. When on, it's a system section in Threads and/or Spaces, never in Build. With learning on, agents add facts with `remember_about_me`; each one is a tool card ("Saved to About me"), and the history has Restore. Both are off by default.
- **MCP in Threads and Spaces:** pi-durable has no MCP client, so the engine connects pi's global `mcp.json` servers (`@modelcontextprotocol/sdk`) and offers their tools as a pi-durable extension. `exposure: "direct"` declares them; other servers are deferred behind `tool_search`. It is off by default (Settings › MCP servers › In Chat), because chat doesn't ask before a tool runs. Turning it on or off, and server changes, reconnect and reinstall the tools in open conversations.
- **Routing replay set:** `packages/engine/test/replay/routing-50.json` (a home-renovation Space with 5 topics; 50 messages with the outcomes that count as right, including 4 new topics referred to later as @aliases) and `scripts/routing-replay.mjs`, which reports accuracy, decision time (S10) and cost. Settings › Chat and engine-wide settings live in `<home>/settings.json` (`settings.get/set`).
- Verified: 2 engine tests (a suggestion, Move to topic, Move as new topic keeping the thread, Dismiss, Promote to Thread and continuing it, after a restart; About me off/on/capture/edit/restore; a stdio MCP server reached from a thread and from a Space's Main only when allowed), the release bundle starting with the MCP SDK, the replay script's plumbing with the scripted model, and app captures. **Not verified:** the suggestion's quality with the utility model, HTTP and OAuth MCP servers in chat, and conversions of threads with attachments or branches (only the shown branch moves).
- **Routing replay, first run (2026-10-21):** organizer and topics on `anthropic/claude-haiku-5.5` (the default model). **49/50 right (98%; acceptance ≥ 90%).** The miss: "Get three quotes for the new windows" created a "New windows" topic instead of going to Contractors, a defensible call. All 4 expected new topics were created, and later messages went to them. Decision time (until the card or the answer text shows) was 1.3 s median, 2.0 s p90 and 3.5 s max: the median meets S10's ~1.5 s budget, but 14 of 50 took longer. A cheaper or faster organizer model is the lever (Space Settings). Cost $0.07 for the run, topic replies included. Report: `packages/engine/test/replay/results/2026-10-21-claude-haiku-5.5.json`. Still open for Phase 3's acceptance: a real Space used daily, and checking that Wrong topic corrections are learned (the replay has no corrections).

## Spike S6 — Hindsight as the memory provider (before Phase 4's memory)
| Question | Done when |
|---|---|
| Can the engine run Hindsight locally, on demand, at a cost a Mac app can carry? And is it worth it over the built-in provider? | Measured on an Apple silicon Mac, with a throwaway `PIOPIO_HOME`. **Footprint:** download size, disk, RAM idle and under load, cold start, startup with the app, and whether the daemon supervisor (`@vectorize-io/hindsight-all` or our own) handles sleep, quit and updates. **Cost and latency:** retain (LLM extraction through OpenRouter on the utility model) and recall at 1k and 20k facts; embeddings local vs OpenRouter. **Quality:** a replay of 200 messages from a real agent-like conversation, with 30 questions about it (old facts, changed facts, who said what), scored for the built-in provider and for Hindsight. **Transparency:** extracted facts, observations and their deletes can be listed and shown with sources. **Packaging:** what runs from outside the signed bundle (uv, Python wheels, model downloads), and whether that's acceptable for notarization and for users. |

Outcome: a decision in README (AQ11 → default provider), and `MemoryProvider` + the built-in provider in `@piopio/runtime` either way. The interface is useful even if Hindsight stays opt-in. Not verified yet: Hindsight's benchmark numbers (LongMemEval, LoCoMo) are the authors' own claims.

**S6 done (2026-10-21), see [docs/spikes/s6](../spikes/s6/README.md).** Hindsight 1.0 runs locally. **Footprint:** a 1.9 GB download and 1.8 GB installed, plus 225 MB of models and Postgres binaries fetched at first start. First start takes 52 s, a warm start 17 s, and RAM is 250–800 MB. **Speed and cost:** recall takes about 300 ms, flat to 20k items; reflect takes 7 s; retain costs about $0.07 per 100 messages with claude-haiku-5.5, which needs `HINDSIGHT_API_LLM_OPENAI_COMPATIBLE_JSON_MODE=false`. **Quality on the 200-message set:** built-in baseline 29/30, Hindsight 30/30. The set is too easy to separate them; the baseline's miss was a paraphrased changed fact. **Packaging:** uv, Python wheels, model weights and Postgres all come from outside the signed bundle. **Decision:** the built-in provider stays the default; Hindsight is opt-in for Agents, remote URL first, then a local daemon; the default is reconsidered after a harder set (2,000+ messages, paraphrased questions) and a measurement of the slim package.

## Phase 4 — Agents (local)
Scope: 06-agents §2–4, §6–9, §11 local part. In-app channel + simulator, schedules, heartbeat, triggers (local URL via tunnel optional), memory partitions, **agent-to-agent**, approvals, budgets. Background mode.
Also (from the 2026-10-20 review of a similar app, see README decisions AQ5–AQ10): **Apple app tools served by the Mac app** (§4.1: Reminders, Calendar, Contacts, Notes, Music, Shortcuts), **result cards with Undo** (§4.2), **compact progress lines**, agent header and avatars, the **Inbox** with toolbar/menu bar/Dock badges (§12). Side-by-side agents, link previews, voice and quick entry to an agent (§12 UI3–UI6) if time allows; agent boards (§12.1) later.
Memory: `MemoryProvider` with the built-in provider, partitions as banks (06 §8 ME2–ME2b), and Hindsight as an opt-in provider (S6).
Also: **Settings › Extensions** for pi packages and **MCP memory** (07-shared §6, AQ12).
Cross-cutting (any phase): the **on-device utility model** (07-shared §1.3, 03-engine-protocol §3.12) for titles, commit messages, routing hints and summaries.
**Acceptance:** two local agents run for a week on the author's Mac. Schedules fire with the app closed. Agent-to-agent delegation with loop guards is tested.

Milestones:
| | Scope |
|---|---|
| **4.1** Extensions and memory providers | Settings › Extensions: pi packages listed, installed, updated, removed and switched on or off with pi's package manager (07-shared §6.1 EX1–EX6); package skills and prompt templates reach Threads and Spaces. `MemoryProvider` in `@piopio/runtime` (07 §5.1) with the **built-in provider** (SQLite: records with sources, FTS + recency, list, forget). The **MCP memory provider** with a mapping editor and a Hindsight preset (§6.2 MM1–MM4). About me (3.4) moves onto the provider interface. |
| **4.2** Agents: definition and runtime | Agent Definition files and validation (06 §2 AD2–AD4, templates), the form editor (AD1 without the Builder). The local agent runtime on pi-durable in `@piopio/runtime` (§3): one conversation per person, the owner's chat, the **in-app channel and the channel simulator** (§5.4). Memory partitions as banks with the memory view (§8 ME1–ME3). Agents sidebar, agent page tabs, **agent header** and **compact progress lines** (§12 UI1–UI2). |
| **4.3** Proactivity | Schedules, heartbeat, triggers (local webhook URL; a tunnel is optional), quiet hours and outbound limits (§6 PR1–PR6). The Runs tab with outcomes and cost. Runs fire with the app closed (background mode). |
| **4.4** Approvals, budgets and the Inbox | Approval policies and the pending state (§9 AS1–AS2), budgets and the kill switch (AS3–AS4). **Result cards with Undo** (§4.2 RC1–RC5) and proposed actions. The **Inbox** with toolbar, menu bar and Dock badges (§12). |
| **4.5** Apple apps as tools | The native bridge (§4.1 NB1–NB2) through `app.tool` reverse requests (03 §3.12): Reminders, Calendar, Contacts, Notes, Music, Shortcuts, each with result cards and Undo. |
| **4.6** Agent-to-agent | `ask_agent` and `tell_agent`, permissions, loop guards and the trace budget, `agent_msg` items and the trace view, shared memory partitions (§7 AA1–AA7). |
| **4.7** Hindsight provider | The native Hindsight adapter: remote URL first (self-hosted or Hindsight Cloud), then the supervised local daemon behind a download prompt (S6: JSON mode off, the utility model for extraction, recall per turn and reflect as a tool). The harder memory set (2,000+ messages, paraphrased questions) to revisit the default (AQ11). |
| **4.8** Agent Builder and extras | The Agent Builder chat (§2 AD1). If time allows: side-by-side agents, link previews, voice, quick entry to an agent (§12 UI3–UI6). |

The first week-long acceptance run can start after 4.4 (two agents, schedules, approvals). 4.5–4.8 add to it.

**Milestone 4.1 done (2026-10-21).**
- **Settings › Extensions (EX1–EX3, EX5):** the user's pi packages (`~/.pi/agent/settings.json`, shared with the CLI), with what each brings. Install from npm, git, a URL or a folder (with a confirmation that says what a package can do), Update All, Remove, and on/off per package or per kind (extensions, skills, templates). It's all done with pi's `DefaultPackageManager`, and turning something off writes pi's own filter form. Project packages aren't listed yet.
- **Skills and templates in Threads and Spaces (EX4):** the skills from pi's folders and the enabled packages are listed in the system prompt and read on demand with `read_skill`. Prompt templates and `/skill:name` are `/commands` that the engine expands (`$1`, `$@`, `$ARGUMENTS`, `${@:N}`); the transcript shows what you typed. The composer suggests them after `/` in every conversation. Package changes reload them.
- **`@piopio/runtime`:** the `MemoryProvider` interface and the **built-in provider**: SQLite records with sources, tags and pins; FTS5 search (prefix terms, no accents) with a recency boost, packed to a token budget; list, update, forget; and an event log grouped into batches for the history. It sits behind a small synchronous SQL adapter, so it can run on a Durable Object later.
- **MCP memory provider (MM1–MM4):** Settings › Chat › Memory providers. Pick an MCP server or a URL, load its tools, and map recall (required), retain, list, forget and reflect to tools with JSON argument templates (`{bank}`, `{query}`, `{content}`, …). Results are read as JSON or as one fact per line. There is a **Hindsight preset**, checked against hindsight-api 1.0.0's MCP tools (`/mcp` with `bank_id`), and a Try sheet. A provider without a list tool is marked "limited visibility".
- **About me on the provider interface:** facts are records tagged with their section, in a built-in or MCP provider (Settings › Chat › Stored in). The doc is rendered from them. History and **Undo** come from the provider; Undo replaces 3.4's Restore. The 3.4 `about-me.json` is migrated once.
- Verified: 2 runtime tests (ranking, banks, budget, accents, pins, edits, history, paging) and 4 engine tests: a local package's skill and template in a thread, plus toggles and removal; About me migration, edit and Undo; an MCP memory server storing and recalling About me, and limited without list; and the updated 3.4 test. Also the release bundle starting, and app captures. **Not verified:** installing from npm or git (the tests use a local folder), the Hindsight preset against a running Hindsight (tool names read from its source), the provider editor beyond the build, and package extensions inside Build sessions (pi loads them as before).

**Milestone 4.2 done (2026-10-21).**
- **Definition (§2 AD2–AD4):** `agent.json` v1 as a TypeBox schema in `@piopio/runtime`. `validate` returns schema errors and the AD3 checks, each with a path: one owner, unique contact and schedule ids, WhatsApp and Telegram ids, 5-field cron, `deliverTo`, referenced agents, known model. Five templates (personal assistant, daily briefing, habit coach, family helper, research watcher). Each agent's folder (`~/Piopio/Agents/<slug>`: agent.json, instructions.md, skills/, knowledge/) is a git repo, committed on every save.
- **Runtime (§3, §8):** `AgentCore` in `@piopio/runtime` (pi-durable only, for the Cloud Engine later): one pi-durable session per agent, one ownerless conversation per person (`person:<contactId>`, mapped in the `piopio.agent-state` doc), and the definition's model, thinking and tools applied to every conversation (again after each save). Memory partitions are banks of the memory provider (`<agent>/owner`, `/shared`, `/contacts/<id>`). Before a turn, what's relevant to the message is recalled into the system section (pinned facts always). After it, the message and the answer are retained in the person's partition. `remember`, `recall` and `forget` respect the partitions (a contact can't write the owner's: AS2). The agent's section says who it is talking with and warns it not to leak the owner's details to contacts.
- **In-app channel and simulator (§5.4, §11):** the owner's chat is the agent's Chat tab. The Conversations tab lists everyone, and talking as a contact goes through the same API (`conversationId: person:<id>`), marked as the simulator.
- **App (§12):** an Agents section in the sidebar (avatar, description, LOCAL badge, running dot; the Inbox is a placeholder until 4.4); a new-agent sheet with the templates; the agent header (avatar, This Mac, model); and the tabs Chat, Conversations, Memory (partitions, facts or everything, sources, pin, delete, add) and Definition. The Definition tab is a form over persona, instructions, model, tools, contacts, schedules and policies, with a JSON mode, inline errors, Save with a message and the git history. **Compact progress (UI2):** in agents' conversations, the engine folds a turn's tool calls into one `steps` item ("Worked · 2 steps", which opens to each step).
- Verified: 3 runtime tests (templates valid, errors with paths, cron, partitions) and an engine test: template, git folder and history; the owner's chat with a remembered fact and a steps line; retained messages; an invalid save refused; a valid save adding María; the simulator with María's fact kept in her partition, her write to the owner's refused, and the owner's recall not seeing her facts; conversations; restart; delete (folder to the Trash, banks dropped). Also the release bundle starting, and app captures. **Not verified:** real-model behavior; the Definition form's edge cases (renaming contact ids; schedules aren't run until 4.3); and the steps line's timing (pi-durable tool items have no durations yet, so it shows "Worked · N steps").

**Milestone 4.3 done (2026-10-21).**
- **Schedules, heartbeat, reminders (§6 PR1, PR2, PR6):** each is a pi-durable task (`piopio.schedule`) that sleeps until its next fire, keyed by schedule and signature, so an edit replaces it and a deleted one ends. Cron and active hours are computed in the agent's `timezone` (new field; DST-safe, plain `Intl`). A fire missed while the engine was off happens once when it comes back. The agent's own reminders come from new tools: `schedule` (an ISO time or a cron), `list_schedules`, `cancel_schedule`. The heartbeat is skipped when this month's runs used more than 80% of the budget.
- **Runs (§3, `run:<id>`):** every fire, trigger and manual run gets its own conversation, with the owner's and shared memory recalled for its prompt and a note that nobody reads it. Run ids come from the schedule key and fire time, so a repeated fire is the same run. Each run records its outcome (first line of its last answer), messages sent and cost. Runs left running by a previous engine are followed again.
- **`send_message` (§5.4, PR4, PR5):** delivers to the person's conversation as the agent's message, marked outbound in the transcript ("Sent on its own, from an automatic run") and retained in that person's memory. Quiet hours (unless `urgent` and `urgentBypassesQuiet`) and the daily limits (overall and per person) hold messages in an outbox that a task flushes when they may go; the owner gets one notice a day when a limit is hit.
- **Triggers (PR3):** a local webhook server in the engine (`127.0.0.1:47615`, or `PIOPIO_HOOKS_PORT`) with HMAC-signed URLs, the body templated into the prompt, and delivery ids for retries.
- **Background:** the engine opens every agent at start, so schedules fire whenever the engine runs (it keeps running with the app closed in background mode).
- **Protocol and app:** `agents.runs`, `agents.runNow`, `agents.triggers`, and `outbound` on assistant items. A **Runs** tab: what fires next (Run now for definition schedules), held messages with why and when they go, webhook URLs to copy, and the runs with status, outcome, messages sent and cost; a run opens its conversation, read-only. A prompt field runs anything now. The Definition form gains time zone, per-person limit and urgent sends.
- Verified: 2 time tests (cron in Madrid across DST, weekday/day-of-month OR, windows over midnight, heartbeat in active hours) and an engine test: a reminder set from the owner's chat fires a run that messages the owner (outbound item, memory, run conversation read-only); a trigger with a bad signature refused and a retried delivery deduplicated; a reminder due while the engine was off fires after restart; quiet hours hold a message; the daily limit holds two more and posts one notice. Also the app build, the Swift tests, and app captures of the Runs tab and of an outbound message in the owner's chat. **Not verified:** real-model runs; cron schedules firing on their own (the test drives one-off reminders, run now and triggers); the heartbeat over real hours.

**Milestone 4.4 done (2026-10-21).**
- **Approvals (§9 AS1):** `policies.requireApproval` rules (`send_message:to_non_owner`, `http_request:POST`, `mcp:<server>:<tool>`, globs). A matching call waits in pi-durable's `beforeTool` hook. It ends approved (as asked, or with edited arguments), denied (with a reason), expired after 24 h, or cancelled when the turn is stopped. The decision is in the agent's state doc, so the tool task's hook finds it after a restart. "Always allow …" is remembered per agent. The conversation shows an approval card (Deny / Edit… / Approve) that becomes one line once answered; a call blocked before it ran shows as a failed step.
- **AS2:** a contact's conversation can't make the agent message third people.
- **Budget (AS3):** this month's spend comes from pi-durable's usage ledger (`Harness.usage`, against the total when the month started). At 80% the owner gets an Inbox note. At 100%: an Inbox item and a note in the owner's chat; runs are skipped, tool calls blocked, the owner's messages kept with a note, and contacts get a short canned answer.
- **Kill switch (AS4):** Pause/Resume in the agent header, `agents.pause`, or `/pause` and `/resume` in the owner's chat. It aborts running turns and runs, skips fires, holds messages (outbox reason `paused`) and releases them on resume.
- **Result cards with Undo (§4.2 RC1–RC2):** `remember`, `forget`, `schedule`, `cancel_schedule` and `send_message` return a card and record how to reverse the change. The engine shows the cards after each steps line. Undo (`agents.undo`, 24 h) forgets or restores the fact, cancels or restores the reminder, or withdraws a held message, and leaves a note the model reads.
- **Inbox (§12, docs/design 4d):** per-agent entries (approvals, messages the agent sent the owner on its own, failed runs, budget, pause) gathered by `inbox.list`, with `inbox.read` and an `inbox.changed` notification carrying the count. The app shows it under Agents: a Needs you / All list, then the detail with the conversation and the proposed action (Reject, Edit, "Always allow", Approve ↩). The count shows on the sidebar row, the Dock and a menu bar extra (once there are agents). Approval notifications have Approve and Deny buttons. The agent header shows Auto / Asks first, the month's spend and Pause/Resume.
- Verified: runtime tests for the rules (7 cases) and an engine test: an approval waiting, approved with an edit (the edited message arrives), approving twice refused, denied with a reason (failed step); AS2 (María can't make it write to Luis; her message to the owner lands in the Inbox; read clears it); a memory card undone (fact gone, note in the chat, a second Undo refused); an approval pending across a restart, approved after, and the message delivered; pause (catalog status, message kept with a note, run skipped, `/resume`); budget at $0 (María's canned answer, Inbox item, the owner's note). Also the app build, the Swift tests, and app captures of the approval and result cards in the chat and of the Inbox with a proposed action. Engine writes (a run's message waiting for a busy turn) no longer show in the composer's queue. **Not verified:** notification buttons and the menu bar extra by hand; the 80% note (scripted model has no cost); real-model behavior with approvals.

**Milestone 4.5 done (2026-10-21).**
- **Bridge (§4.1 NB1–NB2, 03 §3.12):** `app.tool` reverse requests. The app declares the service in `engine.hello`, and the engine asks the newest client that serves it. With none (background mode, app closed), the tools answer "Piopio isn't open on the Mac". The app checks the agent's groups and allowed Shortcuts again.
- **Tools (NB5):** defined in `@piopio/runtime` (shared with the Cloud Engine's Mac Bridge later) and turned on per group in the definition (`tools.apple`, `tools.shortcuts`). The Definition form has an "Apple apps on this Mac" section; Reminders/schedules and Send messages are no longer greyed out there.
- **Native side:** `AppleTools.swift` uses EventKit (Reminders, Calendar; full-access requests), Contacts, AppleScript (Notes, Music) and the `shortcuts` CLI. Usage descriptions are in Info.plist, and release signing gets the hardened-runtime resource entitlements.
- **Cards and Undo (§4.2):** each change returns a card (reminder, event, note, music, shortcut) and the reversing call. Undo sends it to the app through 4.4's Undo.
- Verified: an engine test with the test client as the Mac app: unavailable before it connects; then a reminder created with its card, the call carrying the agent, groups and allowed Shortcuts; Undo sending the delete; a Shortcut by name; a group that's off not offered or called. Also the app build, the Info.plist keys, all suites, and a capture of the Definition tab with the new section. **Not verified:** the Swift handlers against the real apps (no TCC prompts or changes to your data were made here).

**Milestone 4.6 done (2026-10-21).**
- **`ask_agent` and `tell_agent` (§7 AA1–AA3):**
  - Each agent has a conversation with every agent that writes to it (`agent:<id>`), where it answers the message like any input.
  - An ask waits for that answer (10 minutes by default). A later answer comes back to the asker's conversation as a new message, including after a restart: answers in progress are followed again.
  - Permissions: A must list B in `tools.agents`, and B must accept A (`acceptFrom`, unset means every agent).
- **Guards (AA4):** `{traceId, hop}` on every message, so a fifth hop is refused. There is a per-pair hourly limit (30) and a per-trace budget ($0.50); both are `policies` settings. Mutual asks get side conversations instead of deadlocking (AA8).
- **Shared memory (AA6):** `shareMemory: {<agentId>: ["shared"]}` lets another agent read that partition. It's included in that agent's recall and notes, read-only.
- **Visibility (AA5):**
  - Both agents' transcripts show `agent_msg` items ("Asked Ledger …" with the answer, "Scout asks …").
  - The Conversations tab lists the agents it has talked with (read-only).
  - `agents.trace` returns the tree of hops with costs, and the app shows it in a sheet from the message's Trace link.
  - The Definition form has an "Other agents" section: may write to it, accepts it, shares memory with it.
- Verified: an engine test with three agents:
  - Scout asks Ledger and gets the answer; Ledger's side shows the message, and that conversation is read-only and listed under Conversations.
  - The trace holds one hop.
  - Muse refuses Scout; Ledger can't write to an agent it doesn't list.
  - A Scout → Ledger → Scout → Ledger chain stops at four hops, with parents linked.
  - The rate limit and the trace budget refuse.
  - Ledger's shared fact reaches Scout's recall.

  A deliberately slow chain also exercised the late-answer path once (not asserted). Also the app build, the Swift tests, and captures of the agent messages in a chat and of the trace sheet. **Not verified:** real-model behavior between agents; a restart in the middle of an ask.

## Phase 5 — Agents (cloud) + channels
Scope: Cloud Engine (02 §5), cloud setup wizard, deploy/rollback, Telegram, WhatsApp (Cloud API + template), approvals over channels, cloud cost ledger sync, live view.
**Acceptance:** two agents live 24/7 with the Mac off. Telegram + WhatsApp both work. Owner approvals via Telegram buttons work. Agent-to-agent works in the cloud.

## Phase 6 — 1.0 polish
GitHub PR/CI loop (G4–G8), worktrees UX, usage page, export everything, accessibility pass, Sparkle + Homebrew cask, docs site.

## Backlog from the v2 review (2026-10-22)
Noted by the user after using the v2 redesign. Not scheduled into a phase yet.

**Bugs**
- B1 · The agent's icon (avatar) picker looks broken.
- B2 · The Questions UI ("The agent asks") draws each option as a one-line capsule that doesn't wrap, so long answers run past the card's right edge and over the transcript. Options should wrap inside the card. Screenshot: [docs/design/feedback/questions-overflow.png](../design/feedback/questions-overflow.png). **Fixed 2026-10-22:** a long answer wraps in a rounded box no wider than the card; short ones stay capsules.

**Small changes**
- S1 · After you answer through the Questions UI, the chat shows nothing of it. Show the question and the chosen answer inline in the transcript, as Cursor and Claude do.
- S2 · Thinking lines read "Thought x words": drop the word count ("Thought for 4s" or just "Thought").

**Plan mode**
- P1 · Show the plan inline in the transcript, not in a pop-up.
- P2 · Give it real formatting (headings, numbered steps, checkboxes, code) instead of flat text.
- P3 · Let the user edit the plan before approving it.

**To design further**
- D1 · Connected apps (Gmail, Calendar, …). Open question: where they live. Per agent (Setup › Abilities), per project, or app-wide in Settings with each agent or project choosing which to use? Overlaps with MCP servers and Mac apps (4.5).
- D2 · More model providers beyond OpenRouter: ChatGPT/Codex subscription and OpenAI API first, several connected at once, reusing pi's own provider and auth infrastructure. Requirements: [10-model-providers.md](10-model-providers.md). Related: "direct providers + local models + subscription logins" in Later.
- D3 · Truly proactive agents: agents that don't need you to chat with them. They observe their environment (mail, calendar, files, Mac apps), decide when something matters, ask you questions and act. Builds on 4.3 proactivity (schedules, heartbeat, triggers).
- D4 · Create agents by chatting: describe what you want and Piopio drafts the definition (instructions, schedule, abilities, people) for you to confirm, replacing or complementing the form in the new agent sheet.
- D5 · Voice input in the composers (dictation, push to talk).
- D6 · MCP Apps support: MCP servers that return interactive UI, rendered in the transcript.

**Future idea**
- F1 · Concept → simple 3D visualization: say a concept and Piopio shows it in 3D (reference: https://x.com/elvar_official/status/2111831136171151589). Open question: a skill, a mode, or its own item type in the sidebar.

### Second batch (2026-10-22)

**Bugs**
- B3 · The model picker in a notebook's settings sheet looks broken: the sheet forces it into a 420×380 frame (`SpaceViews.swift`, `.popover(item: $picking)`), but the v2 picker lays out at 760×520, so its list and detail pane are squeezed and clipped. **Fixed 2026-10-22:** the fixed frame is gone; the picker opens at its own 760×520 size.

**Small changes**
- S3 · Follow-up suggestion chips are cut to one line (`FollowUps` in `ChatExtras.swift`, `lineLimit(1)`), so long ones can't be read. Let them wrap like the Questions UI options (B2), or at least show the full text as a tooltip. **Fixed 2026-10-22:** long suggestions wrap in a rounded box no wider than the column, and the full text shows on hover.
- S4 · Attach folders as well as files from the composer's +. Today the file panel only accepts files (`Composer.swift`, `canChooseDirectories = false`); @-mentions already reach folders in Build.

**To design further**
- D7 · A composer that keeps formatting: pasting Markdown (or rich text) today loses it. Show it formatted while typing, or at least keep the Markdown source intact and preview it.
- D8 · A file viewer for Markdown (rendered), PDF, images and more, used everywhere: chat attachments, notebook files, Build's Files tab. Build's `FileViewer` (`BuildFiles.swift`) shows files as text today.
- D9 · Custom skills: create, edit and enable skills from the app. Today skills are read from `~/.pi/agent/skills` and enabled pi packages (`tools/chat-resources.ts`), offered as `/skill:name`, with no UI to make or manage them.
- D10 · Computer use: let agents and chats drive the Mac's screen (screenshots, clicks, typing), with approvals. Builds on Mac apps as tools (4.5).
- D11 · Image generation in Chat (and as an agent ability), through a provider that offers it (see D2).
- D12 · Web search: Chat has it already (OpenRouter web plugin, CQ3) and agents have `web_search`. Check it's on and visible in Build sessions, notebooks and the composer, and make it obvious when a turn searched the web.

**Open questions**
- Q1 · **Checkpoints vs fork.** Today a checkpoint is a snapshot of the project's *files* taken before each turn that writes (a shadow git dir, 05-build §7, `checkpoints.ts`); "Restore to here" rewinds the files, not the conversation. Fork (pi's session tree, BR6) branches the *conversation*. Claude Code's rewind and Cursor's "restore checkpoint" put both on each message: hover a message → restore code, conversation, or both. Proposal to evaluate: drop the separate checkpoint items from the transcript and the inspector timeline, put Restore on each of your messages with those three choices, and draw forks as a small branch marker on the message they start from.
- Q2 · **"Worktree" at the top of a Build session.** A worktree is a second working copy of the repo on its own branch (BP5), so several sessions can change the same project at once without stepping on each other; when the session ends you merge, open a PR, keep or discard it. The word is git jargon: consider "Separate copy (branch piopio/…)" in the header and new-session sheet, with worktree in the tooltip.
- Q3 · **How pi uses context files and skills.** To verify against pi's docs and write down in 07-shared-resources: which files pi reads into the prompt (AGENTS.md and CLAUDE.md from the project and its parents, `~/.pi/agent/AGENTS.md`, SYSTEM.md / APPEND_SYSTEM.md?), how skills (`SKILL.md` folders) load on demand, and whether anything like OpenClaw's SOUL.md exists or should exist for agents (an agent's persona today is its Setup › Instructions). The app reads AGENTS.md/CLAUDE.md only to show it per project (`projects.ts`).
- Q5 · **Where a notebook's Files live.** Today Files is a button in the notebook's toolbar that opens a sheet. Options: the left sidebar (under the notebook, like a project's sessions), or the notebook's right-hand panel, next to Progress and Memory. The right panel looks like the better fit: it already holds what every topic shares, and the left sidebar stays a list of places.
- Q4 · **Where things run.** Claude and Codex let you pick, per chat, whether it runs on this Mac or in the cloud. Research per kind: Build sessions (this Mac, a worktree, or a cloud machine from the GitHub repo), chats and notebooks (this Mac or the cloud engine), agents (this Mac or a Durable Object, Phase 5). Decide whether the choice lives in the composer, the new-session sheet, or per project/agent, and how a running item moves between them. Related: "cloud Threads/Spaces" and "cloud Build sessions" in Later.

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
