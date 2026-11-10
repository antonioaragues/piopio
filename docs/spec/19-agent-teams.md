# 19 — Agent teams

Draft, 2026-11-09; the choices are decided (§8). Nothing here is built unless it says so. It ties together 06-agents (personal
agents), 13-cloud-engine (Durable Objects, Telegram, WhatsApp), 17-dispatch (a coordinator for Build) and 18 phase 3
(turn a conversation into an agent), which today are four separate ideas.

**2026-11-10: [20-projects-agents-teams.md](20-projects-agents-teams.md) reorganizes what's built here.** A team becomes
a definition, work always happens in a project, and each conversation in a project with a team is a conversation with
its lead. It replaces §4.2 and the team page of §11.

## 0. The vision

1. **You make agents by talking.** Any conversation can become an agent, or a team of agents, once it's clear what
   the work is. You don't fill in a form first.
2. **Agents work in teams.** A lead takes a goal, splits it, hands the pieces to specialists, checks what comes back
   and reports to you. Specialists can be saved agents with memory, or helpers made for one task.
3. **Teams build things.** A team can write code, documents, research or designs. The work happens in a real
   workplace (a folder, a branch, a sandbox) that you can open and review, not only in chat.
4. **Agents live where you are.** They run on your Mac or in your own Cloudflare account. You can talk to them in
   the app, on Telegram or on WhatsApp, and they can come to you.
5. **You stay in charge.** Every agent has a budget, every irreversible step asks you, and you can open any piece of
   work and take over.

### Simple first (non-negotiable)

Teams are a layer on top. What you get without asking for any of it stays as simple as Grok Bot
(docs/research/grok-bot.md):

- **S1 An agent is a contact.** Agents are a list like a messaging app's: avatar, name, last line, unread dot. Each
  has one conversation with you. A team is an agent too; its board is one more tab on its page.
- **S2 You set it up by talking.** A new agent interviews you with two or three question cards and drafts itself
  (AD5). The definition and forms are for later edits, never the first step.
- **S3 Proactive by asking.** "Every weekday at 8, …", "When an email from my bank arrives, …", "If nothing happened
  by Friday, remind me". Each one becomes a **routine** the agent creates itself. The trigger is a time, an event (a
  webhook, a new email or calendar event from a connected app, a file in a folder) or a check (the heartbeat). The
  agent page lists the routines; it has no form for them (UI8).
- **S4 Telegram in a minute, without the cloud.** Make a bot with @BotFather and paste its token in the chat. The
  agent answers on Telegram right away, from the Mac, by polling Telegram (no webhook, tunnel or Cloudflare
  account). Moving the agent to the cloud later makes it answer with the Mac off.
- **S5 Nothing extra to learn for one agent.** Boards, roles, workplaces and budgets per task appear only once an
  agent leads a team. One agent with routines and Telegram needs none of them.

### Three examples

- **"Build me a landing page for the app"**, said on WhatsApp while away.
  - The **Web team's lead** (in the cloud) asks one question back ("for piopio, in its repo?").
  - It writes a plan and puts three tasks on its board: copy, design, build.
  - The **writer** and the **designer** work in the cloud. The **builder** waits for the Mac: it works in a Build
    session in a worktree once the Mac is awake.
  - The **reviewer** checks the result against the plan.
  - You get "Ready: preview link, 6 files, PR open. Merge?", and answer "yes" on WhatsApp.
- **"Every Monday, what changed in local AI this week"**: the Research team. Three researchers search in parallel, an
  editor merges their notes, and the lead sends a two-minute brief to Telegram.
