# 24 — Side conversations

Status: decisions SC1–SC9 confirmed by the user 2026-11-12; the questions of §9 decided 2026-11-14; nothing here is built. Reference: the Claude
desktop app, which opens a separate session when a request has nothing to do with the one you're in
([the card](../design/side-conversations/reference-card.png), [the note back](../design/side-conversations/reference-note.png)).

## 0. Where this comes from

A long conversation collects unrelated work. You're redesigning the agent page and remember that the start page lost
its centered layout; you write it where you are, because that's where you are. From then on the conversation carries
two subjects: the context fills with both, the title describes one, search finds the second under the wrong name, and
a rewind or a fork takes both along.

Piopio already has pieces of an answer, none of which does this:

| Piece | What it does | Why it isn't this |
|---|---|---|
| Subagents (`task`, 05-build §4) | A child session for a piece of the current task; its result returns to the turn | You don't talk to it, and it's part of the same task |
| Fork (T5, `sessions.fork`) | You copy a conversation from one answer | By hand, no brief, no link back, no report |
| Continue in (18 §5) | Takes a loose chat to a project folder | Moves the whole conversation; one subject still |
| Board tasks (19, 20 PT6; since 2026-11-17, 26) | Piopio hands pieces of one job to helpers, shown as cards in the conversation | Delegation inside one job, with review and merge |
| Dispatch (17) | One router that never works and hands everything out | A separate place you must go to; planned. Since 2026-11-17 dropped: from Home, Piopio starts side conversations across projects (26 CL11) |
| Notebook organizer (04-chat §3.3) | Routed every message to a topic | One front door for everything; removed by CF4 |

What's missing is the small version: **any conversation notices that something is a different subject and gives it
its own conversation, linked to this one, which reports back when it's done.**

## 1. The experience

1. **You ask for something else.** In the agent-page conversation you write "also, bring back the centered start page
   for + and New project". Before doing anything, Piopio shows a card: **This looks like its own task** —
   **New conversation** (Return) · **Do it here**.
2. **It starts beside this one.** On New conversation the card becomes the side conversation's card: its title, a
   status dot and one live line ("Reading RootView.swift", "Running tests", "Retrying the capture"). The conversation
   you're in goes on with what it was doing.
3. **It tells you when it matters.** When the side conversation finishes, asks something or fails, a row appears here:
   **Message from** *Bring back the centered start page* **›**. If that changes anything here, Piopio says so in a
   line or two; if not, the row is all you get.
4. **Open it whenever you like.** The card and the row open an ordinary conversation with its own title, history,
   diffs and cost. What you write there goes to it directly. A bar at its top says **Started from** *Agent page
   redesign* **›**.
5. **Piopio proposes, you start.** Finishing a fix, it notices the same bug in the team page. That's outside what you
   asked, so it leaves a card: **Proposed: Fix the same clipping in the team page** — **Start** · **Dismiss**. Nothing
   runs until you press Start. An untouched proposal goes away after a week.
6. **You can just ask.** "Do that in the background", "in parallel", "in its own conversation", or `/side <what>`:
   it starts with no question.
7. **You change subject while it's working** (later, SD4). You write about something else mid-task. The task in
   progress moves to a side conversation and carries on there; this conversation answers you now.

The whole model: **one subject per conversation; a new subject gets its own, linked, and nothing starts without your
words or your click.**

## 2. Decisions (confirmed 2026-11-12)

