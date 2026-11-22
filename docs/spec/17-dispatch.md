# 17 — Dispatch

Written 2026-11-03. Planned; nothing built yet. "Dispatch" is a working name (DPQ1).

> **Where this stands: decided with the user 2026-11-17 (26 CL11).** 19 TD2 made Dispatch the default team, and 26
> has since removed teams, so Dispatch as written had no home. The separate router is dropped, and what it was for
> stays:
>
> - **No Dispatch row, no router that "never does the work".** From Home, Piopio is the front door. A request for
>   work in one or more projects ("in piopio, fix the picker; in wiki, add a dark-mode toggle") becomes one **side
>   conversation per project** (24), started because you asked for separate work (SC3) and reporting back to the
>   Home conversation with notes (24 §5). This needs 24's "Later" item *a side conversation in another project*,
>   brought forward.
> - **Piopio still does small things itself,** at Home as anywhere (26 CL3). A one-line question about a project is
>   answered, not handed out.
> - **What stays from this spec:** the Watchdog (§4, DP1, DP6), non-blocking `task` (§3, DP4), PR events routed to the
>   conversation that owns the branch (§5, DP5), and §2.6's limits, which 24 already uses.
> - **What goes:** DP2 and DP3 (Dispatch's own runtime, Main, sidebar row and board), and DPQ1–DPQ3.
>
> Why: a router that only classifies and hands out is the layer that one capable orchestrator no longer needs
> (Anthropic, *When to fold subagents into your main agent loop*, 2026-10-22), and Piopio already has the two pieces
> that do the job: side conversations for separate work and Piopio for everything else. The rest of the page is kept
> as written: §3, §4, §5 and §2.6 still hold, and the parts about Dispatch's own runtime (§1, §2.1–§2.5, DP2, DP3,
> DPQ1–DPQ3) are history.

## 0. Where this comes from

DeepSeek Harness's article *Exploring Super-agent Design* (X, 2026-11-01) argues that single coding tasks now need
little supervision, so the limit is the person juggling sessions: three to five at once. Their answer is one
long-lived **Router** that takes every message and event, never does the work itself, and hands each task to an
isolated **Worker** session; workers report back, and only the Router talks to you. Around it: events instead of
prompts, routing of follow-up events straight to the worker that owns them, tools that don't block, and a
**Watchdog** outside the main loop.

Piopio has most of the pieces, in different places:

| Piece | Where Piopio has it | What's missing |
|---|---|---|
| A front door that routes and doesn't do the work | The Notebook organizer (04-chat §3.3), with link cards in Main (S1) | It only routes to chat topics |
| Isolated workers | Build sessions, worktrees (BP5), subagents as child sessions (05-build §4) | Nobody hands them work but you; `task` blocks its parent |
| Events | Agents: schedules, triggers, heartbeat (06-agents §6) | Not connected to Build |
| PR ↔ session link | Planned, G6–G8 (Phase 6) | Not built; events don't reach the session |
| Recovery | pi-durable resumes and parks crash-looping tasks | No check that a running session is making progress |

This page brings the Router/Worker pattern to Build, adds a Watchdog, makes subagents non-blocking, and routes PR
events to the session that owns them. The article's cloud-hosted loop is **not** taken: Piopio stays local by
default, and the Mac is the host (the Mac Bridge, 06-agents §10, is the same split the other way round).

## 1. The experience

1. **One place to ask.** At the top of the Build sidebar there's **Dispatch**. You write there as you would to a
   colleague: "In piopio, the model picker loses its search text when it closes. Also, in wiki, add a dark-mode
   toggle." Dispatch answers in a line ("Two tasks, starting both") and shows **two session cards**.
2. **Work runs in the background.** Each card is a normal Build session, in its own worktree, with its own model and
   tools: *🔧 Model picker keeps search · piopio · piopio/model-picker-search · working… 3 min*. You don't have to
   open them. You can keep writing in Dispatch while they work.
3. **Dispatch tells you what matters, briefly.** When a session finishes, asks a question, needs an approval or
   fails, its card changes and Dispatch writes one or two lines: "Model picker: fixed and tested, 2 files. Merge or
   PR?" You answer in Dispatch ("PR"), and it carries that to the session.
