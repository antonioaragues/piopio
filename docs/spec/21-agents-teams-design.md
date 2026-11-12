# 21 · Agents and teams: the design handoff, as a plan

Status: plan, 2026-11-10; nothing here is built yet. The design is `docs/design/agents-teams` (Claude Design: open
`Agents and teams.dc.html` in a browser; the README is the written spec, and it wins over `docs/design/agents-brief.md`).
It builds on 20 (projects, agents and teams) and changes some of its choices (§2).

**The idea, in the design's words:** start from what you want to happen, not from which kind of object to create.
Agents, teams and projects share one visual language: an avatar, a colour and a role verb.

## 1. What changes, in short

- **Sidebar:** one Agents section holds your agents and your saved teams. Teams that only live in a project show only
  on that project's row, as an avatar stack.
- **Agent page:** two tabs, Chat and Setup. A glance strip (Next · Can · Reaches you · This month) replaces the info
  panel and the Activity tab; runs become dividers in the chat.
- **Agent setup:** six sections ordered by questions, and each tool is Off · Asks · Allowed, in place of one approval
  mode.
- **Team page:** members drawn as the path a task takes (Plans → Does tasks → Reviews → Merges), with an inline
  editor, an add-member picker and team settings.
- **Project:** "Who works here" as two cards (Piopio alone · A team), a fit check when a team joins, and an inline
  team picker on the empty Board.
- **Conversations:** a "with the lead ⌄" pill in the composer, `@agent` to bring one of your agents in for a message,
  the plan as one live block, and the merge card in the conversation.
- **Journeys:**
  - **Teams are born in a project:** Piopio offers one when work grows.
  - **Agents are made by talking** and "come alive".
  - **Agents can join teams.**
  - **Home absorbs Needs you,** with a Today timeline.

## 2. Decisions this takes (to confirm)

The handoff's data model was agreed in Claude Design. Against 20, it means:

