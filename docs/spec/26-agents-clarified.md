# 26 · Agents, clarified: contacts, and Piopio orchestrates the work

Status: draft 2026-11-16, from a conversation with the user; decisions CL1–CL12 confirmed by the user 2026-11-17;
the questions of §10 are still open; nothing here is built. It changes what 19, 20 and 21 made of agents and teams: it keeps the machinery they built (the board, worktrees,
review, merging, project routines) and takes teams away as something you make and manage. 06 (agents) and 19 §0 S1–S5
("simple first") still hold, more strictly.

**The idea:** an agent is someone who lives with you. Work in a project is Piopio's to organize: it splits the work
and creates helpers for it itself, and they go away when the work is done.

## 1. Why

Piopio's agents began as personal assistants, like Grok Bot (docs/research/grok-bot.md) and the other "a bot is a
contact" apps: you make one by talking, it remembers you, it acts on its own, it reaches you on Telegram. Building
teams then stretched the word until it named three different things:

| | What it is | Where it came from | Does it exist when you're not talking to it? |
|---|---|---|---|
| **A personal agent** | A contact: name, memory, routines, channels; it writes to you on its own | 06, 19 §0 S1 | **Yes** |
| **A team member** | A role with a prompt and a model, inside a project (lead, builder, QA) | 19, 20, 21 AD3 | No: it's there for the work |
| **A subagent** | A helper made for one task | `task`, 17 (Dispatch), `offer_team` | No |

To make the second fit the first, the model kept growing: saved and project-only teams, your agents joining teams,
"Make it one of your agents", memory that goes to the team when an agent works in it (21 AD7), a team page with a chain
of work and an editor. 20 was written because nobody could tell where to start (20 §1). 21 redesigned it again. It
still asks you to learn two kinds of object before a project can go fast.

The real trial (20 §14) points the other way. What worked was the lead's judgement: it did small things itself,
refused to split work that touched the same nav, and wrote scoped briefs when it did split. None of that came from
someone defining "Builder" or "QA" by hand. A strong orchestrator that makes its helpers when it needs them gives the
same result with nothing to set up.

## 2. Decisions (confirmed 2026-11-17)

