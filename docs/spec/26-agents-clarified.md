# 26 · Agents, clarified: contacts, and Piopio orchestrates the work

Status: draft 2026-11-16, from a conversation with the user; decisions CL1–CL10 confirmed by the user 2026-11-17;
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

**What this doesn't change:** Dispatch (17) is still the idea of a front door across projects. Under CL3 it's the same
orchestrator one level up, and it isn't part of this spec.

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
