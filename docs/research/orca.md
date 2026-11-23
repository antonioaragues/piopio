# Orca: what Piopio could take (2026-11-21)

Orca is Stably AI's open-source "agent development environment" (MIT, TypeScript/Electron, macOS, Windows and Linux,
with iOS and Android companions; v1.4.268 on 2026-11-21). orca.build is now a parked domain. The product lives at
[orca.dev](https://orca.dev) and [stablyai/orca](https://github.com/stablyai/orca). It runs other people's agents
(Claude Code, Codex, Pi, Antigravity, about 35 CLIs) on your own subscriptions. Each agent gets its own git worktree,
and Orca adds terminals, a diff review, a Chromium browser, SSH and cloud hosts, and "bots" around them.

Piopio already covers most of the same ground, often on purpose and in a different way: native rather than Electron,
its own harness plus coding agents (spec 31) rather than terminal first, and agents as contacts (26) rather than Slack
bots. The useful ideas are a handful of tight review loops and some honest accounting of plan usage.

## Worth bringing, in order

| # | Idea | What Orca does | Where it lands in Piopio | Size |
|---|---|---|---|---|
| 1 | **Batched notes on the diff** | Comment on a line or a range of lines in any hunk. Notes stay pinned as the diff shifts. **Send to agent** turns every unresolved note into one prompt with line anchors, and you pick which agent receives it. After the revision the notes stay, so you can check each fix and **Resolve** it. Unresolved notes go into the next batch. Orca's reason: one note at a time makes the agent swing back and forth. [Docs](https://orca.dev/docs/review/annotate-ai-diff) | 05 **BR3** is specced as one note at a time and isn't built. Change BR3 to notes in a tray, then one send. Notes become findings like PAR4's review cards, so the Review panel and your own notes share one list. | M |
| 2 | **Plan usage before you hit the limit** | The status bar shows each provider's 5-hour, daily and weekly windows, the time to reset, a warning at 80%, and credit balances. A popover lists the tightest limit first. Orca reads the agents' local state and never spends quota to check. [Docs](https://orca.dev/docs/agents/usage-tracking) | 29 already rests a route *after* it hits a limit. With 31 (Claude Code, Codex, Antigravity on a plan), seeing the window *before* a long run starts matters. Put it in the model chip's hint and the Settings › Providers rows, and let 29 pick the next route early when a window is above about 95%. | M |
| 3 | **Pick an element, with notes** | Design Mode in the browser: click an element, and its HTML (plus nearby markup), computed styles, a cropped screenshot and the source file and line (from source maps) go to the agent. An annotation tray holds several notes before one send, survives a reload, and the agent can read it (`orca tab annotations`). [Docs](https://orca.dev/docs/browser/design-mode) | 22 §6 lists "pick an element" under **Not yet**. Build it with the same tray-then-send pattern as #1, from the project preview (PAR3). The page map (BW2) already has refs and roles, and computed styles plus a crop are the missing parts. | M |
| 4 | **Worktree setup** | A new worktree can run a setup step (`--setup run`). The docs warn that worktrees don't isolate ports or databases. [Docs](https://orca.dev/docs/model/worktrees) | `git.ts addWorktree` only runs `git worktree add`, so a new worktree has no `.env` and no `node_modules`. Add a per-project **setup command** (detected or set, like PAR5's check command), run when a worktree is created and shown as a background process (PAR2). Optionally give each worktree a `PORT` offset. | S |
| 5 | **Quote into the composer** | **Add to chat** from a file, the terminal, a Markdown preview, or part of an agent's reply inserts the quote with its source, without sending it. | Piopio has file attachments and `@` paths. Add a text selection → "Add to chat" in the transcript, diff, file viewer and terminal drawer. | S |
| 6 | **Chat ⇄ terminal for coding agents** | The same Claude or Codex conversation moves between the structured chat and the raw CLI without losing context, from the tab menu or the session history. [Docs](https://orca.dev/docs/agents/native-chat) | 31 runs coding agents structured only. **Continue in Terminal** (`claude --resume <id>` in the session's cwd) covers what the transcript can't show, such as the agent's own `/` commands. The reverse, importing a CLI session, is a later item. | S |

Smaller details from Orca's chat surface that are worth checking against ours:

- **Fork from this response** opens the fork *beside* the original, with the same workspace, model and permission mode.
  Orca's **/btw** asks a side question in a fork while the original keeps running. Piopio's T5 forks in place with a
  switcher, and 24 covers unrelated tasks. A /btw is closer to a quick fork than to a side conversation, so it could be
  32's **/side** with "fork" context.
- Chats that open or push to a PR show its **CI result in the conversation**. That fits PAR7's fix loop.
- Interrupted chats **resume automatically** after a restart, and a status-bar item lists the ones left to resume.
- Workers report back under a strict contract: `worker_done` exactly once with `succeeded|failed`, carrying the task
  and dispatch IDs so that a stale retry can't complete the wrong attempt. Blocking questions are `ask` calls with
  options and a timeout, not TUI prompts. Heartbeats are optional (every 5 minutes by default). Piopio's board (`work/runner.ts`)
  has attempts and blocking. The attempt ID on each report is the part to copy if retries ever overlap.
  [Docs](https://orca.dev/docs/cli/orchestration)

## Already in Piopio or planned

| Orca | Piopio |
|---|---|
| Parallel worktrees, one task each | 05 B2 worktrees per session. 17 and 24 side conversations, the project board |
| Orchestration (Run, Task, Dispatch, decision gates) | The project board and helpers (26), review rounds and blocking in `work/runner.ts`. 32 `/parallel` proposed |
| Bots with `SOUL.md` / `MEMORY.md`, schedules, triggers, "Needs you", "Who can ask" | Agents as contacts (26), automations (27), NOTES.md and memory (14), Home's Needs you, owner plus allowlisted contacts (A4–A9) |
| Slack, GitHub and Linear bots | Telegram and WhatsApp (A3), connectors (12). GitHub issue → session is PAR7 |
| Commit and PR drafting, failing checks and review comments back to the agent | G2, G6, the Act mode. The automatic loop is PAR7 |
| Remote Orca Server, SSH, a cloud VM per worktree, "keeps running when the laptop sleeps" | 30 cloud target (K-phases), PAR10 |
| Mobile companion | 30 Piopio iPhone app |
| Inline visuals in replies | 25 visuals |
| Queue while busy, steer | T4 (Enter queues, ⌥Enter steers) |
| Mobile emulator the agent can drive | PAR9 |
| Computer use | 23 |
| Auto / Manual / Yolo permissions | AP modes (Ask, Auto-edit, Full auto) |

## Not worth bringing

- **Any CLI in a terminal tab.** Thirty-five agents through a PTY trades the transcript, approvals and checkpoints for
  breadth. Spec 31 deliberately picks a few agents with structured protocols.
- **The plugin marketplace, themes, and a full editor with panes and splits.** These go against B1 (agent first, no editor) and a
  native, single-author app.
- **Hosted bot connectors** (Slack apps, Linear labels) need a sign-in to Stably's service. That conflicts with X1 (no
  Piopio-hosted backend) unless they run from the user's own Cloudflare Worker (13, 30).
- **Federated workers across machines** (`--on windows`) are too much before K2–K3.

## Suggested next step

Do #1 first. It's specced (BR3), it sits next to the review panel that shipped today (PAR4), and its tray-then-send
pattern is what #3 reuses. #4 is the cheapest fix for a daily annoyance with worktrees.