| ID | Decision | Was |
|---|---|---|
| CL1 | **One test for what an agent is:** it exists when you're not talking to it. It has an identity and a memory that grow over time, it can act on its own (routines, events), and it may reach you or other people (channels). Whatever exists only to get a piece of work done is a **helper**, not an agent. | Agents, members and subagents all "agents" |
| CL2 | **Agents are contacts.** They're listed like a chat app's contacts, set up by talking (21 D4), proactive, with channels. They're never assigned to a project and never join a team. | 21 AD3, 5d "Join a team" |
| CL3 | **In a project, Piopio orchestrates.** Every conversation in a project is with Piopio. It does small things itself and, for bigger or parallel work, plans and hands tasks to helpers it creates (on the board, in worktrees), reviews what comes back, and reports. This is 20 PT5 and PT6 with Piopio as the lead, always. | A conversation with Piopio or with the team's lead (20 PT4, 21 "with the lead ⌄") |
| CL4 | **Helpers are Piopio's, not yours.** They're made for a task with a brief, a kind (does tasks · reviews · merges) and a model; they have no memory of their own, and they don't show in the sidebar or the Agents list. You see them in the plan block and on the board, and you can open any of their sessions. | Team-only members, the team page, "Make it one of your agents" |
| CL5 | **Teams stop being something you make.** What a team decided moves to the project as its **way of working** (§4): whether work is reviewed and how many times it may be sent back, the checks, how many tasks run at once, the helpers' models, what they may do without asking, and the budget per job. | Team definitions, saved teams, team templates, New team |
| CL6 | **Know-how is a playbook, which is a skill.** "How a development job runs here" (plan, build in parallel, review, merge), "how a research brief is made": a `SKILL.md` that Piopio reads when it plans. The built-in teams become built-in playbooks; your own are skills (07 §2), in a project or in your library. What a helper is told comes from the playbook, not from a member card. | Templates as folders of role cards (20 §13), TEAM.md |
| CL7 | **Two memories, with clear owners.** What's learned about a project goes to its NOTES.md, and how to do the work goes to a playbook (Piopio may suggest the change, and you accept it). An agent's memory only comes from its own conversations. | The team's NOTES.md; 21 AD7 |
| CL8 | **The one bridge: asking an agent.** In any conversation, `@Rita` or the model calling `ask_agent` asks one of your agents something. She answers from her own conversation, with her instructions, model, memory and tools, and the answer comes back indented (21 D6, as built). She doesn't work in the project's folder and doesn't become part of the work. | Also: agents as team members |
| CL9 | **Piopio offers, you start.** Before it puts parallel work on the board in a project that hasn't done that yet, Piopio asks ("This could go faster in parallel: 3 parts", with Work in parallel / Do it here, one by one), as `offer_team` does today. Once the project has a way of working, Piopio splits work on its own and shows the plan. | `offer_team` → "A team for <project>" sheet → `teams.adopt` |
| CL10 | **Routines keep their two owners** (21 AD5): an agent's (it messages you) or a project's (it opens a conversation there with Piopio). | Same; "with the lead" goes |
| CL11 | **No Dispatch router** (added 2026-11-17). From Home, Piopio is the front door: work in one or more projects becomes one side conversation per project (24), which reports back there. 17's Watchdog, non-blocking `task`, PR events and limits stay (17's note). | 17: a separate router that never does the work; 19 TD2: Dispatch as the default team |
| CL12 | **Agent-to-agent stays a bridge** (added 2026-11-17). `ask_agent` as built; `tell_agent` for notices only, not for handing work to another agent; the WhatsApp front agent answers and asks, and doesn't hand out work; agent boards (06 §12.1) go (06 §7's note). | 06 AA3 and §5.3: fire-and-forget delegation, a front agent that dispatches; 06 §12.1 |

**Dispatch (17)** was the idea of a front door across projects. Under CL3 it's the same orchestrator one level up:
CL11 makes it Piopio at Home, starting side conversations in projects.

## 3. The model

```
Agent      a contact: instructions, model, tools and skills, memory, channels, routines   (06, 21 D3–D4)
Project    a folder: AGENTS.md, NOTES.md, its files; its conversations (always with Piopio);
           its way of working (§4); its board, branch, routines
Playbook   a skill: how a kind of work is planned, split, done and checked             (07 §2)
Helper     made by Piopio for one task: a brief, a kind, a model; lives on the board
```

What each one is told, in order:
- **Piopio in a project:** its own brief, AGENTS.md, NOTES.md, the way of working, and the playbooks it chose (their
  names and descriptions always, their text when it uses them).
- **A helper:** AGENTS.md, the playbook's part for its kind, and the task's brief.

## 4. The way of working

This is the project Settings' "How work is done here", in place of "Who works here" (21 D6, 4a):

- **Parallel work:** Off (Piopio does everything itself in the conversation) · On (it may split work onto the board).
  It's off until you accept the first offer (CL9) or switch it on.
- **Review:** "Every task is reviewed · sent back at most 3 times, then ask me" · No review.
- **Checks:** the test command, prefilled by the fit check (21 D6).
- **Tasks at once:** 3.
- **Models:** for building and for reviewing; each defaults to the project's model.
- **What helpers may do without asking:** the members' mode today.
- **Budget per job:** what a conversation's tasks may cost (21 D1).
- **Playbooks:** the ones this project uses, preselected from the folder (a code project gets Development).

The fit check (git, checks, AGENTS.md) runs when parallel work is first switched on. It works as it does today,
minus the team.

## 5. What you see

**The sidebar:** Search · Home · Projects · Agents · Conversations. Agents lists only your agents. A project row
shows a dot while its tasks run, with no avatar stack.

