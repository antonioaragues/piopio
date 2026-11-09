# 19 — Agent teams

Draft, 2026-11-09; the main choices are decided (§8). Nothing here is built unless it says so. It ties together 06-agents (personal
agents), 13-cloud-engine (Durable Objects, Telegram, WhatsApp), 17-dispatch (a coordinator for Build) and 18 phase 3
(turn a conversation into an agent), which today are four separate ideas.

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
- **CH-T2 One front door per number.** Telegram gets a bot per agent or per team (AQ1); WhatsApp gets one number with
  one front agent (AQ2), which routes to agents and teams with `ask_agent` or by opening a task.
- **CH-T3 Long work in chat apps.** Over a channel, the lead answers within seconds with a plan line ("On it: 3
  tasks, about 20 min"). It sends the result as one message with a link (a preview page, a PR, a file), and sends
  approvals as buttons (13 §5.3, §5.5).

## 7. Phases

Each phase ends with something usable every day.

| Phase | Scope | Acceptance |
|---|---|---|
| **T0 · One agent model** | Leads, specialists and role cards are agents (T1, T7). "Turn into an agent" as an interview card in the conversation (AD5). The default role cards. | Make three agents from conversations without touching the form. |
| **T1 · Teams on this Mac** | Teams, the board (TC1), non-blocking tasks (TC2), reports (TC3), hire and keep (T2, T6), guards (TC5), the team page. "Make a team for this". | A Research team runs a weekly brief from a schedule; a Writing team turns notes into a post with a review loop. |
| **T2 · Teams that build** | Tasks with a folder workplace run as Build sessions in worktrees (T3). Dispatch becomes the default team (T5), and 17's Watchdog and PR events come with it. | Build a small feature with a lead, a builder and a reviewer; merge from the result card. |
| **T3 · In the cloud** | 13's milestones 5.1–5.4: deploy agents and teams, the Mac Bridge for build tasks and Apple apps, cross-engine messages (R2). | A cloud lead takes a task with the Mac off and finishes it when the Mac wakes. |
| **T4 · Channels** | Telegram first, then WhatsApp (13 §5.3, §5.5), with teams reachable through their lead (§6). | The landing-page example (§0), end to end, from WhatsApp. |
| **T5 · Later** | Cloud sandboxes (R3), rooms where several agents and you talk (06 §7 Later), side-by-side agents (UI3). | — |

## 8. Decisions and open questions

**Decided (2026-11-09):**

| # | Decision |
|---|---|
| TD1 | **Specialists are helpers by default** (T2): hired from a role card for one task, and kept as a saved agent only when you say so. |
| TD2 | **Dispatch is the default team** (T5): one coordination model for Build and Agents. 17-dispatch is built as phase T2 of this spec. |
| TD3 | **Builders wait for the Mac** (R2): a cloud lead's build task waits as "Waiting for the Mac". Cloud sandboxes (R3) are later. |
| TD4 | **Telegram first**, then WhatsApp (§6, phase T4). |

**Open:**

| # | Question | Leaning |
|---|---|---|
| Q3 | Is the board visible and editable by you (a real kanban), or an internal tool you see only in the trace? | Visible and editable (06 §12.1). |
| Q6 | May a lead hire helpers on its own, or does each hire ask you? | On its own within the team's budget and role cards; a new kind of role asks. |
| Q7 | How does a team share knowledge: a team NOTES.md in its workplace (like projects, CF4), a shared memory bank, or both? | A team folder with NOTES.md first. |
