# 37 · Subagents beside the conversation

Status: decided 2026-11-22 from a conversation with the user, who compared Piopio's subagents with Antigravity's.
Mockup: [docs/design/subagents/subagents.html](../design/subagents/subagents.html) (options A, B and C, with C on an
audit, a comparison and a build). **The user chose A now and C later** (SB1). It changes how 17 §9's non-blocking
subagents look. The engine's `task`, its limits and its report bridge (26 §7.1) don't change.

## 1. Why

In Antigravity a subagent is one quiet line in the conversation that turns into a check when it's done. Clicking it
opens the subagent beside the conversation, where you can talk to it. In Piopio (17 §9 as built) the same subagent
shows in three places, and none of them is the answer:

- **A "Subagent … started · its result comes back here · Open" card** in the transcript, which never changes: it
  still says "started" when the work is done.
- **A "Subagents · 3 running" block above the composer**, whose line is a raw command
  (`bash cd /Users/…/piopio && sed -n '400,460p' …`).
- **A "Result from … · finished" row** when it ends.

**Open** replaces the conversation with the subagent's session, which isn't in the sidebar, so the way back is the
parent's row. Steering a subagent means leaving the conversation that started it.

## 2. Decisions

| # | Decision |
|---|---|
| SB1 | **Option A now, C later.** A: the subagent is one live row in the transcript, and it opens in the right column. C (findings as they come: a `finding` tool, a card whose shape follows what comes in, steering by reacting) is the next layer, on top of A's column. B (one docked card) is what A falls back to in a narrow window. |
| SB2 | **One row per subagent, and it's live.** The row Piopio's `task` call draws is the subagent: a ring while it works, a check when it's done, red when it failed, dashed while queued. Its grey line is what it's doing; when it ends, how long it took and what it cost. |
| SB3 | **Plain-language activity.** The engine writes the line from the tool call: "Reading SessionView.swift", "Searching for Keychain", a command's own description, "Running the tests". Never the raw command. |
| SB4 | **It opens beside.** A click opens the subagent in the right column of the Build session, where Summary, Files and the Browser go: tabs for this conversation's subagents, its transcript as it happens, and its own composer (steer it while it works, ask a follow-up after; its approvals show there). Open in full moves to its session. When the window is too narrow for the column, the click opens the session, as before. |
| SB5 | **One place.** The "Subagents" block above the composer goes. The `[Task] … finished / failed / was stopped` result rows aren't drawn: the row says it, and the column has the answer. The parent still gets the message; only its drawing goes. Watchdog notes ("looks stuck") show on the row, in amber, until it moves again (2026-11-22). |
| SB6 | **A follow-up after it finished** is a new turn of the subagent: its row works again and its new answer reaches Piopio as another `[Task]` message, as any turn does (17 §9). |
| SB7 | **Claude Code, Codex and Antigravity tasks** keep their card: they run on your account, report no steps, and always wait. *(31 CA14, decided 2026-11-23, not built (31's A5), would change this for Claude Code and Codex: such a `task` becomes a side conversation on that agent's runtime, and `external-agents.ts` goes.)* |

## 3. What you see

- **In the transcript:** under "Thought for 12s, ran 4 commands", one row per subagent, in the order Piopio started
  them: the glyph, the title in the transcript's sans (not monospace), then the line in grey: "Reading oauth.ts" while
  it works, "queued · starts when one finishes", "done · 1m 52s · $0.03", "failed · 40s", "stopped". On hover the row
  tints and shows a chevron; the open one stays tinted.
- **The column:** tabs at its top, one per subagent of this conversation (glyph and title), and ✕. Under them the
  subagent's own transcript (its brief is its first message), and its composer with its model. Open in full is an
  icon beside ✕.
- **Above the composer:** nothing for subagents. The plan block (26 §5) stays as it is. Side conversations stay in
  the transcript, where 24 §11 put them on 2026-11-17: nothing of theirs sits above the composer either (§6).

## 4. How it's built

- **Engine** (`sessions/children.ts`, `progress-line.ts`): `progressLine` becomes plain language (SB3), from the tool and its arguments: `read`
  "Reading <file>", `edit`/`write` "Editing <file>", `grep` "Searching for <pattern>", `find`/`ls` "Looking through
  <dir>", `bash` its `description` if it has one, else a reading of its first command (cat/sed/head → "Reading
  <file>", rg/grep → "Searching for …", a test runner → "Running the tests", a build → "Building"), else "Running a
  command"; `web_search` "Searching the web for …", `web_fetch` "Reading <host>"; any other tool its name in words.
- **App, transcript** (`PiopioTranscript`): a `SubagentInfo` per child (id, title, state, line, started, ended,
  cost), set with `setSubagents` as `setSides` does. A Piopio `task` card renders as a hosted row (as the side offer
  row is), redrawn when its child changes. Its click is `.offer(kind: "subagent-open", callId: <session id>)`.
  `[Task]` notes whose verb is finished, failed or was stopped draw nothing.
- **App, session** (`BuildSessionView`): the column can show a subagent instead of its panel (`subagentOpen`), with
  its own width; `SubagentPanel` holds the tabs, `TranscriptView` of the child's `ThreadModel` and its `Composer`.
  `SideConversations` loses its subagents block.
- **Tests:** the engine's line for each tool; the transcript's row for each state and the hidden result rows.

## 5. Later: C

C needs the engine first: a `finding` tool for read-only subagents with optional `severity`, `option` + `aspect`,
`verdict` and `decision` fields, findings kept in the child's state, and citations in the parent's answer. The card
picks its shape from the fields (a list worst first, a table, hypotheses, decisions to keep or change). The mockup
shows all of them. Not started.

## 6. As built (2026-11-22)

- **Engine:** `progress-line.ts` writes the line (SB3), tested in `progress-line.test.ts`. A command without a
  description is read from its first real step, outside quotes (`cd x && sed -n '1,9p;20p' a.ts` is "Reading
  a.ts"). The line is at most one a second, and the latest always lands: before, a line that came less than a second
  after the last one was dropped, so a quick read followed by a long command kept saying "Reading…". Side
  conversations' lines get the same fix. The parent link carries `startedAt`, `endedAt` and `costUsd`.
- **Transcript:** `SubagentRow.swift`: `SubagentInfo`, the hosted row (`SubagentRowAttachment`) and `SubagentGlyph`;
  `setSubagents(_:open:)` on the document. `[Task]` notes that only say finished, failed or was stopped draw nothing.
  Tests: `SubagentRowTests`.
- **Session:** `BuildSessionView` opens a subagent in its column (`subagentOpen`, its own width, 400 by default, at
  least 340); a toolbar view icon takes the column back. `SubagentPanel.swift` holds the tabs, the child's transcript
  and its `Composer`. In a window too narrow for the column, the row opens the session. `SideConversations` (the
  block above the composer) is gone, from Build sessions and chats.
- **The column is a card** (white, like the conversation), and the composer fits it: the model chip shrinks with a
  "…" instead of pushing the box wider than the column (it did with "DeepSeek V4.1 Flash 1017 · OpenRouter high").
- **Captures:** `PIOPIO_DEMO_SUBAGENT=1` opens the first subagent beside once there is one;
  `PIOPIO_FAUX_MODEL_NAME` gives the scripted model a long name.
- **Tabs that fit** (2026-11-22): every title while they fit (each up to 140pt); then the open one's title and the
  others as their glyph, the title in the tooltip; at the narrowest, one menu of all of them with where each stands.
  At 340–400pt with four subagents it's the second step.
- **The way back:** a subagent's own session (Open in full, or the narrow-window fallback) has a "Subagent of
  <conversation> ›" bar, as side conversations have "Started from"; subagents aren't in the sidebar.
- **Narrow window:** when the window hides the column, no row stays highlighted as open (it did); widening brings
  the column back with the same subagent.
- **Checked:** a follow-up to a finished subagent (SB6) in `tasks.test.ts` with the scripted model: its row works
  again, `startedAt` moves, and a second `[Task]` result reaches the parent with the new answer. The narrow-window
  fallback in a capture (`PIOPIO_DEMO_RESIZE=700`): the click opens the subagent's session.
- **A queued subagent** (2026-11-22): its column shows "Queued · starts when one finishes" and its brief, and the box
  reads "Add to its brief before it starts…". A message to it joins its brief (`addToQueuedBrief`) and doesn't start
  it: before, it started out of turn and its brief was never sent. The parent link carries `brief` while queued.
- **The limit held only one message at a time:** tasks the model starts in one message run in parallel, and each
  counted the running ones before creating its session, so four parallel tasks all ran. The count is now taken right
  before the child takes its place. `tasks.test.ts` starts them in one message (and fails without the fix).
- **The brief says it's from Piopio:** a subagent's first message is "From Piopio · the brief" (open while it's
  under 600 characters), not a bubble of yours (`briefFrom` on the document).
- **The Watchdog's note is on the row:** "looks stuck: nothing new for 10 minutes…" in amber in place of the line,
  until the subagent does something again (`parent.alert`); its `[Task]` note isn't drawn, and the parent still gets
  it. Not seen in a capture (it takes ten quiet minutes); the row's part is in `SubagentRowTests`.
- **Not verified:** the follow-up with a real model.