**A project conversation:**
- It's always with Piopio. The "with the lead ⌄" pill goes, and so does the "Piopio team joined" line.
- The plan block, the merge card and the "sent back / blocked" lines stay as 21 D6 built them. A plan row names the
  helper by its kind and task ("Builder · Signup form"), with no avatar of its own.
- `@` lists your agents (CL8).

**The project's Settings:** the way of working (§4), routines, AGENTS.md and NOTES.md.

**The Board:** as today. Its empty state says "Piopio puts parallel work here" and shows the switch for parallel work,
in place of the team picker (21 D6, 4b).

**Agents:** as 21 D3 and D4 built them (Chat · Setup, the glance strip, made by talking, the trial run), minus
••• › Join a Team.

**Home:** Waiting on you, While you were away and Today stay. A project's work shows under the project's name, not a
team's.

## 6. What goes, what stays

| Goes | Stays (maybe renamed) |
|---|---|
| Teams in the Agents list, New team, the team page (chain, editor, Add member, TEAM.md, Notes, Projects) | The board, worktrees, the team branch (now the project's work branch), review, CI merging, the merge card |
| Saved and project-only teams, "Save for reuse", "Save this team?" | The plan block, cost per job, the budget stop |
| Join a team, "Make it one of your agents", agents as members | `@mentions` and `ask_agent` (CL8) |
| "Who works here" (Piopio alone · A team), the "with the lead ⌄" pill | The fit check, now behind "parallel work" |
| The "A team for <project>" sheet and `teams.adopt` | `offer_team`, renamed as an offer of parallel work (CL9) |
| Team templates as folders of role cards | Their text, as built-in playbooks |
| The team's NOTES.md | Project NOTES.md; playbooks |

## 7. Engine

- **The way of working** lives in the project's work state, next to its board, branch and routines (`teams.json` today,
  split by 20). It holds §4's fields and no members. `team-definitions.json` goes after migration.
- **Piopio's project brief** gets the board's tools when parallel work is on. That's the lead's brief, written for
  Piopio, so every project conversation is the same kind of session and there's nothing to adopt.
- **Helpers** are created per task from a kind (`build`, `review`, `merge`), the way of working's model for that kind,
  and a brief written by Piopio from the playbook. Their sessions are today's member sessions.
- **Playbooks** are skills found through the existing skill discovery (`packages/engine/src/packages.ts`,
  `tools/chat-resources.ts`). Built-in ones ship with the app, and a project enables the ones it uses.
- **`ask_agent`** stays as built. Members' sessions don't get it, and neither do helpers.

### 7.1 One mechanism for child sessions (added 2026-11-17)

Three things start a session from a conversation, and they should be one mechanism with three uses, not three:

| Use | For | Lives | Reports to |
|---|---|---|---|
| **`task`** (05 §4) | A read-only piece of this turn that would flood the context (a wide search, a long trace) | Inside the turn; you can open it | This turn |
| **A helper** (§7) | A piece of this job that changes files in parallel, or an independent review | The board, a worktree | The conversation that made the job |
| **A side conversation** (24) | A different subject | The sidebar, under its parent | Its parent, as a note |

They share:
- **one start that doesn't block** (17 §3: `wait: false` by default, a wait call for when the parent needs the
  result);
- **one report bridge** (24 §7), with batched notes that may wake the parent and the same loop guard;
- **one set of limits**: running at once, cost per job or per session, permissions never wider than the parent's.

**When to start one at all.** Doing the work in the conversation is the default, with parallel tool calls inside the
turn. A child session is for one of three reasons: the context would get too large, the work really runs in parallel
(and, for writes, needs its own worktree), or it needs fresh eyes (review). A role, a domain or "a specialist for X"
isn't a reason; that's a playbook. (Anthropic, *When to fold subagents into your main agent loop*, 2026-10-22, and
20 §14.)

**As built (2026-11-17):** `task` and side conversations share the start that doesn't block, the report bridge
(notes that wake the parent, batched while a sibling works, the loop guard) and the live line (17 §9, 24 §10). Board
helpers still report through the work runner's `[Board]` messages; moving them onto the same bridge is left.

