# Piopio · Agents and teams: a design brief

For a design pass in Claude Design. It says what exists today (2026-11-10), how the pieces relate, and where the design
needs help. Screenshots of the current app come with it. The current visual style is `docs/design/grey` (neutral greys,
one accent, SF, quiet chrome); keep it unless a change earns its place.

## What Piopio is

A native Mac app (SwiftUI) for working with AI models: conversations, projects (folders it works in), and **agents**
that act on their own. One window: a sidebar on the left (Home, Needs you, Projects, Agents, Teams, Conversations),
the content on the right. Everything runs on your Mac by default; models are yours (OpenRouter and others).

## The model: three layers

| | What it is | Where you see it |
|---|---|---|
| **Agent** | Someone who acts for you: instructions, a model, tools, memory, channels (Telegram), routines | Agents section; its page |
| **Team** | Agents working together: a lead and members in roles, shared instructions, team memory | Teams section; its page |
| **Project** | Where work happens: a folder, its conversations, its board, its routines, and **who works here** (Piopio, or a team) | Projects section; its page |

Agents and teams are definitions you reuse. Work always happens in a project.

## Agents

**What one has:** a name, an avatar and colour, instructions, a model, tools (web, files, Apple apps, connected apps
like Mail and Calendar), memory, an approval mode (what it may do without asking), and a budget.

**Making one:**
- **By talking:** a new, empty agent opens with a greeting that asks what it's for (at most three short questions),
  then sets itself up: name, line, icon, instructions. A result card with Undo shows what it set.
- **From a conversation:** "Turn into an agent" drafts one from what you talked about.
- **From a template** on the New agent page.

**Talking to it:**
- **In the app:** its Chat.
- **On Telegram:** paste a @BotFather token in its chat; it answers with a pairing link; then you message it from your
  phone. Approvals it needs are announced there too.

**Proactive:** it acts without being asked through **routines** it sets itself when you ask ("every morning at 8",
"when an email from the bank arrives"):
- **Times:** schedules and reminders.
- **Events:** a new email (from someone / about something), a file in a folder, a webhook URL.

Messages it sends on its own are marked ("Sent on its own", "Automatic run").

**Needs you** (top of the sidebar) gathers what waits on you across agents: approvals, questions, messages.

**The agent page today:**
- **Header:** avatar, name, model, approval mode.
- **Chat:** the conversation; the **info panel** on the right (300 pt) shows what it's doing now, what's next, recent
  runs and its setup at a glance.
- **Activity:** Next (upcoming schedules and routines), Held (messages waiting for quiet hours or a limit), Webhooks,
  and Runs (each with outcome and cost).
- **Setup:** the definition: instructions, model, tools, channels, budget.

## Teams

**What one has:** members, each a role card: a name, what it does (*plans and assigns* · *does tasks, several at once*
· *reviews every task* · *merges and runs the checks*), what it's responsible for, what "done" means, its own model,
and optionally the agent it's based on. Plus `TEAM.md` (what every member is told) and the team's notes (what it
learns across projects).

**Making one** (Teams › +):
- **Describe it in a sentence** ("a marketing team with a lead, a copywriter, a designer and an editor who reviews"),
  get a draft of members, adjust, create.
- **Start from a template:** built in (Development, Research, Writing) or yours.
- **Save as template:** any team, as a folder of readable cards you can edit or share.

**The team page:** Members · Instructions · Memory · Projects. No chat: the team works in projects.

## A project with a team

- **Every conversation in the project is with the team's lead.** The lead answers and does small things itself; bigger
  or parallel work goes on the **board** as tasks, which members do at the same time; a reviewer checks each one; CI
  merges it and runs the checks.
- **Who:** the project's start page says "Who: Development team | Piopio alone", per conversation.
- **In a lead conversation:** its tasks show as chips above the composer (state, title; one opens the member's
  session). Board updates appear as quiet event lines ("Board · T1 'Signup form' is done…"), not as your messages.
- **The project page:** Conversations · Board · Settings.
  - **Board:** a kanban (To do, Doing, Review, Done, Blocked) and, when work is ready, a merge card ("Ready for main ·
    3 tasks · 3 files · Merge into main… · Push for a PR").
  - **Settings:** who works here, the checks, how many tasks at once, routines, AGENTS.md and NOTES.md.
- **Routines** in a project start a new conversation with the lead ("Every Monday at 09:00: write this week's brief").

## Principles to keep

- **Simple first:** making an agent and talking to it should feel as easy as a chat app. Teams, boards and routines are
  there when you need them, never in the way.
- **Plain words:** sentence case, no jargon, verbs on buttons, every empty state says what to do.
- **Native Mac:** a window, a sidebar, keyboard first, light and dark.
- **Local by default:** nothing goes to the cloud unless you choose it. Cloud agents and WhatsApp come later; don't
  design them yet.

## Where design can help most

1. **The agent page:** too many places (Chat, info panel, Activity, Setup). What does someone need to see at a glance,
   and what can hide?
2. **Making an agent by talking:** the greeting, the questions, the moment it "comes alive" (name, avatar, colour).
3. **Agents and teams together:** a team member can be one of your agents. How do the two sections feel like one
   family without confusing them?
4. **The lead conversation:** task chips, event lines, the merge moment. Does the plan read at a glance?
5. **The Board and the merge card** on the project page.
6. **Routines and proactivity:** seeing what will happen and when, and what happened while you were away.
7. **Telegram:** connecting a bot and pairing your phone, step by step.
8. **Needs you:** approvals and questions from many agents in one place.

## Handoff

Like earlier rounds: export the handoff (HTML artboards plus a short README per screen) and drop it in the repo; it
gets implemented from there.
