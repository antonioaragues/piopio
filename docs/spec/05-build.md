# 05 — Build mode

Agent-first development environment (decision B1). The agent does the work. Piopio makes it easy to **steer, review, and ship** that work.

## 1. Layout

```
┌ Sidebar ─────────────┬ Session ────────────────────────────────┬ Inspector (toggle) ──────┐
│ PROJECTS             │ ‹branch: feat/login›  model ▾  mode ▾   │ [Changes] [Files] [Git]   │
│ ▾ piopio             │                                          │                           │
│   ● Fix auth bug  ⏳  │  transcript (timeline items)             │  M src/auth.ts  +12 −3    │
│   ✓ Add tests        │  tool cards: read / edit (diff) / bash   │  A src/auth.test.ts       │
│   ⚠ Refactor (needs  │                                          │  ─────────                 │
│      approval)       │                                          │  diff viewer               │
│ ▸ website            │  ───────────────────────────────────     │                           │
│ + Add project        │  composer: @file /command  ⏎             │                           │
└──────────────────────┴──────────────────────────────────────────┴───────────────────────────┘
                           Terminal drawer (⌃`)
```

Session status icons: running ⏳, waiting for you ⚠ (approval/question), done ✓, error ✕, idle (none). These are also mirrored in the menu bar extra and in notifications.

## 2. Projects & sessions

- **BP1** Add a project: pick a folder, drag one in, or "Clone from GitHub" (§8). Detect git, default branch, `AGENTS.md`/`CLAUDE.md`, and the pi project config (`.pi/`).
- **BP2** Sessions are listed per project, newest first, with status, title (auto), branch/worktree badge, and cost.
- **BP3** **Pi CLI interop:** sessions live in pi's session directory for that cwd. Sessions started with the `pi` CLI in that folder show up in Piopio (read on FS change) and can be resumed. Piopio-started sessions can be resumed in the CLI. Piopio-specific metadata (title, pin, status cache) lives in `catalog.db`, keyed by session file path.
- **BP4** Concurrency: any number of sessions can run in parallel. Two sessions writing to the same working tree without worktrees trigger a warning.
- **BP5** **Worktrees (optional per session):** "New session in worktree" creates `worktrees/<projectId>/<sessionId>` on a new branch `piopio/<slug>` from the chosen base. Worktree sessions show their branch. On finishing: **Merge into base**, **Create PR**, **Keep**, or **Discard** (removes the worktree and branch after confirmation).

## 3. Runtime

- Each Build session is an `AgentSession` from `createAgentSession({ cwd, sessionManager, resourceLoader, modelRuntime, ... })` in the Local Engine.
- **Resources:** `DefaultResourceLoader`, so user-level and project-level pi extensions, skills, prompt templates and context files are discovered exactly as in the CLI. Piopio adds its own bundled extensions through `extensionFactories` (§4).
- **SDK caveat:** built-in CLI extensions (codemode, tool_search, MCP) aren't auto-loaded in the SDK. Piopio adds `createMcpExtension()` (and optionally codemode/tool search) explicitly, then calls `session.bindExtensions()`.
- Model/auth: OpenRouter via pi's model runtime. The key comes from the app's Keychain through `secrets.get`.

## 4. Piopio pi extensions (bundled, each toggleable)

Default state for new sessions: **approvals, checkpoints, todos, notify and subagents ON. Plan mode OFF** (`/plan` is always available on demand).

> **Since 32 §7 (2026-11-21):** Plan is a mode only: no /plan command and no chip. It lives in the mode selector.

| Extension | Purpose |
|---|---|
| `piopio-approvals` | Approval modes (§6). Intercepts tool calls and asks the user via the UI bridge (`ctx.ui.confirm`-style request → `approval.requested`). |
| `piopio-checkpoints` | Snapshot before each turn that writes files (§7). |
| `piopio-plan` | Plan mode: read-only tools until the user approves a plan. Plan rendered as a checklist card. |
| `piopio-todos` | Todo list tool: each step a short title and an optional one-sentence detail. Shown in the inspector as a timeline (docs/design/plan-timeline) and as a progress card. |
| `piopio-subagents` | `task` tool to spawn child sessions (shown as nested `task` items, openable). Children inherit the parent's approval mode and count toward its cost. Default max 3 concurrent children per session. Blocks its parent today; non-blocking is 17 §3 (DP4). *(Since 17 §9, built 2026-11-17: `task` returns at once by default; `wait: true` keeps the blocking call, and Claude Code / Codex tasks always wait. Since 37 SB2 and SB4, built 2026-11-22: each subagent is one live row in the transcript and opens in the right column, not a nested item.)* Since 2026-11-17 it's one of three uses of one child-session mechanism, for a read-only piece of the turn that would flood its context (26 §7.1). |
| `piopio-notify` | `notify_user(message)` / `ask_user(question, options)` for agent-initiated questions. Surfaced as a "waiting for you" state. |
| `piopio-sandbox` | Runs `bash` inside macOS's sandbox (AP5). Built 2026-11-08. |
| `piopio-present` | `present_files(files)`: the files the agent made for you, as a card per file that opens in the viewer. Kept out of the folded activity line. Built 2026-11-08. |
| `piopio-goal` | `/goal <what done looks like>`: the session gets another turn ("round") each time it finishes until the agent calls `update_goal` with "done" or "blocked", up to 25 rounds. Stop pauses it; `/goal continue` resumes (with more rounds when they ran out); `/goal off` clears it. Each round shows as "Goal · round n of 25". Kept in the session file. Built 2026-11-08. *(Since 32 §8, 2026-11-23: up to 25 rounds or $5.00, and chats have /goal too.)* |

| `piopio-diagnostics` | The project's check after the agent's edits ("Diagnostics" below). Built 2026-11-21. |

### Diagnostics (roadmap PAR5, 2026-11-21)
- **DG1 When.** A run that edited files (`edit`, `write`) is about to end: Piopio runs the project's check before the
  agent answers. A run that only read, or a failed edit, runs nothing.
- **DG2 What.** The project's own check, not a language server: its `typecheck` / `type-check` / `check:types` /
  `check` script (with its package manager), `tsc --noEmit` when the project has TypeScript installed, `cargo check`,
  `go vet`, `pyright` or `mypy`. On the project page, **Check after edits**: Automatic (what was detected), a command
  of the user's, or Off. Chat projects and review sessions don't run it.
  **Since 18 CF3 (2026-11-07):** the Chat lens is gone, replaced by the Read only permission, so "Chat projects" is not a kind any more.
- **DG3 Feedback.** The problems the agent's changes brought in go back, with a line or two of context, at most 60
  lines: those in the files it changed, and, since 2026-11-24, those anywhere else that weren't there before its first
  edit. Before a message's first `edit` or `write` the check runs once as a **baseline**, and a problem elsewhere counts
  only when the baseline didn't have it (the same file and message, on any line). A check whose last run took over
  20 s gets no baseline, so the first edit doesn't wait twice; then only the edited files count. The run goes on with
  them as a message ("fix them, then finish; if one is wrong, say so"), shown in the transcript as "Checked with
  <command>: N new problems since its first edit" (without a baseline, "N problems in files it changed"). At most
  twice per message from the user; a third time the note says "(left for you)" and the agent stops.
- **DG4 Bounds.** It runs in the project folder with the session's sandbox (confined unless Full auto), a two-minute
  limit, and no colours. A check that passes, times out or names none of the edited files adds nothing.
- **As built:** `diagnostics.ts` in the extensions package (`detectCheck`, `problemsIn`, `runCheck`,
  `diagnosticsExtension` on `agent_before_settle`), the project's `check` (`projects.configure`, `ProjectInfo.check`
  with its source), the live transcript taking messages pi adds at a boundary (`entry_appended`), and the project
  page's row. Not done: coding agents (Claude Code, Codex, Antigravity) run their own loop, so the check doesn't run
  for them; a language server's live diagnostics.
- **Found in use (2026-11-24):** DG3's first rule (only the files it edited) missed a break the agent caused in a file it
  didn't touch: a changed return type broke a caller, and the check stayed silent. The baseline above fixes it
  (`problemKeys` and `problemsIn`'s baseline in `diagnostics.ts`), tried for real: the same change came back as "1 new
  problem since its first edit" and the agent fixed the caller ([the pass](../research/par-pass-2026-11-24.md) F3).

The engine adds three more (not pi extensions of this package): the **context guards** (the model's clock and the repeated-call nudge, `tools/guards.ts`), **earlier conversations** (`search_conversations` / `read_conversation` and `@conversation:<id>` mentions, `tools/history.ts`), and **Claude Code / Codex** as `task` backends (`external-agents.ts`). See [docs/research/deepseek-harness.md § As built](../research/deepseek-harness.md#as-built-2026-11-08).

All of them SHOULD also work in the pi CLI (graceful TUI fallback), so they can be published as a pi package `@piopio/pi-extensions`.

**Third-party pi packages** can be installed from Settings › Extensions (npm/git). Tools, hooks, commands and skills are supported. **Custom TUI components are not rendered.** They show as a "This extension has a terminal UI that Piopio can't display" notice.

## 5. Transcript & review

- **BR1** Tool cards:
  - `read`: path + range, collapsed. Click opens the file viewer at those lines.
  - `edit`/`write`: an inline **diff** (unified, syntax-highlighted), "Open in diff viewer", "Revert this change".
  - `bash`: command, live output (terminal-styled, ANSI colors), exit code, duration, "Copy" / "Run again in terminal".
  - Extension/MCP tools: generic card with args/output (JSON pretty-print).
- **BR2** **Changes panel** (inspector): all files changed by this session (vs. its first checkpoint), with stats. Clicking shows the diff (side-by-side/unified toggle). Per-file **Revert** and **Stage**.
- **BR3** **Comment-on-diff:** select lines in the diff → "Ask agent about this" or "Request change" → sends a follow-up with the file/line reference.
- **BR4** **File viewer:** read-only, highlighted, with a quick-edit mode (small changes, saved via `projects.files.write`). "Open in <Editor>" (configured: Xcode, VS Code, Cursor, Zed, Sublime, …).
- **BR5** **@-mentions** in the composer: fuzzy file/folder search (respects .gitignore). **/commands**: pi prompt templates, skills (`/skill:name`), and Piopio commands (`/plan`, `/compact`, `/model`, `/fork`, `/worktree`).
  **Since 32 §7 and §4.1 (2026-11-21):** there is no /plan command (Plan is a mode only, §7), and skills are listed by their name, without `skill:`.
- **BR6** Fork/branch navigation follows pi's session tree (`/tree` equivalent as a popover).
- **BR7** Context meter: tokens used / model context window, in the inspector footer. Click → the **context popover**:
  - The total (pi's count: the provider's last reported usage plus an estimate for what came after it), the window, the percentage and what's free, on one grey bar.
  - **What fills it**, as rows that expand: Instructions (Piopio guidelines, AGENTS.md, skill listings, MCP server instructions), Tool definitions, Conversation (your messages, assistant messages, thinking, added background), Tool use (files, terminal, web and browser, apps and MCP), Your attachments, Summaries. The engine estimates each category by its characters and spreads pi's total over them by those shares, so the rows add up to the total; they're shares, not exact counts. They're counted on the request as it was sent to the model (after hidden tools and forced prompts), plus what came after it; after a reopen or a context rewrite, on the saved conversation.
  - Right after a compaction the total is unknown until the next response, and the popover says so.
  - **Compact…** (plain text), then a confirmation with Compact as the black action. Not while it answers, asks you something or already compacts.
  - Past 85% the composer says "This conversation is at N% of its context" with **Compact now** (one click) and **View context** (the popover).

## 6. Approvals (decision B4)

Three modes, set per session (default per project; global default = **Auto-edit**):

| Mode | read/grep/ls | write/edit (inside project) | bash | network tools | writes outside project |
|---|---|---|---|---|---|
| **Ask** | auto | ask | ask | ask | ask |
| **Auto-edit** | auto | auto | ask (unless allow-listed) | auto | ask |
| **Full auto** | auto | auto | auto | auto | ask |

> **Since 18 §10 (built 2026-11-07):** `read_only` is a fourth approval mode, and Plan is a fifth choice in the selector (18 CF3). The default is the project's own: a folder without code markers starts in Read only, a code repository in Auto-edit (18 §4).

- **AP1** Approval card inline in the transcript + global badge + notification when the window isn't focused. Actions: **Allow**, **Deny (with note to agent)**, **Always allow** → a rule.
- **AP2** Rules: command prefix patterns (`npm test`, `git status`, `swift build`), tool names, path globs. Stored per project in `catalog.db` and exportable to `.pi/` if the user wants them shared with the CLI.
  **As built:** a project's rules are kept with the project in `projects.json` (`packages/engine/src/projects.ts`; 39 §2 names the file), not in `catalog.db`.
- **AP3** Built-in **deny-list** that always asks even in Full auto: `rm -rf` outside worktree, `git push --force`, `sudo`, writes to `~/.ssh`, `~/.aws`, keychain tools, `curl … | sh`.
- **AP4** Approvals time out? **No** by default. The session waits ("waiting for you").
- **AP5** **Sandbox** (built 2026-11-08, Settings › Approvals, default on): in Ask and Auto-edit, `bash` runs through `sandbox-exec` with a Seatbelt profile that allows everything except writes outside the project (or worktree, plus the repository's git folder), temporary folders, `/dev` and package/build caches (`~/Library/Caches`, `~/.npm`, `~/.cargo/registry`, DerivedData, …). Reads and the network are not restricted. A blocked write tells the model it can run the command again with `outside_project: true`, which always asks (deny-list rules and Always allow don't skip it). If the sandbox can't start, nothing runs. macOS refuses a sandbox inside a sandbox, so confined commands find `swift` and `xcodebuild` through wrappers that turn their own manifest, plugin and script sandboxes off (`SHIMS` in `sandbox.ts`); another tool that tries gets a hint to look for its flag, not the `outside_project` one. Full auto runs commands unconfined, as before. Not covered: `edit`/`write` (they keep the path checks above), MCP servers and the terminal tab.
  **Since 39 (built 2026-11-23):** "Reads and the network are not restricted" no longer holds. The sandbox hides Piopio's data, sign-ins, credential files, SSH private keys and the Keychain tool (39 §1), and a project you add or clone is filtered until you trust it: its commands reach this Mac, the built-in sites and the sites you allowed (39 §2, §3). Project trust is defined there (39 §2) and, for coding agents, in 31 CA13; a filtered project can't be in Full auto (39 NF3).
- **AP6** **Auto review** (built 2026-11-08, Settings › Approvals, default off): in Auto-edit, a command that would ask is first judged by the session's own model (`REVIEW_SYSTEM` in `review.ts`). "allow" runs it (sandboxed); "ask" shows the usual card with "Auto review: reason". Deny-list commands, writes outside the project and `outside_project` never go to the reviewer. Costs one request per reviewed command. Allowed commands carry the reason on their card ("auto-reviewed"; `ToolItem.review`, kept in the session file), not as a note between steps. The reviewer judges the command alone: a later step the user asked for (a push) is reviewed when its own command comes.
- **AP7** A `task` for Claude Code or Codex asks first in Ask mode ("Hand a task to Claude Code"), since they change files without asking; in the other modes their own permission setting follows the session's mode (external-agents.ts). On a Claude plan, Claude Code's reported cost isn't counted as spending.
  31 CA14 (decided 2026-11-23, not built) would change this: a `task` handed to Claude Code or Codex becomes a side conversation on that agent's runtime (24), with its approvals in the tray.

## 7. Checkpoints (B5)

- **CK1** Before the first file-modifying tool in each agent turn, snapshot the working tree into a **shadow git dir** (`checkpoints/<projectId>.git`, `--work-tree=<project>`), respecting .gitignore plus a size cap. Untracked files are included. The user's repo is never touched.
- **CK2** A `checkpoint` timeline item marks each one. "Restore to here" → shows the files to be changed, confirms, restores, and posts a `system` item to the session telling the agent what happened.
- **CK3** Retention: last 50 checkpoints per project or 14 days, whichever is larger. Configurable. Each checkpoint is a commit of its own, with no parent, so one dropped past the window is collected at once (chained, every old one stayed reachable from the newest and the shadow repo only grew).

## 8. Git & GitHub (B3)

### v1
- **G1** Status in the header: branch, ahead/behind, dirty count. Branch switcher.
- **G2** **Commit:** stage panel + message (an "✨ Generate" button uses the utility model on the diff). Commit/amend.
- **G3** Push / pull / fetch. Creates upstream on first push.
- **G4** **Auth:** if `gh` is installed and authenticated, use `gh auth token`. Otherwise GitHub **OAuth device flow** with Piopio's public OAuth App client ID. The token is stored in Keychain.
- **G5** **Clone** from a URL or a GitHub repo picker.
- **G6** **Create PR** from a session: title/body generated from the session + diff (editable), base branch, draft toggle. The PR is linked to the session.
- **G7** **PR panel** for linked PRs: checks status (polled while the app is open), review comments listed with file/line, and "Address comments" → a follow-up prompt with the comments.
- **G8** "Fix CI": pull failing check logs (GitHub Actions) into a follow-up.

### G4–G8 as built (2026-11-17)
- **G4:** `github.ts` takes `gh auth token` when `gh` is signed in, else a token you paste in Settings → GitHub,
  kept in Keychain (`github.token`, through the secret broker). The OAuth device flow is not built: it needs
  Piopio's own OAuth App, which comes with the 1.0 release work. git gets the token as an `http.extraheader` for
  github.com only, so nothing is written to the remote URL or the git config.
- **G5:** New project → "Clone from GitHub…": your repositories (searchable) or any URL, cloned into a folder you
  pick, which becomes the project.
- **G6:** Create PR from the Git menu, the session's menu, or a board card's landing: the branch is pushed, title
  and body come from the conversation and the diff (editable), base branch and draft toggle. The PR is linked to the
  conversation (`entry.pr`), and a PR block sits above its composer.
- **G7:** the PR block shows state, checks (passing, failing, pending) and review comments with file and line.
  "Address comments" sends them as a `[PR]` follow-up. Linked open PRs are polled every 2 minutes while the engine
  runs.
- **G8:** "Fix CI" pulls the failing GitHub Actions jobs' last 150 log lines into a `[PR]` follow-up.
- **PR events (17 §5, DP5):** per project, Off, Tell (default) or Act. New human comments, a failing head commit
  (once per sha) and a merge or close become a notification (Tell) or `[PR]` follow-ups the conversation works on
  (Act). Bots are dropped in code; the collaborators filter and an ignore list are not built yet.
- Tests: `test/github.test.ts`, against a fake GitHub API and a bare repo standing in for github.com.

### Later
- Issues → session ("Work on #42"). PR review mode (agent reviews someone else's PR). Auto-fix loop. GitLab.

### Review by an agent (roadmap PAR4, 2026-11-21)
- **RV1 Start.** In a Build session's ⋯ menu: **Ask an Agent to Review** reviews this session's changes (since its first
  checkpoint), or, with none, the branch against its base; **Review a Pull Request…** takes a number and reviews any
  pull request of the project's GitHub repository, yours or someone else's.
- **RV2 Runs** as a session of its own in the project folder, in Read only, on the session's model: "Review · <title>"
  or "Review · PR #42". Its first message carries the diff (`changes.diff`, up to 200 KB) and what it's for; it reads
  the files it needs and reports with `report_findings`. Correctness first: bugs that would break something, then
  risks (security, data loss, races, missing error handling), then a few nits at most. A finding names the file and the
  line, says what goes wrong and when, and suggests a fix.
- **RV3 Findings** show on the session that was reviewed (for a pull request, on the review itself) as a Review panel
  above the conversation: severity, title, `file:line` (opens the file at that line), the explanation, and **Fix**
  (sends the finding to the session as a message, and marks it fixing) or **Dismiss**; **Fix all** sends the open ones
  together. While the review runs the panel says so, with a link to it.
- **RV3 in captures (2026-11-24):** the panel is as tall as its findings, up to 260 points, then scrolls (it was 260
  whatever it held). When it appears (or the drawer opens or closes) the transcript keeps its last line above the
  composer (UI2, checked live). A fixed finding stays "Fixing": nothing marks it done yet
  ([the pass](../research/par-pass-2026-11-24.md)).
- **RV4** Posting the findings to GitHub as review comments is not built: it publishes on the user's behalf and needs
  its own confirmation design.
- **As built (2026-11-21):** `code-review.ts` (the reviewer's message and `report_findings`, which never asks),
  `sessions.review` / `sessions.reviewFinding`, the summary's `review` (target, status, summary, findings with their
  state), GitHub's `pullRequestDiff`, and the app's `ReviewPanel.swift` with the two ⋯ menu items. A review on a coding
  agent (Claude Code, Codex, Antigravity) reports through Piopio's tool server. A review that ends without reporting
  is marked failed. Tried for real: Claude Code (Sonnet) reviewing a branch with two planted bugs found both, with the
  right lines and fixes, and said both edits were regressions.

## 9. Terminal
- **TM1** Drawer terminal per project (SwiftTerm, local PTY, cwd = project/worktree). Multiple tabs.
- **TM2** "Send selection to agent" and "Send last command output to agent".
- **TM3** The agent's `bash` runs inside the engine, not in the user's terminal. Its output appears in tool cards.
- **TM4 Background processes** (roadmap PAR2, 2026-11-21). `bash` with `background: true` starts a command that keeps
  running (a dev server, a watcher, a long test run) and returns at once: its id (`p1`), the first lines of output and
  any local address it printed (`http://localhost:5173`). It's still `bash`, so the same approvals, rules, deny-list and
  sandbox apply; the approval card says "Start a command in the background". `process_output` reads what it printed
  since the last read (or its last lines), `process_stop` stops it with everything it started (its process group:
  SIGTERM, then SIGKILL after 3 s), `process_list` lists them; none of the three asks. At most 8 running per session;
  each keeps its last 256 KB of output. They stop when the session closes or the engine quits, never outliving
  Piopio. The session state lists them (`state.processes`: id, command, status, exit code, addresses), and the
  terminal drawer shows each as a tab next to your shells ("npm run dev · agent"), with its output as it comes,
  **Stop**, Send to agent, and Preview while it runs; the app reads output with `sessions.processOutput` and stops one with
  `sessions.processStop`. Claude Code, Codex and Antigravity have their own background commands (spec 31).