### 7.2 Rules in the tools, not the prompt (added 2026-11-17)

- **A report isn't proof.** Before Piopio says a helper's task is done or offers the merge card, it reads the diff and
  the check's output, not only the report (24 §5 says the same for notes).
- **The way of working is enforced by the board's tools:** a task is sent back at most `reviewLimit` times, then the
  tool returns "ask the user"; merging is refused until review passed when review is on; the budget stop is the
  engine's. Each refusal says what to do next, so the model can act on it.
- **Tools per session:** count them for each kind of session (a chat, a project conversation with parallel work on, a
  helper). Above roughly 30–50 definitions, choice gets worse, so the rest are found through tool search, as MCP
  servers and the browser already are (22 §13). Group tools by what you want done, not one per API.
- **Prompt audit with C1:** Piopio's project brief, the build and chat prompts and the playbooks get a pass for rules
  written for weaker models. Piopio runs on several providers, so what's cut for frontier models may come back as a
  section for a model family, not in everyone's prompt.

## 8. Migration

At first start after this ships, once, with a short report in the app ("What changed in your teams"):

- **A project with a team** keeps its board, branch, tasks and routines. The team becomes the project's way of working:
  - its members' models become the build and review models;
  - `reviewLimit`, `memberMode`, `budgetPerJob` and tasks at once carry over;
  - parallel work is on.
- **TEAM.md and the team's NOTES.md** are added to the project's NOTES.md under "From <team>" (one copy per project
  that used the team). The team's folder stays on disk, untouched.
- **Members that were your agents:** the agent stays an agent, with nothing lost. The helper of that kind uses the
  agent's model. The agent's instructions aren't carried into helpers, and the report says so.
- **Custom role cards** (yours, or drafted by `teams.draft`) become one project playbook, "How <team> works", with one
  section per kind, so their responsibility and "done" text is kept.
- **Saved teams no project uses**, and your templates in ~/Piopio/Teams/Templates, become playbooks in your skills
  library. The folders stay where they are.
- **Conversations with a lead** become conversations with Piopio, with their history kept, and their tasks stay theirs.

## 9. Phases

| Phase | Scope | Done when | Size |
|---|---|---|---|
| **C1 · One orchestrator** | The way of working in the engine; Piopio's project brief with the board's tools when parallel work is on; helpers from kinds; `offer_team` turns parallel work on; migration (§8). | A migrated project runs a three-task job from a plain conversation with Piopio, reviewed and merged, with the same models as before. | M |
| **C2 · Teams leave the app** | Sidebar, project Settings (§4), the Board's empty state, the conversation without the pill, Agents without Join a team; the migration report. | You can't find "team" anywhere in the app except the migration report. | M |
| **C3 · Playbooks** | Built-in playbooks from the templates; a project enables them; Piopio picks one when it plans and says which; "Save how we did this as a playbook" after a merge, as a skill diff you accept. | A research project and a code project plan differently from their playbooks, and you edit a playbook and the next plan follows it. | M |
| **C4 · A real trial** | Like 20 §14, with real models on a throwaway project: small requests, a parallel job, a job with `@` an agent. | The costs and judgement match 20 §14's, or this spec says why not. | S |

**CL11 and CL12** aren't phases of their own. CL11 is 24's SD1–SD2 plus a side conversation in another project, from
Home. CL12 goes with C1: `tell_agent`'s description and the front agent's brief say "notices only", and nothing that
was built for agent boards exists to remove.

**Order:** C1, then C2, so the app never shows teams that the engine no longer has. C3 can follow later. Until then,
the built-in Development playbook is the lead's current brief.

## 10. Open questions

- **Does anyone need a hand-made team?** For example, "my code reviewer, always this model and these rules". Under
  this spec that's a playbook (the rules) plus the review model in the way of working. If that's not enough, the next
  step would be review *rules* in the playbook, not members.
