# 43 · Background work in the Summary column

Status: draft 2026-11-25 from a request by the user; **decided by the user the same day (§6: the block always last, a
number on the toolbar icon, commands and subagents only)**; **built 2026-11-25** (§7).
Mockup: [docs/design/background/background.html](../design/background/background.html) (running, one failed, all
finished, column closed and a chat).
It adds one block to the Summary column (Build's `InspectorPanel` and a chat's `ChatSummaryPanel`). It doesn't
change background commands (05 §9 TM4, roadmap PAR2) or subagents (37); it gives them one place to be seen together.

**The request (the user, 2026-11-25):** the user compared Piopio with Claude Code's "Background tasks" pane (running
work with how long it has run and a stop button, then a folded "Finished" list) and asked whether Piopio has one.
Then: "We could put it in the Summary panel, a new panel isn't needed. Write that spec."

**The idea in one line:** a **Background** block in the Summary column lists what this conversation left running and
what it ran earlier: its background commands and its subagents. Each row says how long the work has run and can be
stopped right there. It uses the column's own blocks, with no new panel or tab.

## 1. Why

Today this work shows in two places, and neither gives you the whole picture:

- **Background commands** are tabs in the terminal drawer ("npm run dev · agent"). You only see them with the drawer
  open, and a tab doesn't say how long a command has run or how it ended.
- **Subagents** are live rows in the transcript (37 SB2). Once the conversation has moved on they've scrolled away.

So to answer "is anything still running, and did what ran work?" you have to scroll back and open the drawer. The
Summary column already answers "where does this conversation stand?" (Setup, Tools, Skills, Read, Changes, Plan), so
the answer to that question belongs there too.

## 2. Decisions

| # | Decision |
|---|---|
| BG1 | **A block in Summary, not a panel.** A **Background** block in both Summary columns, drawn like the others (`BlockFold`, `inspectorBlock`). No new pane, tab or toolbar view. |
| BG2 | **Commands and subagents, one list.** The conversation's background commands (`state.processes`, Build only) and its subagents (sessions whose `parent.id` is this conversation, 37), under the subheadings "Commands" and "Subagents" only when both have rows. **Side conversations aren't listed** (the user, 2026-11-25): they have their own sidebar row and their line in the transcript (24 §11). A coding agent's own background commands (Claude Code, Codex, Antigravity) aren't Piopio's, so they aren't listed either (05 TM4, 31). |
| BG3 | **Running first, then Finished.** Running rows (queued subagents too) are always shown. Finished ones (exited, stopped, failed, done) fold under "Finished N", closed by default, newest first, five at a time, then "and N more". |
| BG4 | **Only when there is something.** With nothing running and nothing finished, the block isn't drawn: no "Nothing yet" row. |
| BG5 | **Always the last block.** Background sits at the bottom of the column, under Plan and above the footer, whether something runs or not (the user, 2026-11-25). It doesn't jump around as work starts and ends, and the blocks above keep their places. Once everything has finished, its head reads "3 finished ›". |
| BG6 | **Each row: glyph, name, how long, Stop.** The glyph is `SubagentGlyph`'s, so both kinds look alike: a ring while running, dashed while queued, a check when it's done, red when it failed or exited with an error, a square when it was stopped. The time ticks each second on the right ("1m 04s"); a command's address, when it has one, goes on the line below ("localhost:5173 ↗"). When it ends, the line says how it ended ("exited 0 · 2m 10s", "exit 1 · 12s", "stopped · 40s", "done · 1m 52s · $0.03"). On hover, a running row shows a ■ Stop button in place of its time. |
| BG7 | **A click goes to where the work is.** A command opens the terminal drawer on its tab. A subagent opens beside the conversation (37 SB4); because that column is the same one, Summary steps aside as it does today. A command's address opens the preview (22 §6.1). |
| BG8 | **Visible with the column closed.** The Summary column is closed by default. While something runs, the toolbar's Summary icon carries a small count ("2"), in grey ink, not a dot (the user, 2026-11-25), and a tooltip ("2 running in the background"). The column doesn't open by itself for this. |
| BG9 | **Stop works as it does today, without asking.** Stopping a command is `sessions.processStop`, as the drawer's Stop is. Stopping a subagent is `sessions.abort` on its session, as its own composer's Stop is: the turn ends, and the session stays. |
| BG10 | **How long it's kept.** Finished commands stay in the list as long as the engine keeps them in `state.processes`: until the session closes or the engine quits (TM4). Subagents stay because they're sessions. Until you clear them (BG11). |
| BG11 | **Clear** (the user, 2026-11-25: "I don't want them there forever"). A blue Clear link in the block's head, before the chevron, while something has finished, takes every finished row off the list. Running rows stay. It's this list only: a command's output stays in its drawer tab and in `process_list` for the agent, and a subagent stays a session. Per conversation, kept across launches (`backgroundClearedAt`): what had ended by the time you cleared isn't listed; a subagent you ask again ends later, so it's back. With nothing running, clearing leaves no block (BG4). |

## 3. What you see

Build session, something running (the column open, the block last):

```
Setup
…
Plan                                    2 of 4
  …
────────────────────────────────────────────
Background                   2 running  Clear ⌄
  Commands
  ◌  npm run dev               1m 04s  ■
     localhost:5173 ↗
  Subagents
  ◌  Audit the OAuth flow       38s    ■
     Reading oauth.ts
  ▸ Finished 3
────────────────────────────────────────────
38k of 200k                              $0.14
```