| # | Decision | Alternative considered |
|---|---|---|
| SC1 | **The conversation's own model decides** what is a new subject, by a rule in its prompt (§3). | A classifier (utility model) on every message before the turn: faster card, works with weak models, but a second opinion to tune and a cost on every message (SCQ2). |
| SC2 | **A request for unrelated work is offered, not moved.** The card asks; Return takes New conversation. | Start it without asking (quieter when right, disorienting when wrong); a setting can allow that later. |
| SC3 | **Three ways to start, all yours:** *offered* (you asked for the work; the card asks where), *asked* (you said "separately"; starts now), *proposed* (Piopio's idea; a card you may start). | Let the model start what it proposes within a budget, as a team lead does (TD3). Not here: a lead was given a job; this is unasked work. |
| SC4 | **A side conversation is an ordinary conversation** of the same kind, in the same project, listed under its parent. Not a new container kind. | A lighter "sub-thread" drawn inside the parent's transcript: keeps you in one place, but brings back two subjects in one history. |
| SC5 | **Same project, same or narrower permissions, same "who"** (Piopio or an agent; before 26, also a team's lead) as the parent. It can't give itself more than its parent has. | Let the brief choose. |
| SC6 | **Work that changes files in a git project gets its own worktree** (BP5); read-only work shares the folder. In a folder without git it shares the folder, is told which files are its own, and edits to files changed on disk since it read them are refused (SCQ4). | Always share the folder: simpler, and two conversations overwrite each other. |
| SC7 | **It reports back with a short note, which may wake the parent** when the parent is idle and no other side conversation of its own is still working. | Notes only shown, never read by the model (SD1 ships this way first). |
| SC8 | **Your conversations only.** Loose chats and project conversations (lead conversations, before 26). Not agents' conversations with other people, not debates. | — |
| SC9 | **Manual first, noticing second** (as CF5 did for moving): `/side`, a message action and "asked" ship before offers and proposals. | Ship the noticing first; it's the part that needs tuning on real use. |

## 3. What counts as a new subject

The rule the model is given, in order:

- **A new task:** unrelated work that a fresh conversation would do just as well from your words alone. It builds on
  nothing done, found or decided here.
- **Everything else stays:** a correction, a follow-up, a question, the next iteration of the work here, going ahead
  with what was just investigated ("ok, do it"), and anything a few tool calls settle, whatever it's about.
- **When unsure, it stays.** A wrong offer stops you and makes you choose; a wrong stay only makes this conversation a
  little longer.
- **A piece of the task at hand is never a side conversation,** however large or parallel: wide searching, the
  independent parts of one change, testing or reviewing what was just built. Those are subagents (`task`), whose
  result comes back to this turn.
- **A side conversation is for a task of its own:** it outlives this turn, a short brief is enough to start it, you
  may want to open, steer or review it apart from this work, and it ends in something of its own (a branch, a PR, a
  document, an answer you'll read later).

On a turn that is a new task, the model's **first** action is the offer, with only a title, so the card is up before
it has read a file. It writes no brief and does no work until you choose.

A proposal is for work the model concludes or notices while working: out of scope, a fix spotted in passing, the
follow-up its own answer recommends. At most three per turn, none twice, and never for what it's about to do anyway.
Work that only acts on what this conversation just found (the fix for what it just diagnosed) is not proposed away:
it's offered here, as a question, because a new conversation would have to find it all again.

## 4. What the model gets

One tool group, `side`, in every conversation of §2 SC8. Names are stable across Build (pi SDK) and chat (pi-durable),
as with `piopio-history`.

| Tool | Does |
|---|---|
| `side_offer({title})` | Shows the offer card and waits for your choice: `new` or `here`. Durable: survives a restart while waiting. On `here` the model does the work in this conversation. |
| `side_start({title, brief, context?, workOn?, model?})` | Starts a side conversation with `brief` as its first message. Returns at once with its id. Allowed after `side_offer` answered `new`, or when your message asked for separate work. |
| `side_propose({title, brief, why})` | Leaves a proposal card. Returns at once. Start on the card runs it with that brief. |
| `side_dismiss({id})` | Withdraws a proposal that went stale (done here after all, or replaced by a better one). |
| `side_send({id, message})` | A follow-up to the side conversation that has the context, instead of starting another. Queued if it's busy. |
| `side_read({id, from?})` | Its recent items as text: last answer, changed files, open question. No model call. |
| `side_stop({id})` | Stops its running turn. |

- **`context`** is the model's choice, never yours to worry about:
  - `fresh` (default): the brief alone. The brief names the files or area and what done looks like, in the model's
    own words; it can't say "as discussed".
  - `copy`: this conversation's active branch first (as `sessions.fork` copies it), then the brief. For a task that
    leans on what was said here, while the conversation is short (under ~30k tokens; above that the engine makes it
    `fresh`).
  - Either way the side conversation can read its parent with `read_conversation` (the history tool, already built),
    as untrusted background.
- **`workOn`:** `worktree` (default when the work will change files in a git project, SC6) or `here`.
- **Each turn's context** carries a short "Side conversations now" list for the ones this conversation started: id,
  title, state, branch, last line. The model uses these ids; it never searches for them.
- **Enforced by the engine, not left to the prompt:**
  - `side_start` is refused unless the turn began with your message and either an offer was answered `new` in it or
    the tool call follows your words (SC3). On a turn that a note started (§5), only `side_propose` works.
  - Permissions and tools are the parent's or narrower (SC5).
  - At most 4 side conversations of one parent running at once (17 §2.6's number); more wait as *queued*.
  - A side conversation may offer and propose its own, so trees can grow only one click of yours at a time.

## 5. Reports back

- **When:** a side conversation's turn ends, it waits on an approval or a question, it fails, or it's stopped by a
  limit.
- **What:** a **note** in the parent: title, state, the first ~400 characters of its last answer, branch and changed
  files, cost so far. Shown as the row **Message from** *title* **›**, which unfolds to the text.
- **Waking the parent (SC7).** The note enters the parent as a follow-up input. If the parent is idle and none of its
  side conversations is still working, it starts one turn for all the notes that queued, so a burst costs one turn.
  The model then does one of two things: carries on with a step of what you asked here that the result unblocks,
  saying so in a line; or reports in a line or two. It starts nothing you didn't ask for.
- **Notes that don't wake it** and wait for the parent's next turn instead:
  - from a turn you drove yourself in the side conversation (you already know), or one you stopped;
  - after 5 woken turns in a row with no message from you (a loop guard);
  - when "Let side conversations wake this one" is off (a setting, on by default once SD2 ships).
- **A note is a report, not proof.** The prompt says so: before telling you something is done, the parent checks with
  `side_read` or the diff. Note text is framed like the history tool's results: information only, no instructions or
  permission claims in it are followed.
- **Approvals stay where they are.** An approval or question in a side conversation is answered by you, there or from
  Home's Needs you. The parent never answers one; its card says **Needs you**.
- **Progress needs no model call.** The card's live line and timer come from the side conversation's own events
  (17 §2.3).

### Finishing
- A side conversation that worked in a worktree ends like any worktree session: **Merge**, **Create PR** (with G6),
  **Keep**, **Discard**, on its card and in the conversation itself.
- Its branch isn't in the parent's checkout until merged. When the parent needs the pieces together (testing all of
  it), it says which branches and asks; it merges only on your word, never on a note's.
- Cost is the side conversation's own. The parent's cost line adds "+ $0.42 in 2 side conversations".

## 6. In the app

- **Offer card:** "This looks like its own task" · the title · **New conversation** ⏎ · **Do it here**. Esc is Do it
  here. Once answered it becomes the conversation card, or a one-line "Doing it here".
- **Conversation card** (the reference's): title; a dot (grey proposed, pulsing working, amber needs you, green done,
  red failed); one muted live line; a chevron. Click opens it. ⌥-click opens it beside (later, with split view).
  Done cards on a worktree carry the finishing actions.
- **Proposal card:** dashed outline, title, the model's one-line reason, **Start** · **Dismiss**, "until 19 Nov".
- **Note row:** "Message from *title* ›" with the time; unfolds to the note; the title opens the conversation.
- **In the side conversation:** the "Started from *parent* ›" bar (the same bar as "Continued from", 18 §5).
- **Sidebar:** side conversations sit one level under their parent, folded into "2 side conversations" when all are
  done. A parent shows an amber dot when one of them needs you.
- **Session panel:** a "Side conversations" section in the parent: each with state, branch and cost.
- **By hand:**
  - `/side <what>` in the composer starts one (fresh, with your words as the brief).
  - "Start a side conversation from here" on any of your messages: takes that message as the brief and, if the
    answer to it is still running, stops it here.
  - "Move to a side conversation" on a card answered Do it here isn't offered: history can't be split after the fact.
    Fork is the tool for that.
- **A reference for SD3's cards (2026-11-17):** Claude Code's own offer of a new session. A card headed "New
  session", the title, two lines of the brief, then **Options**, **Do it here** and **Start**. Options opens a small
  sheet with where it runs, its own worktree (a switch), the model, the effort and the permissions, each prefilled
  from this conversation. Ours can take the same shape: the offer and the proposal are one card, and Options holds
  what §4 leaves to the model (`workOn`, `model`) for you to change before it starts.
- **Settings › Conversations:** *When I bring up something unrelated:* Ask (default) · Always start a side
  conversation · Do nothing. *Propose follow-ups:* on. *Let side conversations wake their parent:* on.

## 7. How it's built

### Engine
- **`side.ts`:** the links (parent, children, proposals with their expiry) in the catalog, and the rules of §4.
  Starting goes through the same path as `sessions.create` (worktree option included) or `sessions.fork` for `copy`.
- **`tools/side.ts`:** the `piopio-side` extension, defined for both runtimes like `tools/history.ts`.
  `side_offer` waits the way approvals and questions do.
- **A report bridge** watches the state of sessions that have a parent link (as the subagent bridge and the team
  runner do for theirs) and submits notes with `whenBusy: "followUp"`. This is 17 §2.3's bridge; build it once and
  let board helpers and `task` use it too (26 §7.1).
- The prompt section of §3 goes in `runtimes/prompts.ts`, added only when the tool group is on.
- A proposal's Start and a queued start survive a restart; expired proposals are swept on launch and daily.

### Protocol
- `SessionSummary.side?: { parent: { id, title }, how: "offered" | "asked" | "proposed" | "manual" | "handoff" }`
  and `SessionState.sides?` (the parent's list, for the panel and the sidebar).
- New `SideItem` (`kind: "side"`): `sideId?`, `title`, `state` (`offered`, `here`, `proposed`, `dismissed`,
  `expired`, `queued`, `working`, `needs_you`, `done`, `failed`, `stopped`), `line?`, `why?`, `branch?`, `costUsd?`,
  `expiresAt?`. Updated in place, like `RoutingItem`.
- New `SideNoteItem` (`kind: "side_note"`): `sideId`, `title`, `state`, `text`, `branch?`, `files?`, `costUsd?`,
  `woke: boolean`.
- `sessions.side.answer({ ref, itemId, choice })` for offer and proposal cards;
  `sessions.side.start({ ref, title?, brief, fromItemId? })` for the manual paths.
- Settings: `side.onUnrelated: "ask" | "start" | "off"`, `side.propose`, `side.wakeParent`, `side.maxRunning`.

### Tests
With the scripted model and a fake clock:
- An unrelated request: the offer is the turn's first call; New starts a linked conversation; Do it here doesn't.
- Restart while the offer waits: the card is still there and still answers.
- `side_start` without your words or an answered offer is refused; on a note-started turn too.
- `copy` carries the active branch; over the size limit it becomes `fresh`; the child can read its parent.
- A git project: the child works in a worktree and the parent's files don't change. Read-only: same folder.
- Permissions are never wider than the parent's.
- Two notes while the parent is busy become one turn; a note while a sibling works waits for the sibling.
- A turn you drove in the child doesn't wake the parent. The sixth woken turn in a row doesn't happen.
- A proposal expires after seven days; Dismiss and `side_dismiss` remove it; Start after a restart works.
- The fifth running child waits as queued.
- An approval in the child shows Needs you on the card and in Home; the parent can't answer it.

## 8. Milestones

| Milestone | Scope | You can |
|---|---|---|
| **SD1 · By hand and by asking** | `/side`, the message action, `side_start` when you ask in words; links, the card with its live line, the Started-from bar, sidebar nesting, the panel section; the stale-edit check for shared folders (SCQ4); notes shown but not read by the model. | Say "do that in its own conversation" and watch it work beside this one. |
| **SD2 · It reports back** | Notes wake the parent (SC7) with batching and the loop guard; `side_send`, `side_read`, `side_stop`; "Side conversations now" in context; finishing from the card. | Ask for two things, keep working, and get "both done, merged?" here. |
| **SD3 · It notices** | The rule of §3, `side_offer`, `side_propose` and `side_dismiss`, expiry, the settings, "Don't ask again" after three (SCQ3), the project chip on loose chats' offers (SCQ5). A replay set of ~60 real messages from this repo's conversations (half continuations, half new tasks), as the Notebook routing replay did. | Change subject and be asked where it goes. Accept: ≥ 90% of new tasks offered, and at most 1 false offer in 20 continuations, on the default models. |
| **SD4 · Hand-off mid-task** | A new subject while a turn runs: the running task moves to a side conversation (`copy` plus the remaining plan; in a worktree project it commits first and starts from that tip) and this one answers. | Interrupt without losing the work in flight. |
| **Later** | Open beside (split view) · a utility-model check before the turn, if SD3's replay asks for it (SCQ2) · a side conversation in the cloud or in another project ("in the api repo"; another project is brought forward, 26 CL11) · agents' own conversations · Watchdog W1–W5 (17 §4) on side conversations. | |

SD1 and SD2 need nothing that isn't built. SD3 is prompt work on top; it should wait for a week of using SD1–SD2 by
hand, which also produces the replay set.

## 9. Questions decided (2026-11-14)

All seven went with the proposal.

- SCQ1 · **The name: "side conversation"**, and `/side`. It reads naturally where the app says "conversation"
  everywhere (CF1); "Branch" stays with forks.
- SCQ2 · **No check before the turn yet.** SD1–SD3 ship with the prompt rule of §3 alone; SD3's replay set measures how
  often small and local models miss or are late, and that decides whether the utility model (on-device, AQ7) judges
  "same subject or new?" before the main model runs (Later, §8).
- SCQ3 · **Ask every time, with a way out after three.** After three New conversation answers in a row, the card offers
  "Don't ask again", which sets *Always start*; Settings turns it back. Ships with the offers, in SD3.
- SCQ4 · **Folders without git share the folder, with a stale-edit check.** The brief names the files that are the side
  conversation's own, and an edit to a file changed on disk since that conversation last read it is refused, so it
  reads again first (today the edit tool only fails when its old text no longer matches). The check ships in SD1 and
  serves any two conversations in one folder, not only side ones.
- SCQ5 · **Loose chats get a project chip, in SD3.** When a loose chat's side brief is plainly about a known project
  ("in piopio, …"), the offer card carries that project's chip, which you can change or clear: a Continue-in in one
  step. Before SD3 a loose chat's side conversation stays loose.
- SCQ6 · **In a team project, the lead decides.** Parts of the job in front of it go on the board; another subject
  becomes a new lead conversation (PT6), offered as any side conversation is. Since 26 (2026-11-17) the lead is
  always Piopio, so read "a project with parallel work on"; SC5's "who" is Piopio or an agent.
- SCQ7 · **No auto-archive in v1.** A done side conversation stays until you archive it; the card in the parent stays
  the way back. Revisit after real use.

## 10. SD1–SD2 as built (2026-11-17)

- **Engine** (`sessions.ts`, `tools/side.ts`):
  - `startSide` makes a side conversation as an ordinary conversation of the parent's kind, in its project. It gets
    the parent's model, thinking, permissions, profile and tools turned off.
  - In a git project, when it isn't Read only, it gets a worktree on `side/<title>-<id>`. With `workOn: "here"` it
    shares the folder.
  - Its first message is the brief, plus a line naming the parent it can read with `read_conversation`.
  - Past 4 running for one parent, it waits as queued and starts when one ends.
  - The link is `SessionSummary.side`: `{ parent, how: "asked" | "manual", state, line }`. The state is queued,
    working, needs_you, done, failed or stopped. The line ("Editing about.html") updates at most once a second.
- **Tools**, for your own conversations (not a helper's or a subagent's):
  - `side_start` is refused unless the turn's last user message is yours, not one starting `[Side]`, `[Board]` or
    `[Routine]`.
  - `side_send` is queued if the side conversation is busy, and added to the brief if it's queued.
  - `side_read` gives the state, branch, cost, what's committed and changed on its branch, and its last answer, in
    6,000-character pieces.
  - `side_stop`.
  - Each turn's system prompt has the rule of §3 for asked work, and "Side conversations now".
- **Notes back** (§5), when a turn ends, or when the side conversation waits on an approval:
  - the note says what happened, its branch, its cost and the first 400 characters of its answer;
  - it comes as a `[Side] “Title” (id) finished…` follow-up that wakes the parent;
  - while a sibling is still working, notes wait for it, and arrive together in one turn;
  - after 5 woken turns in a row without you, or from a turn you drove in the side conversation yourself, the note is
    quiet: a `piopio.side_note` message, shown as "Message from <title> · done" and read on the parent's next turn;
  - writing in a conversation yourself resets the count.
- **`/side <what>`** in any composer is `sessions.side.start`, with your words as the brief. It shows in the `/` list.
- **The app:**
  - "Started from <parent> ›" in a side conversation;
  - a "Side conversations" block above the parent's composer: a row each with its dot, title, live line and branch,
    which opens it, and **Merge** / **Discard** on a finished one whose worktree isn't merged;
  - `[Side]` notes as "Message from <title> · finished" rows that open to the answer;
  - side conversations nested under their parent in the sidebar, with the parent's dot showing when one needs you;
  - Build conversations in a worktree now find their project by its path, not the worktree's.
- **Also:** the scripted test model keeps 8 responses queued, so conversations asking at the same moment don't run
  it dry.
- **Tests:** `side.test.ts` covers:
  - asked in words: worktree, note, waking, `side_read`;
  - refused on a board turn and for a stranger's id;
  - `/side` twice, reporting in one turn;
  - a turn you drove reporting quietly.

  `ToolCardTests` checks the note rows.
- **Fixed with SD3:** chats with no project didn't get the side tools (their runtime opens on its own path).
- **Not done:**
  - `context: "copy"` (a side conversation always starts fresh, and reads its parent if it needs to);
  - the stale-edit check for shared folders (SCQ4);
  - the session panel section;
  - the message action "Start a side conversation from here";
  - the parent's cost line "+ $0.42 in 2 side conversations";
  - the settings of §6, so waking is always on;
  - a turn you drove in the side conversation is remembered until the parent writes to it again.

## 11. SD3 as built (2026-11-17)

Built before the week of SD1–SD2 by hand that §8 asks for, so the noticing rule is untuned and the replay set doesn't
exist yet. That's what's left of SD3 (below).

- **Settings › Chat › Side conversations** (`chat.sideOnUnrelated`, `chat.sidePropose`, `chat.sideWake`):
  - *When I bring up something unrelated*: Ask (default), Always start one, or Do nothing;
  - *Propose follow-ups*: on;
  - *Let side conversations wake this one*: on.
- **The rule of §3** is in each turn's prompt, by setting:
  - Ask: on a new task, the first action is `side_offer`, then stop.
  - Always start: the first action is `side_start`.
  - Off: neither.

  The definition of a new task, what stays, and "when unsure, it stays" are always there with Ask or Always start.
  `side_propose` gets its rule when proposals are on.
- **`side_offer({ title, brief?, project? })` doesn't wait** (a change from §4). It leaves the card and the model stops,
  as `offer_parallel` does, so the card and its answer survive a restart without a pending tool call. Its brief is the
  part of your words that's the new task; without one, your whole message. It's refused when offers are off, and on
  a turn that a note, the board or a routine started.
- **The card** (`ItemRenderer`): "This looks like its own task", the title, the brief and **New conversation** ·
  **Do it here**. It stays out of folded steps.
  - **New conversation** (`sessions.side.answer`, choice `new`) starts the side conversation, with `how: "offered"`.
    You stay where you are, and it shows in the block above the composer.
  - **Do it here** sends "Do it here." as your words.
  - A card answers once; a second click says why it can't.
  - After three New conversation in a row (since the engine started), the app asks "Start these on their own?",
    and Always start sets the setting (SCQ3).
- **`side_propose({ title, brief, why, project? })`** leaves a proposal on the conversation (`sideProposals`). It
  expires after a week, a proposal with the same title is refused, and at most 6 are open. The block above the
  composer shows it dashed, with its reason, "until 24 Nov", **Start** and **Dismiss**. `side_dismiss({ id })`
  withdraws one. Started ones have `how: "proposed"`.
- **Another project** (SCQ5, 26 CL11): `side_start`, `side_offer` and `side_propose` take `project`, one of your
  projects by name or id. The side conversation works in that project's folder, with its permissions, in a worktree
  when it's a git repo. A conversation with no project gets your projects' names in its prompt, so "in piopio, fix
  X; in wiki, add Y" from Home becomes two side conversations, each in its project, reporting back to Home.
- **Tests:** in `side.test.ts`:
  - offered, with New, Do it here, answering once, and three in a row;
  - proposed, with Start, Dismiss, a duplicate refused, `side_dismiss`, and the off settings;
  - from a chat with no project, into a project.

  In `ToolCardTests`, the card and the proposal line.
- **Left of SD3:**
  - the replay set of ~60 real messages and its acceptance (≥ 90% of new tasks offered, ≤ 1 false offer in 20
    continuations) on the default models, after a week of use;
  - Options on the card (where it runs, worktree, model, permissions), as in the reference;
  - the card can't show it was answered, since the transcript doesn't know the answer; the block does;
  - "at most three proposals per turn" is the prompt's, not enforced;
  - the streak for "Always start" resets when the engine restarts.