- **Should Piopio split on its own once parallel work is on (CL9), or always offer first?** The guess: on its own, and
  it shows the plan before it starts anything that costs more than a set amount. Whichever way, splitting should stay
  the exception: it pays for parallel writes (worktrees) and independent review, and a small job done in the
  conversation is cheaper and loses nothing in a handoff (20 §14, and Anthropic's *When to fold subagents into your
  main agent loop*, 2026-10-22). C4 should measure it: a small fixed set of requests, each run more than once, checking
  whether Piopio split or did the work itself, which playbook it read, and whether review was skipped.
- **Can a project be an agent's home?** For example, a "Competitor watch" agent that writes into a project's folder
  every week. Under CL2 the agent stays a contact, and the project routine does the writing. Is that enough, or should
  an agent's routine be able to open a project conversation?
- **Names:** "helper", "playbook" and "way of working" are working names.

## 11. C1 as built (2026-11-17)

The engine side, on branch `agents-clarified`; the app still shows teams until C2, so the two merge together.

**The model in the engine** (`packages/engine/src/work/`):
- **A project's work** (`runner.ts`, `<home>/work.json`): one record per project, keyed by its id, made the first time
  parallel work goes on. It holds the way of working (§4: parallel, review and its limit, checks, tasks at once, build
  and review models, what helpers may do, budget per job, playbook), the work branch in a git project
  (`work/<folder>-<id>`), and the board. There are no members and no definitions.
- **Helpers** have two kinds, `build` and `review`. Merging is the board's, as CI was: in a git project an approved
  task is merged into the work branch and the checks run. A helper is told the playbook's part for its kind, the
  task's brief and where to work. A task can name its helper ("Editor") when the playbook has more than one kind of
  builder.
- **Playbooks** (`playbooks.ts`): Development, General, Research and Writing are built in, from the templates' text.
  A project's own is a skill in `.pi/skills/<id>/SKILL.md`, with sections *Planning*, *Doing tasks: <name>* and
  *Reviewing: <name>*. One playbook per project for now; choosing one when planning is C3. A new project gets
  Development when it's code or git, General otherwise.
- **Piopio's brief** (`PIOPIO_BOARD` plus the playbook's plan) is added to a project conversation's system prompt
  each turn while parallel work is on. It says what §7.1 and §7.2 say: do it here by default, split only independent
  parts, and look at the diff before saying a task is done. A finished task's board message says the same, with the
  `git diff` to run.
- **Rules in the tools** (§7.2): the send-back limit, merging only approved work, the budget stop and "parallel work
  is off" are refusals from the board, not lines in the prompt.

