# 20 · Projects, agents and teams: who works where

Status: decided with the user 2026-11-10; nothing here is built yet. It reorganizes what 19 built (teams, the board,
team per project, merging, routines) around one idea, and replaces 19 §4.2 ("where teams show up") and the team page
of 19 §11. 18 (conversation first) still holds: you always start by writing, and a project is a folder.

**The idea:** a team is a definition, not a place. Work always happens in a project. A team changes **who answers** in
a project's conversations, not **where** you talk.

## 1. Why

What 19 built works, but the user couldn't tell how to start (2026-11-10):

- **Two kinds of things inside a project:** its conversations, and a team row with its own chat (the lead). Which one
  do you write in?
- **Three ways to get a team:** the Team menu in New project, Teams › +, and "Give a team work" in the box.
- **No way to give an existing project a team from the project:** you go to Teams and pick its folder.
- **The project's + switched to the team without saying so;** working on your own meant noticing a small chip.
- **After sending you saw the lead's chat, not the board,** where the work happens.
- **The team page mixes two things:** who the team is (members) and where its work happens (lead, board, routines).
- **One lead per team:** every request, from every conversation, lands in one long lead session.

## 2. Decisions

| ID | Decision |
|---|---|
| PT1 | **Three layers.** Agents (who someone is), Teams (who works together), Projects (where work happens). Agents and teams are reusable definitions; projects hold the work. |
| PT2 | **Every team works in a project.** A team with "its own folder" becomes a project (a Research team writing a weekly brief works in a project "Competitor watch"). Teams stop being a place of work. |
| PT3 | **One team per project, at most.** A project's "who works here" is Piopio (the default), an agent, or a team. |
| PT4 | **Every conversation in a project with a team is a conversation with its lead.** There's no team chat apart from the project's conversations. You don't call the lead; you open a conversation in the project as always. |
| PT5 | **The lead does small things itself and delegates the rest.** It answers questions and makes small changes like any Build conversation; it puts big or parallel work on the board. It may edit (no longer Read only). |
| PT6 | **A lead per conversation.** Each conversation is its own lead session; tasks it creates belong to it and report back to it. The board is the project's: every task from every conversation. |
| PT7 | **Two memories.** Team memory is about the craft (how this team works, across projects); project notes are about the subject (this project). |
| PT8 | **One way to give a project a team:** the project's Settings, also offered in New project. "Give a team work" and Teams › + go away. |

## 3. The model

```
Agent     instructions, model, tools and skills, memory, channels (Telegram), routines   (06, 19 T0)
Team      a lead and members: agents in roles (lead, write, review, integrate);
          shared instructions (TEAM.md), team memory (the team's NOTES.md), way of working
          (review? CI? how many at once?)
Project   a folder: AGENTS.md, NOTES.md, its files; its conversations, its board, its routines;
          who works here: Piopio, an agent, or a team
```

- **A team is reused across projects.** The same Development team works in five projects: the same members, roles and
  team memory; each project has its own board, branch and conversations.
- **A member is an agent in a role.** The role says what kind of work it does and what done means; the agent brings
  its instructions, model and skills. In a project a member runs as a Build session in the workplace (its own worktree
  and branch when the team merges). The agent's own chats, channels and memory stay its own.
- **The built-in teams ship with their agents** (Tech lead, Builder, QA, CI; Research lead, Researcher, Editor; …), so
  a team works out of the box and you change it where it lives (§6).
- **What a member is told, in order:** the project's AGENTS.md (pi reads it), the team's TEAM.md and NOTES.md, its
  role, and the task. What it learns goes to the project's NOTES.md when it's about the project, to the team's when
  it's about the craft.

## 4. Working in a project

**Who answers.** The project's start page and every conversation show **Who: Development team ▾**. The default is the
project's team; you can switch one conversation to Piopio alone (a plain Build conversation). It's visible and per
conversation, not a hidden chip.