| # | Decision | Was (20) |
|---|---|---|
| AD1 | **Teams are born in a project.** A team made there lives only there (`saved: false`) until you save it for reuse; Agents › + can still make one. | Teams › + first; every team listed |
| AD2 | **One Agents section** lists your agents and saved teams. The Teams section goes. | A Teams section |
| AD3 | **A member is your agent or a team-only agent.** Team-only members inherit the team's settings (model, tools) and can become your agents. | A role card with an optional agent |
| AD4 | **Agents are never assigned to a project.** They join a conversation with `@name`, or when the model calls them. | Open question in 20 §9 |
| AD5 | **Routines have two owners:** an agent (it messages you) or a project (it opens a session there, with the lead when there's a team). | Routines on the team |
| AD6 | **Per-tool permissions** for agents: Off · Asks · Allowed. | One approval mode |
| AD7 | **Memory has an owner:** what an agent learns in a team goes to the team's or the project's notes, never to its own memory; the UI says so when it joins. | Same in practice, unstated |
| AD8 | **Home absorbs Needs you,** and adds "While you were away" and a Today timeline. | A Needs you page |
| AD9 | **The plan is one live block** in the conversation; grey event lines only for what's notable (sent back, blocked). | Task chips plus an event line per update |

## 3. What exists, what's new

| Area | Today | Work |
|---|---|---|
| Team saved / team-only | Every definition is listed | Engine: `saved` on definitions; app: lists |
| Team settings | Model; review limit fixed at 3 | Engine: review limit, budget per job, tools for team-only members |
| Member source | `agent?` on a role | Engine: explicit source; "make it one of your agents" |
| Project routines | On the team | Engine: move to the project; fire with the lead or Piopio |
| Per-tool permissions | `tools` + `policies.requireApproval` | App mostly: three states map onto these; no engine change expected |
| `@mentions` | `ask_agent` between agents | Engine: let a conversation ask one of your agents; app: mention picker and indented replies |
| Switch a conversation to the lead | A conversation is born with or without a team | Engine: make an existing conversation the lead's (5b) |
| Draft a team from the repo | Draft from a sentence | Engine: read the project (language, tests, checks), suggest your agents, estimate cost |
| Cost per job | Per session | Engine: sum a conversation's tasks; stop at the budget |
| Fit check | None | Engine: git? checks? AGENTS.md? with one-click fixes |
| Home timeline | Upcoming per agent | Engine: routines across agents and projects |
| Sidebar, agent page, setup, team page, project settings, Home | Spec 20's | App: rebuilt to the handoff |

## 4. Phases

Each phase ships on its own, with tests, isolated captures and a note in this spec, like 19 and 20. Sizes are relative
(S, M, L).

| Phase | Scope | Done when | Size |
|---|---|---|---|
| **D1 · The model** | AD1, AD3, AD5 in the engine: `saved` teams and team-only teams, team settings (review limit, budget per job, tools for team-only members), member source, project routines (moved from teams; with or without a team), cost per job. Migration from 20. | A project's team isn't listed until saved; a routine on a project without a team opens a session with Piopio; a job stops at its budget. | M |
| **D2 · Sidebar and Home** | 1a sidebar: Agents with saved teams (avatar stacks), project rows with their team's stack, unread and Draft. 5e Home: Waiting on you (inline Allow, Review, answers), While you were away, Today timeline. Needs you folds into Home. | Everything waiting, what happened and what's next for the day are on Home; there's no Teams section. | M |
| **D3 · The agent page** | 2a: Chat · Setup, the glance strip, runs and held messages as dividers (quiet runs collapsed), the setup-change card with Undo, inline permission requests, Run now. 2c Setup: six sections, routines as sentences with toggles, the Off · Asks · Allowed list, quiet hours, limits. | You read an agent's state in one strip, its runs in its chat, and change a tool to Asks in one click. | L |
| **D4 · Making agents** | 5a: "What should I do for you?" with chips, "Question n of 3" with quick replies, it comes alive (avatar, colour and name animate in, sidebar and header together), the identity card, the trial run. 5d: Join a team (team, role, what it keeps), a team-only member's page and "Make it one of your agents". | You make a morning-briefing agent by talking, it runs once now, and it shows "Next: tomorrow 8:00". | M |
| **D5 · The team page** | 3a: the chain of work, the inline editor, the add-member picker (your agents · new, only in this team), team settings, Projects with status, Save as template in •••. | You swap QA for your Code reviewer agent and set "sent back at most 2 times". | M |
| **D6 · Working with a team** | 4a project settings (two cards, mini chain, "How the team works here", AGENTS.md/NOTES.md Create), the fit check with fixes, 4b the inline picker on the empty Board. 5c: the "with the lead ⌄" pill, `@mentions` (picker, indented replies "joined for this message", "Asked …"). 5b-3/4: the plan as one live block and the merge card in the conversation, then "Save this team?". | In a project with a team, you see the plan and merge from the conversation; `@Code reviewer` answers inline. | L |
| **D7 · Teams born in a project** | 5b-1/2: Piopio offers a team when work is divisible; the "A team for <project>" sheet (a draft read from the repo, your agents suggested, detected checks, an estimate); the conversation becomes the lead's. 5d-3: a conversation that asks to be repeated offers an agent or a project routine. | You ask Piopio for a big change, accept the team it offers, and the same conversation carries on with the lead. | M |

**Order:** D1 first, since everything else reads its model. D2 and D3 are what you'll see every day. D7 needs D1, D5
and D6. D4 and D5 can swap.

## 5. How each phase is checked

- **Engine:** tests in `packages/engine/test` for every rule (saved teams, routine owners, budget per job, mentions,
  the switch to the lead, the fit check).
- **App:** captures from an isolated copy of the app (its own bundle id and home), compared with the handoff's
  artboards side by side.
- **Real models:** after D6 and D7, a trial like 20 §14 (OpenRouter, a throwaway project).

## 6. Open questions

- **Budget per job:** what's a "job": one lead conversation's tasks, or one task? The handoff's merge card shows the
  cost of the conversation's tasks ("$0.36"), so per conversation is the guess.
- **The estimate** in "A team for <project>": from the draft's members and models, and the size of the request? A
  range ("about $0.20–0.60") is safer than one number.
- **Agent page width:** the glance strip has four cells; below about 700 pt it needs two rows or fewer cells.
- **Telegram on the strip:** "Add Telegram" opens the channel setup; is the paste-the-token flow (19 T0) enough, or
  does it need its own sheet?

## 7. D1 as built (2026-11-11)

- **Saved and project-only teams** (AD1): a definition has `saved`. A team made in a project (New project, the
  project's "Give it a team") starts unsaved and lives only there; removing it from the project removes it, its folder
  stays on disk. Agents › + (New team) and teams from before 21 are saved. "Save for reuse" is on the project's Settings
  and the team page. The sidebar's Teams list and the "Your teams" menus show only saved teams.
- **Team settings** (`teams.updateDefinition`): `reviewLimit` (times review or the checks may send a task back before
  it's blocked and you're asked; default 3), `budgetPerJob` (USD), and the members' approval mode. They reach every
  project's copy. On the team page for now: "Sent back at most N times, then ask me" and "Budget per job" (D5 redesigns
  the page).
- **Cost per job** (`teams.job`): a job is a conversation's tasks; its cost is its members' and reviewers' sessions. A
  job at its budget starts nothing new: the next task is blocked with the reason, and its conversation hears it. Raise
  the budget, then move the task back to To do.
- **Member source** (AD3): a member with `agent` is one of your agents; without, it's team-only. "Make it one of your
  agents" (`teams.promoteMember`, in the member editor) makes an agent from the role (its responsibility and done as
  instructions, its model) and points the member at it.
