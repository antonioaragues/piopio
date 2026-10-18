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

| Extension | Purpose |
|---|---|
| `piopio-approvals` | Approval modes (§6). Intercepts tool calls and asks the user via the UI bridge (`ctx.ui.confirm`-style request → `approval.requested`). |
| `piopio-checkpoints` | Snapshot before each turn that writes files (§7). |
| `piopio-plan` | Plan mode: read-only tools until the user approves a plan. Plan rendered as a checklist card. |
| `piopio-todos` | Todo list tool. Shown in the inspector and as a progress card. |
| `piopio-subagents` | `task` tool to spawn child sessions (shown as nested `task` items, openable). Children inherit the parent's approval mode and count toward its cost. Default max 3 concurrent children per session. |
| `piopio-notify` | `notify_user(message)` / `ask_user(question, options)` for agent-initiated questions. Surfaced as a "waiting for you" state. |

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
- **BR6** Fork/branch navigation follows pi's session tree (`/tree` equivalent as a popover).
- **BR7** Context meter: tokens used / model context window. Click → compact.

## 6. Approvals (decision B4)

Three modes, set per session (default per project; global default = **Auto-edit**):

| Mode | read/grep/ls | write/edit (inside project) | bash | network tools | writes outside project |
|---|---|---|---|---|---|
| **Ask** | auto | ask | ask | ask | ask |
| **Auto-edit** | auto | auto | ask (unless allow-listed) | auto | ask |
| **Full auto** | auto | auto | auto | auto | ask |

- **AP1** Approval card inline in the transcript + global badge + notification when the window isn't focused. Actions: **Allow**, **Deny (with note to agent)**, **Always allow** → a rule.
- **AP2** Rules: command prefix patterns (`npm test`, `git status`, `swift build`), tool names, path globs. Stored per project in `catalog.db` and exportable to `.pi/` if the user wants them shared with the CLI.
- **AP3** Built-in **deny-list** that always asks even in Full auto: `rm -rf` outside worktree, `git push --force`, `sudo`, writes to `~/.ssh`, `~/.aws`, keychain tools, `curl … | sh`.
- **AP4** Approvals time out? **No** by default. The session waits ("waiting for you").
- **Later:** an OS sandbox (Seatbelt profile restricting writes to the project/worktree + temp, and network on/off).

## 7. Checkpoints (B5)

- **CK1** Before the first file-modifying tool in each agent turn, snapshot the working tree into a **shadow git dir** (`checkpoints/<projectId>.git`, `--work-tree=<project>`), respecting .gitignore plus a size cap. Untracked files are included. The user's repo is never touched.
- **CK2** A `checkpoint` timeline item marks each one. "Restore to here" → shows the files to be changed, confirms, restores, and posts a `system` item to the session telling the agent what happened.
- **CK3** Retention: last 50 checkpoints per project or 14 days, whichever is larger. Configurable.

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

### Later
- Issues → session ("Work on #42"). PR review mode (agent reviews someone else's PR). Auto-fix loop. GitLab.

## 9. Terminal
- **TM1** Drawer terminal per project (SwiftTerm, local PTY, cwd = project/worktree). Multiple tabs.
- **TM2** "Send selection to agent" and "Send last command output to agent".
- **TM3** The agent's `bash` runs inside the engine, not in the user's terminal. Its output appears in tool cards.

## 10. Later
- **Cloud build sessions:** run the coding agent in Cloudflare Sandbox/Containers or over SSH on a devbox. Session kind stays `build` with `location: remote`.
- **Web preview:** an embedded preview with a dev-server launcher (from `package.json` scripts) and console capture sent to the agent.
- **iOS Simulator** integration for Swift projects.
- **Pi-durable for Build:** pi-durable ships `read/write/edit/bash` tools itself. Once it stabilizes, re-evaluate unifying Build onto pi-durable (gains crash recovery and cloud portability, loses CLI session interop).

## 11. Resolved questions (Build)
- **BQ1** Default approval mode → **Auto-edit**.
- **BQ2** Worktree location → **app support folder** (`~/Library/Application Support/Piopio/worktrees/…`). Sessions offer "Reveal in Finder" and "Open terminal here".
- **BQ3** Default-on extensions → **todos, notify, subagents**. Plan mode is off by default.
