# Piopio · Agents and automations: a design brief

For a design pass in Claude Design (2026-11-18). It says what Piopio is, the model we've settled on, every screen
that changes, and where design can help most. The behaviour is specified in `docs/spec/27-automations.md`; this brief
is the part a designer needs.

## What Piopio is

Piopio is a native Mac app (SwiftUI) for working with AI models: conversations, projects (folders it works in) and
agents. It has one window: a sidebar on the left and the content on the right. Everything runs on your Mac by default,
with your own model keys.

The current visual style is `docs/design/grey`: neutral greys, one blue accent, SF, quiet chrome. Keep it unless a
change earns its place.

| Token | Light | Dark |
|---|---|---|
| Window | #FCFCFB | #1E1E1D |
| Sidebar | #F4F4F2 | #191918 |
| Card | #FFFFFF | #252524 |
| Bubble (your messages) | #F0F0ED | #2B2B29 |
| Selected row | #EAEAE6 | #333331 |
| Text, secondary, tertiary | #1F1F1E · #6B6B67 · #9B9B96 | #ECECEA · #A6A6A1 · #77776F |
| Hairline | rgba(0,0,0,.09) | rgba(255,255,255,.10) |
| Accent | #2F6FEB | #5B8DF0 |

## The problem

Piopio's agents are meant to be like Grok Bot: assistants that live with you, remember you, act on their own and can
be reached outside the app (Telegram today; WhatsApp and Slack later). Separately, work has to start on its own, at a
time or when something happens.

The current design mixes the two:
- An agent's Setup has a "When it acts" section, and the Agents list has a schedule column.
- Projects have their own "Routines" in Settings.
- Home stitches both back together.

So you can't tell what an agent *is* from what it *does on a schedule*. Nor is there one place to see what runs while
you're away. This brief separates them.

## The model: who, where, when

| | Object | What it holds | Where you see it |
|---|---|---|---|
| **Who** | **Agent** | Instructions, a model, tools and the data it may use, memory, channels (Piopio, Telegram; Slack and WhatsApp later), limits (what it may do without asking, quiet hours, budget) | The sidebar, like contacts. Its page: Chat and Setup |
| **Where** | **Project** | A folder, its instructions (AGENTS.md) and notes (NOTES.md), its conversations (always with Piopio), its board | The sidebar, with its conversations |
| **When** | **Automation** (new) | A trigger, who runs it (Piopio or one of your agents), the prompt, a project (optional), where the result goes, what it may do while you're away, on or off, its runs | A new sidebar section, **Automations**. Home shows what's next and what ran |

**Piopio** is the app's own assistant: the one you talk to in Home and in every project. It isn't one of your agents
and has no channels.

### Three rules

1. **A person started it: it's a conversation.** It belongs to the agent. A Telegram message to Rita is a
   conversation with Rita, not an automation.
2. **Nobody started it: it's an automation.** That includes "check in every hour and message me only if something
   matters".
3. **You make automations by asking**, in any chat ("every Monday at 9, send me…"). The Automations section is for
   seeing, pausing, editing and running now. Its **New automation** form is secondary.

### An automation reads as one sentence

> **Every Monday at 09:00**, ask **Rita** to **summarise what competitors shipped last week**, **without a project**,
> and **tell me on Telegram**.

| Part | Choices |
|---|---|
| **When** (trigger) | A time (every day, weekdays, a weekday, monthly, once); when an email arrives (from someone, about something); when a file appears in a folder; when a URL is called (webhook) |
| **Who** (runs as) | Piopio, or one of your agents |
| **What** | The prompt, in plain words |
| **Where** (project) | No project, or one project. **Only when Piopio runs it** (agents never work in a project) |
| **Result** | An agent can post in its chat with you (the default), send on one of *its* connected channels, or stay quiet unless it needs you. Piopio can open a conversation (in the project, or loose; the default), or stay quiet unless it needs you. **Piopio has no channels** |

### While you're away (per automation)

- **If it needs your approval:** wait in Home's "Waiting on you" (the default), or skip this run.
- **Budget per run:** for example $0.25. It stops and tells you before going over.
- **It may use:** the runner's tools. For an agent, that's its Setup; for Piopio in a project, the project's
  permissions. An automation never gets more than its runner has.
- **Runs on:** "This Mac, only while it's awake. A missed run happens when it wakes." Always shown, and honest: there
  is no cloud yet.

### Who may make one

- You: any automation.
- Piopio: any, when you ask.
- An agent: only ones that run as itself.

## Screens

A first mockup exists (a clickable prototype on a design canvas). Use it as a starting point, not a spec. Two of its
choices are wrong, see "Corrections" below.

### 1. Sidebar

Search · Home · **Automations** (with a count) · **Agents** (each agent as a row: avatar, name, its channel) ·
Projects · Conversations · you, "This Mac" at the bottom.

### 2. Making an automation in a conversation

You write: "Every Monday at 9, send me a summary of what competitors shipped last week, on Telegram."

The agent answers in a line and shows a **card**:
- "New automation" and its name ("Weekly competitor brief"; the model proposes it, you can rename it);
- When · Runs as · Does · Tells you;
- Runs on: "This Mac, only while it's awake";
- **Open in Automations** and **Undo**.

The same card shows when Piopio makes one, in Home or in a project.