## 10. Later
- **Cloud build sessions:** run the coding agent in Cloudflare Sandbox/Containers or over SSH on a devbox. Session kind stays `build` with `location: remote`.
  30 §8 (decided 2026-11-19, cloud Build sessions not built) would name this differently: `location: "cloud"` on the ref, where K1 as built marks a cloud agent's catalog entry with `cloud` (30 §13). Build in the cloud needs a GitHub repo (30 CT3).
- **Web preview:** an embedded preview with a dev-server launcher (from `package.json` scripts) and console capture sent to the agent.
- **iOS Simulator** integration for Swift projects.
- **Pi-durable for Build:** pi-durable ships `read/write/edit/bash` tools itself. Once it stabilizes, re-evaluate unifying Build onto pi-durable (gains crash recovery and cloud portability, loses CLI session interop).

## 11. Resolved questions (Build)
- **BQ1** Default approval mode → **Auto-edit**.
  **Since 18 §4 (2026-11-07):** a folder without code markers starts in Read only; a code repository still starts in Auto-edit.
- **BQ2** Worktree location → **app support folder** (`~/Library/Application Support/Piopio/worktrees/…`). Sessions offer "Reveal in Finder" and "Open terminal here".
- **BQ3** Default-on extensions → **todos, notify, subagents**. Plan mode is off by default.