4. **Open any session to look closer or take over.** **Open →** on a card shows the full Build session, with its
   diffs, terminal and tool cards. What you type there goes straight to that session; Dispatch hears about it in the
   session's next report.
5. **Finish.** A done card offers **Merge**, **Create PR** (once G6 exists), **Keep** or **Discard**, the same actions
   as a worktree session today.

### Rules
- **Dispatch never does the work.** It has no file, shell or web tools. It starts sessions, sends them messages,
  reads them, stops them and talks to you. That keeps it fast and cheap, and keeps each task's details out of the
  other tasks' context.
- **Sessions never talk to you through Dispatch's voice.** Their long output stays in the session; Dispatch passes on
  short conclusions, and the card links to the rest.
- **You can always go around it.** Every session it starts is an ordinary Build session.
- **Nothing irreversible without you.** Merge, Discard and Create PR are your decision (DPQ5). Approvals inside a
  session stay that session's approvals, answered by you, never by Dispatch.
- **Nothing new leaves the Mac.** Dispatch and its sessions call the models you already set up. PR events (§5) use
  the GitHub access you already gave.

## 2. Dispatch

### 2.1 What it is
- **One per engine**, across all Build projects (DPQ2). A pi-durable session (`dispatch/dispatch.sqlite`) whose root
  conversation is Main, like a Notebook. It resumes after a quit or crash.
- **Model:** a fast, cheap model with tool use (default: the same as the Notebook organizer default). Sessions it
  starts use their project's Build default unless you name one ("use Opus for this").
- **It sees** the sessions it started, not the ones you started yourself (DPQ3).

### 2.2 Tools
| Tool | What it does |
|---|---|
| `start_session(project, title, brief, worktree?, model?)` | Starts a Build session in a known project, in a new worktree by default (branch from `git.suggestBranch`), with `brief` as its first message. Returns at once with the session id; the card appears. |
| `send_to_session(sessionId, message, mode?)` | Sends a message to a session: queued as a follow-up by default, or `steer`. Returns at once. |
| `read_session(sessionId, from?)` | Reads a session's recent items as text: the last answer, changed files, the open question. Long output is cut with a `from` offset to read on (§2.4). No model call. |
| `stop_session(sessionId)` | Stops the running turn. |
| `list_projects()` | Projects with name, path, default branch and the Build default model. |

Every tool returns immediately; nothing Dispatch calls waits for a session. Results come back as reports.

### 2.3 Reports
- When a session it started settles (idle after a turn), waits for an approval, asks a question or fails, the engine
  sends Dispatch a **report**: session id, title, status, the first ~300 characters of the last answer, changed
  files and branch, cost so far.
- Reports enter Main as inputs with `whenBusy: "followUp"`. pi-durable starts one run for inputs that queued while
  Dispatch was busy, so a burst of reports costs one turn, not one each.
- **Progress needs no model call.** Card status and timing ("working… 3 min", "running tests") are updated by the
  engine from the session's own events. Dispatch's model only runs for what needs judgment: done, a question, a
  failure, an approval, a watchdog note (§4), or you.
- Messages you type directly in a session are included in its next report ("You told it: …"), so Dispatch isn't
  surprised later.

### 2.4 Context each turn
Kept short, with everything else one tool call away:
- The **board**: each session it started that isn't finished: id, project, title, status, branch, a one-line
  summary, last activity. Sessions finished in the last day as one line each.
- The project list (names only; `list_projects` for the rest).
- Recent Main history.
- Every report and board line carries its session id, so Dispatch can follow it with `read_session`. Older work is
  found the same way, by ids in Main's history.

### 2.5 Policy (system section)
- One request may become several sessions; split only when the parts are independent. Several requests about one
  task go to the session that has it.
- Ask before starting when the project or the goal is unclear; otherwise start, and say in one line what was
  started.
- Replies in Main are at most three sentences unless you ask for more. Questions are direct, one at a time.
- Don't repeat what a card already shows.

### 2.6 Limits
- **At most 4 sessions running at once** (setting). Extra `start_session` calls wait, shown as *queued*.
- **A cost cap per started session** (default $3, setting). At the cap the session is stopped at its next turn
  boundary and its card says why; you can raise it from the card.
- Dispatch's own spend counts like any session's.