- **Project routines** (AD5): routines belong to a project (`routines.list`, `add`, `remove`, `run`;
  `project-routines.json`). A run opens a new conversation there: with the team's lead when the project has a team,
  else with Piopio. Webhook URLs and watches are keyed by the project's id. A lead's `schedule` and `watch` add to its
  project. Routines that lived on teams move to their project at start. The project's Settings shows them with or
  without a team.
- **Not in D1:** tools for team-only members (the design's team settings): members keep Build's tools, with the team's
  approval mode. A job's cost doesn't include the lead's own conversation.

## 8. D2 as built (2026-11-11)

- **Sidebar (1a):** Search · Home · Projects · Agents · Conversations.
  - **Home** carries the count of what waits on you; the Needs you row is gone (its page stays, reached from Home's "See
    all").
  - **Agents** lists your agents, then your saved teams. An agent row has an 18 pt rounded-square avatar in its colour
    with its initial (or its glyph), and a blue dot when it wrote to you. A team row has its members as three
    overlapping circles and how many they are. + offers New agent or New team. The Teams section is gone.
  - **A project with a team** shows the team's stack on its row.
  - **Colours:** an agent's comes from its id, among the design's five hues (D4 lets you choose); a team-only member
    gets its own; the member that merges is grey (`AgentLook.swift`).
- **Home (5e):** the greeting and the box stay on top; below, two columns (one when narrow).
  - **Waiting on you · N:** each with its action in the row: "Allow" (and "Not now") for an approval, "Answer here…"
    for an agent's question or message, "Review" for a team's work ready to merge (opens the project's Board), "Open"
    for the rest.
  - **While you were away:** one line per agent or team since your last visit to Home (or the last 12 hours), with a
    dot for how it went; quiet runs ("had nothing new") are grey.
  - **Today:** a timeline of agent runs and schedules, project routines and what teams are doing now, with a "now" row
    highlighted. It runs to the same time tomorrow, under a "Tomorrow" divider, so late at night it still shows the
    morning. Event routines ("when an email arrives") come last, as "any".
  - **Held messages** are counted at the foot.
- **Engine:** `home.agenda` (`engine/src/agenda.ts`) builds it from every agent's runs, schedules and held messages,
  every project's routines and every team's tasks. An agent schedule the runtime hasn't armed yet gets its next time
  from its cron.
- **Not yet:** quiet hours by name in the footer (the design's "Quiet hours 22:30 – 7:30"): agents each have their own,
  so Home only counts held messages.

## 9. D3 as built (2026-11-11)

- **The agent page (2a):** Chat · Setup. The info panel and the Activity tab are gone.
  - **Header:** a 22 pt avatar, the name, its one line, "Paused" when it is; Chat | Setup, Run now, and ••• (Pause or
    Resume, its other conversations, Reveal in Finder).
  - **Glance strip:** Next ("Tomorrow 8:00 · weekdays", "When something happens", "Only when you ask"), Can ("Web ·
    Memory · Message you", and its Mac apps), Reaches you ("In Piopio · Add Telegram"), This month ("$0.05 of $15"
    with a bar, amber at 80%). Each opens its section in Setup.
  - **Runs in the chat:** the engine puts a line in the owner's conversation for each run, when it fired: "Today 8:00 ·
    Automatic run · nothing new, didn't write · $0.0004", "Run now · wrote to you", "… · failed: …". It updates live as
    a run ends. A line opens to the run's last answer; "Open" shows the run's own conversation, with "‹ Your chat" to
    come back. A run's message follows its line, so it no longer carries its own "Automatic run" note.
  - **Composer:** "Reply, or ask it to change how it works…".
  - **Already as designed:** the setup-change card with Undo (`set_up`'s result card) and inline permission requests
    (approval items with Not now / Allow).
- **Setup (2c):** the six questions on the left, with "History · View as file" at the foot.
  - **What it does:** name, avatar, one line, instructions, model, thinking.
  - **When it acts:** its schedules as sentences ("Weekdays at 8:00", the task, "Next: tomorrow at 8:00"); Edit shows
    the cron as "Custom" and Remove. The reminders and event routines it set itself are listed too, with "Change…"
    (asks it in the chat). "+ At a time" adds a schedule; "+ When an email arrives", "+ When a file appears" and "+ From
    a link (webhook)" start the request in its chat. Quiet hours and time zone.
  - **What it can use:** one list of tools and Mac apps, each Off · Asks · Allowed: Off leaves it out of `tools`, Asks
    adds its rule to `policies.requireApproval` (`apple_<app>_*` for an app), Allowed removes it. Shortcuts.
  - **Who it talks to:** channels (In Piopio; Telegram connected, or how to add it) and people and agents.
  - **What it knows:** memory. **Limits:** budget, messages a day, urgent messages, unknown senders.
- **Engine:** an agent's upcoming schedules always have a next time (from the cron when the runtime hasn't armed it
  yet), for the strip, Setup and Home.
- **Not yet:** run lines are quiet lines on the left, not centred dividers; a run opens to its last answer, not its
  steps ("2 steps ›"); held messages aren't lines yet; routines have no on/off toggle (schedules have no "enabled"
  field); event routines are added by asking.

## 10. D4 as built (2026-11-12)

- **A new agent starts by talking** (5a-1): Agents › + (and New Agent in the palette) makes an empty agent and opens
  its chat. It's a draft: a dashed avatar and "New agent" in the header, "Draft" in the sidebar, no glance strip. The
  engine greets with "What should I do for you?" and three ideas to tap (the greeting carries `suggestions`), and the
  composer says "In your own words…". "Turn into an agent" from a conversation still opens the start page with its
  draft.
- **One question at a time** (5a-2): the interview asks with `ask_owner` (the question, two to four answers to tap,
  its number). It shows as "Question 2 of 3" and the question in the chat, the same in the header, and its answers as
  chips above the composer. Tapping one sends it; writing your own works too. The chips go once you answer.
- **It comes alive** (5a-3): when `set_up` ends the interview, the name, avatar and line arrive in the header and the
  sidebar together, and the avatar gets a soft ring for a moment. Its **identity card** sits above the composer: "I'm
  Morning briefing", Rename · change icon, and Does · When · Uses (what asks first is marked "needs your OK") ·
  Reaches, with "Looks good" and "Change something". It shows until you answer it.
- **A trial run** (5a-4): "Looks good" runs it once now (`agents.runNow` with `trial`); its line in the chat says
  "Trial run · …", and the strip then shows what's next.
- **Routines in plain words:** a routine an agent sets itself carries its cron (`upcoming.cron`); its card reads
  "Weekdays at 8:00", not the cron, and the strip adds "· weekdays".
- **Join a team** (5d-1): on the agent's page, ••• › Join a Team…: the team, as what ("Reviews every task · replaces
  QA", or a new member who does tasks), and what changes for it there (it keeps its instructions plus TEAM.md, uses its
  own model unless the member has another, and writes what it learns to the team's notes, not its memory).
- **Fixed on the way:** opening a conversation didn't refresh views that read its items (the chips stayed empty).
- **Not yet:** ⌘⇧N stays New Project (the design gives it to New agent); choosing an agent's colour; a team-only
  member's own page (5d-2, with D5); "this sounds like a job for an agent" in a conversation (5d-3, with D7).

## 11. D5 as built (2026-11-12)

- **Header** (3a): the team's colours, its name, and where it works ("Only in piopio" for a team born in a project,
  "Works in piopio and 2 more" for a saved one); Members · TEAM.md · Notes · Projects; ••• holds Save for Reuse, Save
  as Template…, Reveal Folder in Finder, and Remove Team when no project uses it.
- **Members as the chain of work** (3a): four columns, Plans → Does tasks → Reviews → Merges. Each card has the
  member's avatar and name, its role as a sentence ("Reviews every task. Sends it back if it's wrong."), and its model,
  or "Is your agent Rita ↗" for one of your agents. A tag says `your agent` (filled in its colour) or `team only`. The
  member who does tasks says how many run at once; the merger is a dashed card, "No model · automatic". An empty
  column says what happens without it ("No one reviews: finished tasks are done.").
- **The editor sits under the chain** (3a), not in a sheet: name, does tasks or reviews, responsible for, done means,
  who it is (a new member or one of your agents), its model (or the team's); Make it one of your agents (team-only
  members), Remove from team (not the lead). Save appears once something changed.
- **Add member** (5f-2): your agents who aren't on the team yet, then "New, only in this team": a blank member or one
  from a role in the templates. The new member opens in the editor.
- **Team settings** (5f-3), the base for team-only members: what members may do without asking (`memberMode`, now
  editable through `teams.updateDefinition`), review ("3 times, then ask me"), budget per job. The team model sits
  above the chain.
- **Projects** (3a): each project with what the team is doing there ("2 tasks doing · 1 waits for you", "Idle · last
  task 3 days ago", "No tasks yet") and how many tasks run at once.
- **Captures:** `PIOPIO_DEMO_MEMBER=<role id>` opens a member's editor; `add` opens Add member.
- **Not yet:** a per-tool Off · Asks · Allowed list for members (the design's "Tools"; members keep one mode for now);
  a team-only member's own page (5d-2); dragging members between columns.

## 12. D6 as built (2026-11-13)

- **Who works here** (4a): two radio cards, Piopio alone ("Each conversation works on its own") and A team, with a
  mini chain (Tech lead → Builder ×3 → QA → CI in 16pt avatars) and a menu: Open Team, Save for Reuse, Remove from
  Project. Without a team, the menu is "Choose a team" (your teams, then templates), and "No team fits? Describe one
  for this project…" opens the team start page. Choosing Piopio alone asks before removing the team.
- **How the team works here:** Tasks at once and Checks (monospace). Routines follow, with or without a team.
  AGENTS.md and NOTES.md show "Edited 2 days ago" with Open, or Create (a short starter file).
- **The fit check** (5c-2), before a team starts in a folder (`teams.fitCheck`): git ("Start git", ticked), the checks
  found in the folder (`pnpm test`, `swift test`, `cargo test`, `go test ./...`, `pytest`, `make test`; editable),
  and AGENTS.md ("Write one with Piopio": a conversation with Piopio alone in the project writes it). Then Cancel / Add
  to project.
- **The empty Board** (4b): your teams and templates, each "Use here" (through the fit check), or "Or describe one…".
- **"with the lead ⌄"** (5c-1) in the composer of a project with a team. A conversation keeps who it began with, so
  the menu starts a new one with the other (Piopio alone or the lead). Turning an existing conversation into the
  lead's is D7.
- **@mentions** (5c-2): `@` lists your agents first ("Your agent · joins for this message"). Conversations with
  Piopio and with a lead have `ask_agent`, and the prompt lists your agents. A message with `@Rita` tells the model to
  ask her first. Rita answers in her own conversation with Piopio (her instructions, model and memory; it isn't one of
  her people, and `acceptFrom` doesn't apply to it), and the answer comes back to the conversation. It shows as "●
  Rita · joined for this message", or "Asked Rita" when the model chose to, with the answer indented under a 2pt rule
  in her colour. Members' task sessions don't get the tool.
- **The plan is one live block** (5b-3, AD9) above the composer: "Plan · 3 tasks · 1 approved, 1 blocked, 1
  building", a row per task with its dot, member and state (waiting, building, in review, merging, approved, merged,
  blocked). A row opens the task's session; Board opens the project's board. In the transcript, board updates stay a
  line only when a task was sent back or blocked.
- **The merge card in the conversation** (5b-4): once nothing of this conversation's is on the board, a green card:
  "Ready for main · 3 tasks · 2 files · checks passed · $0.36", with Merge into main, See changes (the files with
  +/−) and Push for a PR. It counts the whole team branch, since that's what merges. After a merge, a team that lives
  only here asks "This team stays on piopio. Use it elsewhere too?": Save as "App team" / Keep it here only.
- **Agent colours** come from one palette shared by the app and the transcript (`AgentPalette`).
- **Captures:** `PIOPIO_DEMO_FIT=<template id>` opens the fit check on a project page.
- **Not yet:** switching an existing conversation to the lead or away from it (D7); the agent's avatar on its answer
  (a dot in its colour for now); "Save this team?" was checked in code, not in a capture (it needs a merge from the
  app).

## 13. D7 as built (2026-11-13)

- **Piopio offers, it doesn't decide** (5b-1, 5d-3). In a project conversation with Piopio (not a lead's or a
  member's), two tools (`offers.ts`) show a card and stop the turn:
  - `offer_team` (why, the parts), only while the project has no team: "This could go faster with a team", with
    Bring in a team / Do it here, one by one. The second just answers with those words.
  - `offer_repeat` (what, when in words, a cron): "Make this happen on its own?", with Make it an agent (Turn into an
    agent's draft), Just a routine here (a project routine with that cron; the conversation is told it's set) and No.
- **"A team for piopio"** (5b-2, `teams.draftFor`):
  - The project is read for its language, checks and git (`fit.ts`). The background model drafts the members from
    that and the request; without one, a code project gets the development template.
  - Your agents are suggested where their name or line fits a member, reviewer first ("Code reviewer · suggested",
    already swapped in), and each member's picker can swap in another or go back to "Only in this team".
  - Checks come prefilled. The estimate ("About $0.20–0.60 for this request, with …") comes from the build model's
    prices and the number of parts; it's hidden when the model has no prices.
  - "Use Development team instead" for code projects.
  - `teams.create` takes the drafted `roles` and `style`, so the team lives only in this project (template "custom").
- **The conversation becomes the lead's** (5b-3, `teams.adopt`): same history, the lead's brief and the board's tools
  from its next turn (the open runtime is closed and reopened; refused while it's answering). The lead is told to
  plan what was asked; the transcript shows "Piopio team joined · the lead takes it from here", and the header and
  pill say "with the lead".
- **Tests:** `born.test.ts`: the offers, the draft from a TypeScript project with your reviewer suggested, a team
  from the draft, no team offer once there is one, adopting (and refusing another project's conversation or a second
  adopt).
- **Not yet:** the offer cards keep their buttons after you answer (Bring in a team does nothing once there's a
  team); the lead's planning and a run with a real model (the trial in §5 comes next); turning a lead's conversation
  back into Piopio's.