### 3. A run's result in an agent's chat

A message the agent sends on its own carries a small label: "From *Daily price check* · 08:00". Clicking it opens
the automation. That's how a message you didn't ask for explains itself.

### 4. Automations (the list)

- **Header:** the title; a line, "Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make
  one here."; a **New automation** button.
- **Filters:** chips by runner (All · Piopio · each agent), and the "Runs on This Mac, only while it's awake" line.
- **One row per automation:**
  - its name and its when ("Every Monday at 09:00", "When an email with an invoice arrives");
  - who runs it (avatar and name; for Piopio, "Piopio in shop");
  - where it tells you ("Rita's chat", "Telegram", "A conversation in shop", "Only if it needs you");
  - the last or next run ("Today 08:00 · sent a message", "Next: Mon 23 Nov, 09:00", "Tue · waited for your
    approval");
  - an on/off switch. A paused row is dimmed. A new one has a "New" badge until it's opened.
- **Empty state:** says what to ask, with an example or two.

### 5. An automation's page

- **Header:** "‹ Automations", **Run now**.
- **Name** and the on/off switch.
- **The sentence.** The choosable parts (who, where, result) are blue words; each opens its choices in place. When and
  what are changed by editing the prompt or asking the runner, so a time picker isn't needed in v1.
- **What it's told:** the prompt, editable.
- **While you're away:** approval (wait or skip), budget per run, what it may use (with a link to the agent's Setup),
  runs on.
- **Runs** (a side column): the latest, each with when, what happened and its cost. One opens its conversation. A new
  automation says when its first run is.
- **Delete automation.**

### 6. An agent's page

- **Header:** avatar, name, a line (what it's for · its model), tabs **Chat · Setup**, and a link "2 automations ›".
- **Setup** describes who the agent is, in four groups:
  - **Who it is:** instructions, model, memory ("14 things learned · View").
  - **What it can use:** tools and data.
  - **Where you reach it:** Piopio (always), Telegram (Connect…), and later Slack and WhatsApp.
  - **Limits:** what it may do without asking, quiet hours, budget.
- **No schedules in Setup.** At the end: "Rita runs 2 automations. When they run is set in Automations, not here. You
  can also just ask Rita." with **Open Automations ›**.
- **The Agents list** loses its schedule column. Its subtitle loses "schedules".

### 7. A project's Settings

In place of "Routines": "2 automations work here ›" (it opens the list filtered to the project) and **New automation
for this project**.

### 8. Home

Today and While you were away keep their shape. Each line names its automation, and clicking it opens it. A run that
waits for approval shows in Waiting on you, under the automation's name.

## Corrections to the first mockup

- Its result picker offers Slack and Telegram when Piopio runs the automation. **Piopio has no channels**, so its
  choices are "start a conversation" or "only if it needs me".
- It lets Rita (an agent) run an automation in a project. **Only Piopio works in a project**, so with an agent the
  project choice should be absent or disabled with a reason.
- It shows Slack as connected. **Slack doesn't exist yet**, so use Telegram in examples.

## Example data

**Agents:**
- **Rita** watches competitors (Acme, Brightly, Northwind). Telegram.
- **Coach** sends a morning summary. Telegram.

**Projects:** shop (code), Competitor research (documents).

**Automations:**

| Name | When | Runs as | Tells you | State |
|---|---|---|---|---|
| Weekly competitor brief | Every Monday at 09:00 | Rita | Telegram | New |
| Daily price check | Every day at 08:00 | Rita | Rita's chat | Today 08:00 · sent a message |
| Monday plan | Every Monday at 09:30 | Piopio in shop | A conversation in shop | Mon 16 Nov · $0.11 |
| File new invoices | When an email with an invoice arrives | Piopio | Only if it needs you | Tue · waited for your approval |
| Morning summary | Weekdays at 07:30 | Coach | Telegram | Paused |

## Where design can help most

1. **The sentence on an automation's page.** It must read as plain language and be editable without feeling like a
   form. How do choosable words look, open and close, in light and dark?
2. **The creation card** in a chat: the moment an automation is born, with Undo. It should be clear, and nobody should
   be surprised by it.
3. **The list:** scannable at five rows and at forty. What's running now, what failed, what waited for you, what's
   paused.
4. **The agent page without schedules.** Setup as "who this is". How the link to its automations feels like part of the
   agent, not an afterthought.
5. **"Runs on This Mac, only while it's awake"**: honest without being alarming, on the list, the card and the page.
6. **While you're away:** approval and budget as two clear choices, not settings jargon.
7. **Empty states:** no automations yet; an agent with none; a project with none.

## Principles to keep

- **Simple first:** making an agent and talking to it should feel as easy as a chat app. Automations are there when
  you need them.
- **Plain words:** sentence case, no jargon (no "cron", "trigger", "webhook" in the main UI; say "when a URL is
  called"), verbs on buttons, every empty state says what to do.
- **Native Mac:** a window, a sidebar, keyboard first, light and dark.
- **Local by default:** nothing goes to the cloud. Don't design cloud running yet.
- **No workflow builder:** no chains, branches or canvases. A condition goes in the prompt.

## Handoff

As in earlier rounds, export the handoff (HTML artboards plus a short README per screen) and drop it in
`docs/design/automations/`. It gets implemented from there (spec 27, phase A2).