## 3. Non-blocking subagents

Today `task` (piopio-subagents) holds the parent's turn until the child finishes. Change it so it doesn't have to:
- `task(description, prompt, wait?)`: with `wait: false` (the new default), it returns "Started <id>" at once. The
  child's result arrives in the parent as a follow-up message ("Subagent 'Explore auth flow' finished: …"), which
  starts a turn if the parent is idle.
- `task_wait(ids)`: block until those finish, for when the parent can't go on without them.
- `task_stop(id)`.
- The session header shows "2 subagents running"; the parent can end its turn while they work. The limit of 3 at a
  time stays.

## 4. Watchdog

A part of the engine outside every session, so it can notice when a session (or Dispatch) is stuck. Rules first,
model second:

| Check | When | Then |
|---|---|---|
| **W1 Silent** | A running turn with no new item for 10 min, and no tool streaming output | Note to Dispatch (its sessions) or the Inbox (yours) |
| **W2 Looping** | The same tool call with the same arguments 3 times in a turn, or the same failing command 3 times | Note, with the repeated call |
| **W3 Waiting on you** | An approval or question unanswered for 30 min | One notification; not repeated |
| **W4 Parked or faulted** | A pi-durable `task_parked` / `task_faulted` report (threads, Notebooks, agents) | Inbox item with **Retry** (`harness.retryTask`) |
| **W5 Over budget** | §2.6's cap or an agent's budget | Stop at the turn boundary, card or Inbox says why |
| **W6 Off track** (optional, DPQ6) | A session running more than 20 min, every 15 min | The utility model reads the brief and the last items and answers *on track / drifting / stuck*; drifting or stuck becomes a note |

- The Watchdog **never stops or steers a session on its own**, except W5. It tells Dispatch, which may steer, stop
  or ask you; for sessions you started, it tells you in the Inbox.
- W1–W5 apply to every Build session and agent, with or without Dispatch. They are cheap and need no model.
- W6 uses the utility model (on-device first, AQ7). When only the OpenRouter fallback is available, it says so in its
  setting and counts the cost.
- If Dispatch's own run fails, the engine retries once, then shows the error in Main. Reports keep queuing durably.

## 5. PR events go to their session

Needs G6–G7 (Create PR, PR panel) from Phase 6.
- A session that created a PR **owns** it. While the engine runs, open PRs of kept or running sessions are polled
  (every 2 min; only while the app is open unless background mode is on).
- New review comments, failed checks, and merged or closed go **straight to the owning session**, without passing
  through Dispatch's model, per a project setting:
  - **Off:** shown in the PR panel only (today's plan).
  - **Tell** (default, DPQ4): a report to Dispatch, or an Inbox item for your own sessions.
  - **Act:** the session gets "New review comments: …" / "CI failed: …" as a follow-up and works on it; Dispatch
    hears the outcome.
- **Filtering in code first:** comments the session posted itself (kept by id, since Piopio posts with your own
  account), bots on an ignore list and people outside the repo's collaborators are dropped before anything else
  sees them. Your own comments on the PR do reach the session.
- Events on PRs that no session owns go to Dispatch, which may start a session for them.

## 6. How it's built

### Engine
- **`runtimes/dispatch.ts`**, a `Runtime` over one pi-durable session, modelled on `runtimes/space.ts`. A
  `piopio.dispatch` doc holds the board: `{sessionId, projectId, title, brief, status, branch, summary,
  lastReportAt, costUsd}` per worker, and the queue of waiting starts.
- Sessions started by Dispatch are ordinary Build sessions, created through the same path as `sessions.create`
  (worktree option included), with `startedBy: "dispatch"` in the catalog.
- A **report bridge** watches Build session state changes (as the subagent bridge does for child sessions) and
  submits reports to Dispatch.
- **`watchdog.ts`**: subscribes to session events and pi-durable reports; checks on a timer (fake clock in tests).
- `piopio-subagents` gains `wait`, `task_wait` and `task_stop`; the engine delivers finished children's results to
  the parent as follow-ups.
- PR polling in the GitHub module (with G7), routing events by the session ↔ PR link.

### Protocol
- `ContainerKind` gains `"dispatch"`; Main is `{ kind: "dispatch", id: "main" }`, and `sessions.submit` works on it.
- New `DispatchItem` (`kind: "dispatch"`): `sessionId`, `projectId`, `title`, `branch?`, `status`
  (`queued`, `working`, `needs_you`, `done`, `failed`, `stopped`), `preview?`, `costUsd?`. Updated in place, like
  `RoutingItem`.
- `SessionState.dispatch`: the board, for the side panel.
- `dispatch.configure`: model, max running sessions, cost cap per session, Watchdog W6 on/off.
- `SessionSummary.startedBy?: "dispatch"`; `SessionState.subagents?` (running children) for the header.
- `projects.configure` gains `prEvents: "off" | "tell" | "act"` (§5).
- New Inbox entry kinds for Watchdog notes.

### App
- **Dispatch** row at the top of the Build sidebar, with a count of sessions that need you.
- Main: your messages, Dispatch's short replies, and session cards (reusing the Notebook link card's look): title,
  project, branch, live status and time, a preview line, **Open →**; on done cards, Merge / Create PR / Keep /
  Discard.