- **Head:** "Background", then "2 running" (or "3 finished" when nothing runs: while something runs, "Finished 3"
  is a row of its own), Clear when something has finished, and the fold chevron. It's
  open by default while something runs, and the choice is remembered per conversation, as Changes is
  (`inspectorChangesOpen`).
- **Command rows** take the drawer's label (`BuildTerminal.label`: the command when it's short, else the agent's
  description), in monospace. **Subagent rows** take their title, with their `line` (37 SB3's plain-language
  activity) under it while they work.
- **The Watchdog's note** (37 §6) shows on a subagent's row in amber, as it does on the transcript row.
- **Finished** unfolds into the same rows without Stop, newest first.
- **A chat** has no commands, so it shows only its subagents, with no subheadings.

## 4. How it's built

- **Engine:** nothing new. `state.processes` already has `status`, `exitCode`, `startedAt`, `endedAt` and `urls`.
  The parent link has `state`, `line`, `startedAt`, `endedAt`, `costUsd` and `alert` (37 §6).
- **App, PiopioKit:** `BackgroundWork.compute(processes:subagents:)` turns both sources into `[BackgroundRow]` (kind,
  id, title, line, state, started, ended, cost, urls, alert), split into running and finished and sorted. It's
  tested in PiopioKit (each state's glyph and line, the order, the five-then-more cut). The subagents are the ones
  `BuildSessionView.subagents` already gathers for the transcript rows.
- **App, column:** `BackgroundBlock` in `Inspector.swift` (or its own file), used by `SessionTab` and
  `ChatSummaryPanel`, always the last block (BG5): Plan's `inspectorBlock(last:)` becomes false when Background
  shows. The time ticks with a `TimelineView(.periodic(by: 1))` that runs only while a row is running and the column
  is on screen. The rows reuse `SubagentGlyph` from `PiopioTranscript`.
- **App, toolbar:** BG8's count on the Summary icon in `BuildSessionView`'s toolbar and the chat's.
- **App, actions:** a command row posts the same selection the drawer uses (`selectedProcess`) and opens the drawer.
  A subagent row calls `openSubagent(id)`. Stop calls `session.stopProcess(id)` or `sessions.abort`.
- **Captures:** `PIOPIO_DEMO_BACKGROUND=1` starts the scripted session with a background command and a subagent, and
  opens the column (the `PIOPIO_DEMO_*` pattern of 37 §6 and TM4's `PIOPIO_DEMO_PROCESS_TAB`). Capture states:
  running (both kinds), one finished with exit 1, all finished, and the column closed with the toolbar count.

## 5. Not in this spec

- **Output in the column.** A command's output stays in the drawer, which has room for it. The column only lists.
- **Side conversations.** They stay where 24 §11 put them: their line in the parent's transcript and their sidebar
  row.
- **Work across conversations.** This lists one conversation's work. A Piopio-wide "everything running" view (Home or
  the sidebar footer) is a separate question; automations already have their own section (27).
- **Commands that outlive Piopio.** TM4's rule stands: background commands stop when the engine quits.

## 6. Questions for the user (all decided 2026-11-25)

1. **Side conversations in the list (BG2):** no. The block shows commands and subagents only.
2. **Where the block goes (BG5):** always at the bottom of the column, even while something runs.
3. **The toolbar count (BG8):** a number, not a dot.

## 7. As built (2026-11-25)

- **Rows:** `BackgroundWork` and `BackgroundRow` in `PiopioTranscript/BackgroundWork.swift`, beside `SubagentInfo`
  (whose line and glyph states they reuse), not in PiopioKit as §4 said. `BackgroundWork.label` is now the one label
  for a command: the drawer's tab uses it too. Tests: `BackgroundWorkTests` (each ending's line and glyph, the order,
  the address, the ticking time, the head).
- **Block:** `BackgroundBlock.swift`. `SessionTab` draws it last; Plan, Changes or Read is no longer the last block
  when it shows. `BuildSessionView` builds it from `session.processes` and the subagents its transcript rows already
  use, and acts on it: a command opens the drawer on its tab (`TerminalDrawer.selectedProcess` is now the session's
  binding), a subagent opens beside, Stop is `processStop` or the subagent's `stop()`, and the address opens the
  project preview. The fold is remembered per conversation only when you fold it (`backgroundFolded`).
- **Chats:** plain chats (`ThreadView`, `ChatSummaryPanel`) run no background commands and no subagents (`task` is
  Build's), so the block isn't there. A Build session in the Read-only lens has it, without the drawer.
- **Toolbar:** the Summary icon's count while the column doesn't show Summary (closed, or on Files or the Browser),
  with "N running in the background" as its tooltip. The blue needs-you dot takes its place while something waits on
  you.
- **Checked** in captures of the Debug app with the scripted model (a dev server, a command that exits 1, a subagent):
  the block under Changes with both subheadings, the times ticking, `localhost:5173 ↗`, "Finished 1" unfolded
  (`PIOPIO_DEMO_BACKGROUND_FINISHED=1`) with "exit 1 · 1s" in red, and the closed column's "2" on the Summary icon.
  Not clicked in a live window: Stop, a row opening the drawer or a subagent, and the address opening the preview.
- **Clear** (BG11, the same day): the head is `BlockFold`'s with a `SummaryLink` between the counts and the chevron;
  `BackgroundWork.rows(…, clearedAt:)` leaves out what had ended by then, tested in
  `clearHidesWhatHadFinishedButNotWhatRunsOrEndsLater`. At 300 pt "2 running · 1 finished" and Clear didn't fit, so
  the head counts only what runs while something does. Captured; Clear not clicked in a live window.