**Conversations:**
- Every project conversation is with Piopio. The board's tools (`create_task`, `list_tasks`, `message_task`, and the
  routine tools) are registered in all of them but declared to the model, with the board's brief, only on turns
  when parallel work is on there. Switching it reaches open conversations at their next turn, without reopening
  them (so the app's live views go on), and `create_task` refuses once parallel work is off.
- Piopio with the board keeps `task` subagents (a lead didn't have them). Helpers have neither, nor `ask_agent`.
- `offer_team` is `offer_parallel`, offered while parallel work is off. **Work in parallel** is `work.accept`:
  parallel work goes on (with the fit check's checks) and that conversation is told to plan.
- A helper's session carries `helper: { project, kind, taskId }` in place of `team`. `sessions.create` lost `team`.
- A card you add on the Board has no conversation, so its updates go nowhere but the Board (a team's first lead
  conversation used to hear them).

**Protocol:** `work.list`, `work.get`, `work.configure`, `work.accept`, `work.playbooks`, `work.fitCheck`, `work.job`,
`work.addTask`, `work.updateTask`, `work.landing`, `work.land`, `work.migrationReport`, `work.dismissMigrationReport`,
and the `work.changed` notification. Every `teams.*` call is gone. Routines are `ProjectRoutine`, `by: "piopio" |
"you"`. Home's agenda shows a board's tasks under the project's name.

**Migration** (`migrate.ts`, at the first start, before anything is served):
- Each team becomes its project's work, with parallel work on, its board, branch and tasks, `reviewLimit`,
  `memberMode`, `budgetPerJob` and tasks at once. Its writer's model becomes the build model, its reviewer's the
  review model. A member that was one of your agents brings its model, not its instructions.
- A team whose members match a built-in template uses that playbook. Any other gets one in its project,
  `how-<team>-works`, with its style and every member's text. A second builder is named in the plan, so Piopio can
  give it tasks.
- TEAM.md and the team's NOTES.md are added to the project's NOTES.md under "From <team>".
- Saved teams no project used, and your templates, become playbooks in pi's skills folder.
- Lead conversations become plain ones; members' sessions become helpers'. Routines Piopio had set say
  `by: "piopio"`.
- `teams.json` and `team-definitions.json` are renamed `*.before-26.json`, so it runs once. The team folders aren't
  touched. A report, `<home>/work-migration.md`, is served by `work.migrationReport` until it's dismissed.

**CL12:** `tell_agent` says it's for notices, not for handing work to another agent. The WhatsApp front agent isn't
built yet, so there's nothing to change there.

**Tests:** `work.test.ts` (the board end to end, review limits, review off without git, models, parallel off,
landing, two conversations, catching up, routines), `work-budget.test.ts`, `work-migration.test.ts`, and
`offers.test.ts`.

**Not done in C1:**
- The app (C2).
- Choosing among playbooks, and saving one (C3).
- Routine tools for Piopio in a project without parallel work (it offers a routine instead, as before).
- A real trial (C4).

## 12. C2 as built (2026-11-17)

On the same branch as C1, so the app and the engine change together.

- **The Kit** (`PiopioKit/Protocol.swift`): `WayOfWorking`, `ProjectWork`, `WorkTask`, `WorkLanding` and `ProjectRoutine`
  replace the team types. A session's `helper` replaces `team`, and `listed` hides helpers' sessions. `work.changed`
  reloads `engine.work`.
- **Project settings › How it works:** "How work is done here" (`WayOfWorking.swift`). It has a parallel work
  switch and, once a project has a board, these settings:
  - review, with its send-back limit;
  - the checks;
  - tasks at once;
  - the build and review models, each with a way back to the default;
  - what helpers may do;
  - the budget per job;
  - the playbook.

  The first time parallel work goes on, a fit check sheet offers git, checks and AGENTS.md, then **Switch on**.
  `work.configure` gained `initGit` for the "Start git" fix.
- **The Board** (`WorkViews.swift`): the same kanban and merge card, now one per project. A card shows its helper
  ("Builder"), and "Give to <role>" is gone. Until parallel work is on, the Board says "Piopio puts parallel work
  here" and has the switch. The Board row shows under a project once it has a board, and the context menu always
  has Board.
- **A conversation:** the plan block and merge card show for this conversation's tasks in any project with a board.
  The "with the lead" chip and "· with <team>" in the header are gone. The offer card reads "This could go faster in
  parallel" with **Work in parallel** (`work.accept`) or "Do it here, one by one". "The user chose to work in
  parallel" shows as one quiet line.
- **Gone:**
  - the team page, New team, the "A team for <project>" sheet, Who works here, the team picker on the empty Board
    and on New project;
  - the Agents page's Teams tab;
  - "Join a Team…" on an agent;
  - the team stack on project rows;
  - "What should <team> do?" on the New conversation page;
  - sending to a team from Home;
  - `.team` in navigation.
- **The migration report** is a sheet at start, shown until you choose **Got it** (`work.dismissMigrationReport`).
- **Captures:** `PIOPIO_DEMO_PARALLEL=<folder>` (with `_TEST`, `_TAB=board|settings`, `_GOAL`) replaces
  `PIOPIO_DEMO_TEAM`.
- **Checked:**
  - the app builds with no new warnings;
  - the Swift tests pass, except `draftsRecoverAttachmentsAndRetryIdentityPerConversation`, which fails the same way
    on `main`;
  - captures of the Board, the settings sheet and the report.
- **Not checked:** a click-through of the offer card, the fit check sheet and a real job. That's C4, with real
  models.