- Side panel **Board**: Needs you, Working, Queued, Done today; each row with project, branch, cost.
- Sessions started by Dispatch show a small badge in the project's session list and a "Started by Dispatch" line
  with a link back.
- Inbox shows Watchdog notes with what was seen (the repeated call, the silent time) and **Open**.

### Tests
With the scripted model and a fake clock:
- One message becomes two sessions in two worktrees; both run, both report.
- Two reports arriving while Dispatch is busy are handled in one run.
- A session's question is relayed; your answer in Main reaches that session.
- The fifth start waits until one of four finishes.
- A message typed directly in a session appears in its next report.
- Restart in the middle: queued starts, running sessions and pending reports carry on.
- Merge from a done card; Discard asks first.
- Watchdog W1–W5 fire once each, on the right target; W6 with a scripted utility model.
- `task` with `wait: false`: the parent's turn ends, the result starts a new one; `task_wait`; `task_stop`.
- PR events (with G7): Off, Tell and Act, and comment filtering.

## 7. Milestones

- **DP1 — Watchdog rules.** W1–W5 for all Build sessions and agents, Inbox entries. Useful on its own, before
  Dispatch exists.
- **DP2 — Dispatch, engine.** *Dropped 2026-11-17 (26 CL11).* The runtime, tools, reports, board, limits, protocol, tests.
- **DP3 — Dispatch, app.** *Dropped 2026-11-17 (26 CL11).* Sidebar row, Main with cards, Board panel, finishing from cards, badges. Then real use on
  this repo for a week and prompt tuning.
- **DP4 — Non-blocking subagents** (§3). Independent of DP2; can go first.
- **DP5 — PR events** (§5), after Phase 6's G6–G7. *Built 2026-11-17 with G4–G8 (05 §8, as built):* Off, Tell and
  Act per project; events go to the conversation that created the PR. Bots dropped; collaborators and ignore list
  later.
- **DP6 — Watchdog W6**, once DP3 shows how often sessions drift.
- **Later.**
  - Agents reach Dispatch through `ask_agent` ("Cobot, tell Dispatch the login page is broken"), so a Telegram
    message can start Build work once Phase 5 exists.
  - **Quiet fixes:** a project policy where a failing check on the default branch, or a reported bug, starts a
    session that tries to reproduce and fix it, and Dispatch only speaks if it succeeded.
  - An LLM filter stage before events reach Dispatch, when group chats or busy repos make code filters not enough.
  - Hand a session you started to Dispatch.

## 8. Open questions

- DPQ1 · **Name in the app.** "Dispatch", "Lead", "Desk", "Foreman"? It should say "the one you talk to, who
  hands out the work".
- DPQ2 · **One Dispatch for all projects, or one per project?** Proposed: one. Asking in one place is the point, and
  it picks the project (or asks). Per project is simpler to route but brings back switching.
- DPQ3 · **Should it see sessions you started yourself?** Proposed: no in v1, so your own sessions stay yours; a
  later "Hand to Dispatch" action covers the rest.
- DPQ4 · **Default for PR events:** Tell (proposed) or Act?
- DPQ5 · **Merge and Discard always need your OK?** Proposed: yes, with no "always allow". Create PR could be
  allowed per project.
