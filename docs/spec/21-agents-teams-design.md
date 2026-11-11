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