**A conversation with the lead** (PT4, PT5, PT6):
- You write as in any conversation. The lead answers, does small things itself (in the project's folder, under the
  conversation's permission chip, like Piopio would), or plans and puts tasks on the board.
- **Tasks show in the conversation that asked for them,** as live cards: T1 Doing → Review → Done, with the member and
  its report. A card opens the member's session.
- **Board updates go back to that conversation,** as compact event rows (not as your messages), and the lead reacts
  to them as today.
- **Member sessions don't show in the sidebar.** You reach them from their cards and from the Board.

**The Board** is a project view, not a chat: every task from every conversation, the columns as today, and the merge
card (19 §11, "Landing the work"). One team branch per project.

**Routines** belong to the project: "Every Monday…" starts a new conversation with the lead in the project, titled
after the routine, like an agent's run. Webhook URLs are the project's.

**Small changes and board work land in different places.** What the lead or Piopio change directly is in the
project's folder, like any conversation. Board work is on the team's branch until you merge it from the Board.

## 5. The sidebar and the pages

```
Projects
  Shop                  ● 3 running            ← the team is working here
    Signup page         conversation with the lead; its tasks inside
    Footer bug          done by the lead itself, or by Piopio alone
Agents
  Daily briefing · Inbox helper · …
Teams
  Development team · Research team · My marketing team · …   ← definitions
```

- **The project row** shows a dot while board tasks run. No team row under it.
- **The project page** (from the project's row): **Conversations · Board · Settings**.
  - **Settings:** who works here (Piopio, an agent, a team), AGENTS.md and NOTES.md, routines, the checks (the test
    command), how many tasks at once.
- **The team page** (from Teams): **Members · Instructions · Memory · Projects**. No chat. You edit members (which
  agent, role, model), TEAM.md, the team's notes, and see where it works.
- **New project** offers "Who works here", the same choice as Settings.

## 6. Customizing teams (after the move)

- **Edit a team:** add or remove members, change a member's agent, role or model, its instructions and "done".
- **Templates:** the built-in teams are templates; "Save as template" makes yours. A template is a readable folder in
  ~/Piopio/Teams/Templates (TEAM.md and a role card per member), so you can edit, share or bring role cards from
  elsewhere.
- **Make a team by describing it:** "a marketing team with a lead, a copywriter, a designer and an editor who
  reviews" drafts the members for you to adjust, as agents set themselves up by talking (19 T0).

## 7. What changes from what 19 built

| Today (19) | After (20) |
|---|---|
| One lead session per team | A lead per conversation in the project (PT6) |
| The lead is Read only | The lead edits like a Build conversation (PT5) |
| `[Board]` messages to the one lead | To the conversation that made the task, shown as event rows |
| Team page: Lead · Board · Routines · Members | Project page: Conversations · Board · Settings; team page: Members · Instructions · Memory · Projects |
| A team row under its project, and in Teams | Only in Teams, as a definition |
| Teams with their own folder | Projects (PT2) |
| Team › + / New project's Team menu / "Give a team work" | Project Settings (and New project) (PT8) |
| Roles copied from a template, fixed | Members are agents in roles, editable (§6) |
| Routines on the team | Routines on the project |

**Engine:**
- `teams.json` splits: team definitions (members, instructions, memory, way of working) and each project's work (its
  team, board, branch, routines).
- A task records the conversation that created it; updates go there.
- A conversation in a project with a team is a Build session with the lead's role and tools; its first message needs
  no special routing.

**Migration:** each existing team becomes a definition plus its project's assignment; a team that worked in its own
folder becomes a project at that folder. Boards, branches and routines move with it.

## 8. Phases

| Phase | Scope | Done when |
|---|---|---|
| **P1 · A lead per conversation** | PT4–PT6 in the engine: project assignment, tasks linked to their conversation, updates to it, the lead may edit; routines on the project; migration. | A project with a team: two conversations each plan their own tasks, both on one board, each hears only its own. |
| **P2 · The project is the place** | Sidebar without team rows; the project page (Conversations · Board · Settings); "Who" on the start page and in conversations; task cards and event rows in the conversation; member sessions hidden; one way to assign a team (PT8). | You start building in a project without opening the team; you see the plan and its tasks in the same conversation. |
| **P3 · Teams as definitions** | The team page (Members · Instructions · Memory · Projects); members are agents; TEAM.md and the team's notes; edit members and models. | You change a team's QA model and add a Designer, and the next task uses them. |
| **P4 · Templates and describing** | Save as template, templates as folders, make a team by describing it (§6). | You make a marketing team by describing it and use it in a new project. |

## 9. Open questions

- **An agent as "who works here"** (one agent, no team): the same pattern with no board. Worth it from P2, or later?
- **Cost guard:** a lead per conversation means more lead sessions; budgets per project or per team (19, "Not yet")
  may be needed sooner.