- **Personal team:** Coach, Finance and Family helper are agents with their own memory. A **front agent** answers
  your WhatsApp number and routes each message to the one that knows (AQ2's "one number, one front agent").

## 1. What exists today

| Piece | Where | State |
|---|---|---|
| Agent definitions, conversations per person, memory banks, schedules, outbox, approvals, budget, kill switch | `@piopio/runtime` (AgentCore), 06-agents | Built locally (Phase 4) |
| Agent-to-agent: `ask_agent` (waits), `tell_agent`, loop guards, trace view | `runtime/agents/peers.ts`, 06 §7 | Built locally |
| Turn a conversation into an agent (a drafted definition) | `sessions.agentDraft`, 18 §12 | Built |
| Agent Builder that interviews first (AD5) | 06 §2 | Designed; the start page + draft exist |
| Subagents in Build (`task`), also Claude Code / Codex | `extensions/subagents.ts` | Built; **blocks its parent** |
| Debate: author + reviewer until they agree | 16-debate | Built |
| Dispatch: a router for Build sessions, non-blocking subagents, Watchdog | 17-dispatch | Planned |
| Agent in a Durable Object (alarms, eviction, memory) | `packages/cloud`, spike S7 | Spike passed; nothing deployed |
| Telegram, WhatsApp | 13 §5.3, §5.5 | Planned |
| Agent boards (a task board per team of agents) | 06 §12.1 | Later |

**The gap:** these use **two runtimes**.
- **Build sessions** (pi-coding-agent) have a folder, a shell, git and the sandbox, but live on the Mac.
- **Agents** (pi-durable) are durable and portable to the cloud and to channels, but have no folder or shell.

A team that builds things needs both. This spec is mostly about joining them.

## 2. The model

Five things, each with one job:

| Thing | What it is | Example |
|---|---|---|
| **Agent** | Who: a role with instructions, model, tools, skills, memory and a budget. Saved as a folder (06 §2). | Reviewer, Coach, Web lead |
| **Team** | Who works with whom: a lead, its members, how they share work, and a shared budget. | Web team |
| **Task** | A unit of work on a team's board: a brief, an owner, a state, a result. | "Write the hero copy" |
| **Workplace** | Where a task can act: a project folder (Build session, worktree, sandbox), the cloud (files in R2), or nothing (talk only). | piopio, branch `web/landing` |
| **Channel** | How a person reaches an agent: the app, Telegram, WhatsApp, a webhook. | WhatsApp → front agent |

**Rules of the model**
- **T1 One kind of agent.** A specialist, a lead and a personal assistant are all agents. They differ in their role,
  their tools and whether they lead a team. There's no separate "subagent" type.
- **T2 Saved or temporary.** A lead can **hire** a helper for one task from a **role card** (a template: researcher,
  writer, designer, builder, reviewer, tester). The helper has no memory beyond the task, and it's gone when the
  task closes unless you **keep it**, which saves it as an agent (T6).
- **T3 Doing needs a workplace.** An agent that edits files or runs commands does it in a **Build session** in a
  workplace. The agent is the identity; the Build session is its hands.
  - **Local leads** start that session in-process.
  - **Cloud leads** reach the Mac through the Mac Bridge (06 §10). While the Mac is asleep, the task waits as
    "Waiting for the Mac".
- **T4 Leads don't do the work** (17 §1). A lead plans, writes briefs, assigns, reviews and reports. It has the board
  and messaging tools, not the shell. That keeps it cheap and its context clean, and it's what Dispatch already
  says.
- **T5 Dispatch is a team.** Dispatch (17) is the default team in Build: its lead is Dispatch, and its members are
  Build sessions. Teams generalize it to any lead, any members and any workplace.

## 3. Making agents from a conversation

| You say or do | What happens |
|---|---|
| "Turn this into an agent" (··· menu, File menu) | Built: the draft opens on the Agent start page. **Changes:** the draft becomes an interview card in the conversation itself (AD5), and nothing opens until you confirm. |
| "Make a team for this" | The Builder drafts a team in the conversation: a lead, two to four members (saved agents it reuses, or role cards), the board's first tasks, the workplace and a budget. You confirm, change or drop members, and Create. |
| A lead hires a helper mid-task | A card in the lead's conversation: "Hired a Tester for 'run the e2e suite' · $0.40 cap". It's visible on the board as its owner. |
| "Keep this helper" | The helper becomes a saved agent: its instructions, the skills it used, and a summary of what it learned as its first memory. |
| "Add Ana to the Web team" / "Remove the designer" | Edits the team. The Builder shows the change as a diff. |

- **T6 What a helper becomes when kept.** Its role card's instructions, the brief's standing details, and the files
  it used often become skills (`save_skill`, 06 §4). You review them as a diff.
- **T7 Role cards are agents too.** They're saved agents marked as templates. You edit them like any agent, and
  every helper hired from one gets your edits.

## 4. Teams and coordination

### 4.1 How a team works

```
You ─▶ Lead ── plan ──▶ Board (tasks) ──▶ members work in parallel ──▶ reports ──▶ Lead reviews ──▶ You
                                   ▲                                   │
                                   └──────── follow-ups, fixes ◀───────┘
```

- **TC1 The board is the shared state.** It replaces the long `ask_agent` chains. Each task has:
  - a **brief:** goal, context, what done looks like, workplace and budget;
  - an **owner**;
  - a **state:** To do → Doing → Review → Done, or Blocked;
  - a **result:** a short report, files and links.

  Members see their own tasks, and the lead sees all of them. It's 06 §12.1's agent board, promoted from Later.
- **TC2 Non-blocking.** A lead assigns and goes on; reports come back as events (17 §3's non-blocking subagents,
  for every team). `ask_agent` stays for short questions between agents.
- **TC3 Reports, not transcripts.** A member ends a task with a report of three to five lines plus its outputs. The
  lead reads reports and opens the work only when something's off, so its context stays small.
- **TC4 Patterns the lead can use:**
  - **fan-out:** the same brief to N researchers, then merge;
  - **pipeline:** writer → editor;
  - **review loop:** builder ↔ reviewer until it passes, as in Debate (16);
  - **escalate:** to you, with a question card (UI7).

  They're instructions in the lead's role card, not hard-coded flows.
- **TC5 Guards** extend 06 AA4:
  - a team budget, with each task's cap inside it;
  - at most N tasks Doing at once (default 3);
  - hop and loop limits;
  - a Watchdog (17 §4) that flags a task that stops making progress.

  Approvals inside a task are yours, never the lead's.
- **TC6 You can step in anywhere.** You can open a task's Build session or agent conversation and type there, and
  the lead hears about it in the task's next report. You can also write to the lead, reassign a task, or pause the
  team (the kill switch, AS4, per team).

### 4.2 Where teams show up

- **Agents area:** a **Teams** section beside Agents. A team page has:
  - **Lead** (chat with the lead);
  - **Board**;
  - **Members**;
  - **Activity** (the trace, 06 AA5, as a timeline);
  - **Costs**.
- **Build:** Dispatch at the top of the sidebar is the default team's page (17 §1). Tasks with a folder workplace
  show their Build session's card: branch, diff size, status.
- **Conversations:** a task's result arrives in the conversation that asked for it, as a result card with its files
  (UI9) and actions: Merge, PR, Keep, Discard.
- **Inbox:** questions, approvals and "Waiting for the Mac" from every team.

## 5. Where agents run

| | This Mac | Your cloud (Cloudflare) |
|---|---|---|
| Runtime | pi-durable on SQLite (built) | AgentDO on DO SQLite (spike passed) |
| Always on | Only while the Mac is awake | Yes |
| Channels | The app (Telegram through a tunnel) | The app, Telegram, WhatsApp, webhooks |
| Doing work in folders | Yes, through Build sessions | Through the Mac Bridge, when the Mac is awake |
| Apple apps (Calendar, Reminders…) | Yes (4.1) | Through the Mac Bridge |
| Models | Every provider, subscriptions included | API-key providers (13 §5.1) |

- **R1 One switch per agent:** "Runs on: This Mac | Cloud". Deploying moves its definition and memory, as in 13 §5.2.
  A team's members can run in different places. The lead usually goes to the cloud so it's always reachable, and
  builders stay on the Mac.
- **R2 Cross-engine messages.** 06 AA7 limits agent-to-agent calls to one engine. Teams need local ↔ cloud: the Mac
  Bridge carries board events and task messages both ways, and queues them while the Mac is offline.
- **R3 Cloud workplaces, later:** a sandbox in the cloud (Cloudflare's container sandboxes) so builders can work with
  the Mac off. Open question Q4.

## 6. Talking to agents from outside

- **CH-T1 A team answers through its lead.** A channel can point at an agent or at a team. A team's channel reaches
  its lead.
- **CH-T0 Telegram on the Mac** (S4): the engine polls Telegram (`getUpdates`) for each local agent's bot while the Mac
  is awake, so no webhook or public address is needed. On deploy, the cloud registers the webhook and the Mac stops
  polling that bot, so there's never two receivers.
- **CH-T2 One front door per number.** Telegram gets a bot per agent or per team (AQ1); WhatsApp gets one number with
  one front agent (AQ2), which routes to agents and teams with `ask_agent` or by opening a task.
- **CH-T3 Long work in chat apps.** Over a channel, the lead answers within seconds with a plan line ("On it: 3
  tasks, about 20 min"). It sends the result as one message with a link (a preview page, a PR, a file), and sends
  approvals as buttons (13 §5.3, §5.5).

## 7. Phases

Each phase ends with something usable every day.

| Phase | Scope | Acceptance |
|---|---|---|
| **T0 · Simple agents** | The single-agent path (S1–S5): set up by talking (interview cards in the conversation, AD5); "Turn into an agent" as a card in the conversation; routines by asking, with time, webhook, connected-app and folder triggers (S3); **Telegram from the Mac by polling** (S4); leads, specialists and role cards are agents (T1, T7). | Make three agents by talking, without touching a form. One messages you on Telegram every morning; another answers when an email from a given sender arrives. |
| **T1 · Teams on this Mac** | Teams, the board as a kanban (TC1, TD5), non-blocking tasks (TC2), reports (TC3), hire and keep (T2, T6, TD6), guards (TC5), the team folder (TD7), the team page. "Make a team for this". | A Research team runs a weekly brief from a routine; a Writing team turns notes into a post with a review loop. |
| **T2 · Teams that build** | Tasks with a folder workplace run as Build sessions in worktrees (T3). Dispatch becomes the default team (T5, TD2), with 17's Watchdog and PR events. | Build a small feature with a lead, a builder and a reviewer; merge from the result card. |
| **T3 · In the cloud** | 13's milestones 5.1–5.4: deploy agents and teams, Telegram by webhook from the cloud (always on), the Mac Bridge for build tasks and Apple apps, cross-engine messages (R2). | A Telegram agent answers with the Mac off; a cloud lead takes a build task and finishes it when the Mac wakes. |
| **T4 · WhatsApp** | 13 §5.5, with teams reachable through their lead (§6). | The landing-page example (§0), end to end, from WhatsApp. |
| **T5 · Later** | Cloud sandboxes (R3), rooms where several agents and you talk (06 §7 Later), side-by-side agents (UI3). | — |

## 8. Decisions

All decided with the user on 2026-11-09.

| # | Decision |
|---|---|
| TD1 | **Specialists are helpers by default** (T2): hired from a role card for one task, and kept as a saved agent only when you say so. |
| TD2 | **Dispatch is the default team** (T5): one coordination model for Build and Agents. 17-dispatch is built as phase T2 of this spec. |
| TD3 | **Builders wait for the Mac** (R2): a cloud lead's build task waits as "Waiting for the Mac". Cloud sandboxes (R3) are later. |
| TD4 | **Telegram first**, then WhatsApp (§6). Telegram arrives in T0 from the Mac and in T3 from the cloud; WhatsApp in T4. |
| TD5 | **The board is a real kanban** you see and edit (06 §12.1): columns To do, Doing, Review, Done; you can add, reorder and reassign cards. |
| TD6 | **A lead hires helpers on its own**, within the team's budget and from existing role cards. A new kind of role asks you first. |
| TD7 | **A team shares knowledge through a team folder** with NOTES.md, like a project (CF4). A shared memory bank can come later if notes aren't enough. |
| TD8 | **Simple first** (S1–S5): the single agent stays the default path. Telegram works from the Mac by polling, before the cloud exists. |

## 9. T0 as built (2026-11-10)

- **Telegram from the Mac** (S4; `engine/src/channels/`).
  - **Connect:** paste a @BotFather token in the agent's chat. The engine catches it before the model or the
    transcript, checks it with Telegram, and keeps it in the Keychain. It answers with a pairing link,
    `t.me/<bot>?start=<code>`, valid for an hour.
  - **Talk:** the engine polls the bot while it runs. A message from a known chat is a turn in that person's
    conversation, and the answer goes back to Telegram as HTML. Messages the agent sends on its own go there when
    Telegram is the person's preferred channel, and pending approvals are announced there.
  - **Strangers** get a polite line, or the owner is told (`unknownSenders`).
- **Event routines by asking** (S3).
  - **The `watch` tool:** the agent sets them itself, next to `schedule` for times.
    - `email`: from someone and/or about something, in the connected mail, checked every 5 minutes.
    - `folder`: a file appears or changes.
    - `webhook`: it gets a signed local URL.
  - Each fire is a run, never twice for the same file version, message or delivery.
  - **Where they show:** the Runs tab's "Next", and `list_schedules` / `cancel_schedule`, with Undo.
  - **Defaults:** every agent has `schedule` and `send_message` on, and the templates too.
- **Set up by talking** (S2).
  - **An empty agent interviews you:** an agent created with no instructions and no template is marked `interview`.
    Its chat opens with a greeting written by the engine (no model call) that asks what it's for, with examples.
  - **The interview:** its prompt tells it to ask at most three short questions, then call `set_up` (name, line,
    icon, instructions), then set its routines.
  - **`set_up`:** owner's conversation only, with a result card and Undo. It ends the interview.
  - **Start page:** Create works with nothing filled in.

**Not in T0 yet:**
- Question cards for agents: the interview asks in text, which also works on Telegram.
- "Turn into an agent" as a card in the conversation; it still opens the start page.
- Role cards as agents (T7), which come with teams (T1).
- **Not seen with a real model:** a real interview, a real Telegram bot, and Outlook mail.

## 10. To fold in: teams as you described them (2026-11-10)

From the user, to adjust together before T1 starts:
- **A development team:** a tech lead, a QA and a developer. You give them a goal, and they coordinate to build it.
- **The collaboration style is a team setting:** "a lead and the rest follow" (what §4 assumes), or more
  distributed (peers who split the work and review each other), and maybe others.
- **Shared memory is a team setting too:** what the members share, and how. TD7 assumes a team folder with NOTES.md.
- **Choose a team when you create a project:** the project's work then goes to that team.

**How it maps onto this spec:**

| Idea | Where it fits | What's new |
|---|---|---|
| Tech lead, QA, developer | Role cards (T2, T7) as saved members | Roles fixed per team, not hired per task (TD1 says helpers by default) |
| Collaboration style | §4.1, TC4 | A setting with named styles instead of instructions only in the lead's card |
| Shared memory | TD7 | Choices per team: folder notes, a shared bank, or both |
| A team per project | §2 Workplace, T3; Dispatch as default team (TD2) | The project picks its team; Build sessions there go through it |

## 11. Teams as built (2026-11-10)

The first version of T1 and T2, from §10's development team.

- **Templates** (`engine/src/teams/templates.ts`). A role card is a responsibility, what "done" means, what it may do
  (`lead`, `write`, `review`, `integrate`) and optionally its own model.
  - **Development:** tech lead, builder, QA, CI. It works in a project.
  - **Research:** lead, researchers, editor. It works in its own folder.
  - **Writing:** editor in chief, writer, editor. It works in its own folder.
- **The lead** is a Build session in Read only with `create_task`, `list_tasks` and `message_task`, and its team's
  brief in every turn. `[Board]` messages tell it when a task is done, sent back or blocked.
- **The board** (`engine/src/teams/runner.ts`, `teams.json` in the engine's home). Tasks go To do → Doing → Review →
  (Integrating) → Done, or Blocked.
  - **Parallel builders:** at most `maxParallel` run at once (3). In a git project the team has its own branch and
    worktree, and each task branches from it, so builders work in parallel.
  - **Review:** a finished task is committed on its branch and goes to review (QA, the editor), which ends with
    `verdict`. A failed review sends it back with the notes; three rounds and it's blocked.
  - **CI:** merges approved branches into the team's branch, then runs the test command. A conflict or a failing
    check sends the task back with the output. The project's own branch is never touched.
- **Shared knowledge:** the team folder's NOTES.md (`~/Piopio/Teams/<name>`). Every member is told to read it and add
  to it.
- **The app:**
  - **Sidebar:** a **Teams** section under Agents, with + and a dot while tasks run.
  - **The start page:** pick the kind of team, a name, the project and checks (development), and an optional goal.
  - **The team page:**
    - **Lead:** the lead's conversation, where you give and adjust the goal.
    - **Board:** the kanban. Click a card to open its session. From a card's menu you move it back, stop it, mark it
      done or give it to another role. + adds a task of yours.
    - **Members:** the role cards.
  - **Session lists:** team sessions don't show in the projects' lists.
- **A team per project:**
  - **New project** offers a team: no team, or a template. A team that merges (one with a CI role) makes the new folder
    a git repo first, with a "Start" commit (`teams.create` `initGit`), so its tasks get their own branches.
  - **Sidebar:** a project's team shows first under it.
  - **The project's +** opens "What should the team do?" with the team chosen: what you send goes to its lead, and the
    team's page opens on the Lead tab. To work on your own, pick the project in the box. The box also lists teams
    ("Give a team work").
  - **Folder templates** (research, writing) can also work in a project folder. Only a team with a CI role makes
    branches.
- **Landing the work** (`teams.landing`, `teams.land`):
  - **The merge card** sits on top of the Board once the team's branch has work the project's branch doesn't: the
    tasks and files it brings, "Merge into main…" and, with a remote, "Push for a PR".
  - **Merge** asks first, then merges with `--no-ff`: in the project's folder when it's on the base branch, otherwise
    in a temporary worktree, so the folder stays on its branch. A conflict changes nothing and says to have the lead
    bring the base into the team's branch. Afterwards the team's branch moves up to the merge, the tasks are marked
    landed, their branches are deleted, and the lead hears it.
  - **Push** sends the team's branch to the remote. With a GitHub remote, the browser opens the pull request page; you
    create the PR there.
  - **The lead hears when it's ready:** when the last open task is done, its `[Board]` message says the branch is
    ready and that you merge it from the Board. The lead never merges into the base itself.
- **Routines** (`engine/src/teams/routines.ts`; `teams.addRoutine`, `removeRoutine`, `runRoutine`): what starts a
  team's work on its own, so a Research team can write its weekly brief without being asked.
  - **Kinds:** a time (a cron, or once), a file appearing or changing in a folder, an email (from someone and/or about
    something, in the connected mail), or a webhook call. They reuse T0's machinery: the cron helper, the folder and
    mail watchers, and the hooks endpoint, with the team's id in place of an agent's.
  - **Firing:** the lead gets a `[Routine]` message with the routine, its prompt and what happened, and plans it like a
    request from you. The same file version, email or webhook delivery never fires twice. A time missed while the
    engine was off fires once when it's back.
  - **Set by asking:** the lead has `schedule`, `watch`, `list_routines` and `cancel_routine`, and its brief tells it
    to set a routine when you want work to start on its own.
  - **The Routines tab** on the team page lists them: when each fires next, how often it ran, who set it, and a
    webhook's URL with Copy. "Run now" fires one at once; "Add routine…" offers every day, every weekday, every week,
    once, a folder, an email or a webhook.

**Not yet:**
- Bringing the base into the team's branch from the app, when a merge conflicts.
- Editing roles or adding your own templates.
- Collaboration styles other than "a lead and the rest follow".
- A shared memory bank.
- Budgets per team.
- **Not seen with a real model.**