- DPQ6 · **W6 (off-track check) on by default?** Proposed: on when the on-device utility model is available, off
  otherwise.

## 9. DP4 as built (2026-11-17): non-blocking subagents

On the bridge side conversations use (24 §5), so `task`, side conversations and their reports are one mechanism
(26 §7.1).

- **`task` returns at once** by default, with the child's id ("Started ses_…"); `wait: true` keeps the old blocking
  call, and Claude Code / Codex tasks always wait.
  - Past 3 working for one parent, a task waits as queued and starts when one ends.
  - The child is a Build session with `parent: { id, callId, state, line }`. Its state is queued, working, done,
    failed or stopped, and the line is what it's doing now.
- **Its result comes back as a `[Task] “Title” (id) finished.` message**, quoted and cut at 8,000 characters, that
  wakes the parent. While another child of the parent (a subagent or a side conversation) still works, results wait
  for it and arrive in one turn. The loop guard (5 woken turns without you) is shared.
- **`task_wait({ ids })`** collects results in this turn; those then don't come back as messages. **`task_stop({ id })`**
  stops one, or keeps a queued one from starting.
- A blocking `task` now goes through the same path (start, then wait), so its card still shows progress.
- A subagent or side conversation that the engine was in the middle of when it quit is marked stopped at the next
  start.
- **In the app** (until 2026-11-22; [37](37-subagents-beside.md) replaced all three with one live row per subagent,
  opened beside the conversation):
  - the task card reads "started · its result comes back here";
  - `[Task]` messages are "Result from <title> · finished" rows that open to the answer;
  - running subagents show in the block above the composer ("Subagents · 1 subagent running"), with what each is
    doing, and open their session.
- **The scripted model:** its `task:` shorthand waits (the blocking path); `call: task | {…}` scripts the
  non-blocking one.
- **Tests:** `tasks.test.ts` covers:
  - return at once, then a waking result;
  - `task_wait` with no message after it;
  - `task_stop`, and a stranger's id refused;
  - queued past three, and batched results.

## 10. DP1 as built (2026-11-17): the Watchdog's rules

`packages/engine/src/watchdog.ts` follows every open Build session and chat. Agents aren't covered yet: their runs are
pi-durable's, and a failed run already reaches the Inbox.

- **The rules:**
  - **W1 Silent:** a running turn with nothing new (no item, no tool output) for 10 minutes. The note says how long
    and what's running ("while running `npm test`"). It goes away when anything new arrives or the turn ends.
  - **W2 Looping:** the same tool call with the same arguments 3 times in a turn, or the same failing command 3
    times. The note stays after the turn, until you dismiss it or the next turn starts.
  - **W3 Waiting on you:** an approval or question unanswered for 30 minutes gets one notification, "Still waiting
    for you after 30 minutes: …", and no note.
- **W4 and W5 aren't separate rules.** A parked or faulted pi-durable task is the agents' Inbox `run_failed`. Over
  budget is the board's budget per job and the agents' budgets. With Dispatch gone (26 CL11), §2.6's cap has no
  owner.
- **Where a note goes** (the Watchdog never stops or steers anything):
  - a side conversation's or a subagent's goes to its parent, as its report (`[Side] “…” looks stuck: …`), through
    the bridge of 26 §7.1;
  - a board helper's goes to the conversation that made the task (`[Board] T2 “…” looks stuck: …`), a row there like
    "sent back";
  - yours goes to Needs you (and Home's Waiting on you), with **Open conversation** and **Dismiss**, under Problems,
    plus a notification.
- **Protocol:** `watchdog.list`, `watchdog.dismiss`, and the `watchdog.changed` notification. Notes are kept in
  `<home>/watchdog.json`.
- **Thresholds** are engine options (`silentMs`, `waitingMs`, `tickMs`); tests use seconds.
- **Tests:** `watchdog.test.ts` covers:
  - W1 with what's running, and the note going when the turn moves on;
  - W2 staying after the turn until dismissed;
  - W3 as one reminder with no note;
  - a stuck side conversation reported to its parent, not to you.

  `ToolCardTests` checks the board rows.
- **Not done:**
  - W6, the utility model's "on track / drifting / stuck" check (DP6);
  - the thresholds as settings;
  - agents' runs.
