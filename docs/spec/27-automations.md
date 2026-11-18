# 27 · Automations: when work starts on its own

Status: draft 2026-11-18, from a conversation with the user; nothing here is built. It takes "when" away from agents
and projects and makes it an object of its own. It changes 06 §6 (PR1–PR3, PR6, PR7's `schedule`), 19 S3 (watches),
21 AD5 and 26 CL10 (routines with two owners). 26's model of agents (CL1–CL12) holds; this spec makes it simpler.
The interaction is mocked up on a design canvas: a target-state board and a clickable prototype (agent chat →
creation card → Automations list → detail as a sentence → agent Setup). It moves to `docs/design/automations` with
the handoff.

**The idea:** agents are who, projects are where, automations are when. An automation says when, who runs it, what it
does, where (if anywhere) it works, and where the result goes.

## 1. Why

Today eight things start work on their own. They have two owners and two sets of tools with the same names:

| What | Owner | Made by | Kept in | Where you see it |
|---|---|---|---|---|
| Definition schedules (`schedules`, PR1) | Agent | You, in Setup | The agent's definition | Setup › "When it acts" |
| The heartbeat (`heartbeat`, PR2) | Agent | You, in the definition | The agent's definition | Nowhere of its own |
| Webhook triggers (`triggers`, PR3) | Agent | You, in the definition | The agent's definition | Nowhere of its own |
| Reminders (the agent's `schedule` tool) | Agent | The agent, when asked | The agent's state | Setup › "When it acts", read-only |
| Watches (the agent's `watch` tool: email, folder, webhook) | Agent | The agent, when asked | The agent's state | Setup › "When it acts", read-only |
| Time routines (Piopio's `schedule` tool in a project) | Project | Piopio, or you in Settings | The work runner | Project Settings › Routines |
| Event routines (Piopio's `watch` tool in a project) | Project | Piopio, or you in Settings | The work runner | Project Settings › Routines |
| Background runs (`schedule` with `when: "now"`, PR7) | Agent | The agent | The agent's state | The agent's chat |

Home's agenda (`agenda.ts`) stitches the first seven back together for Today and While you were away.

What this costs:
- **No one place answers "what runs while I'm away".** Nor what each one costs, or what it may do without asking. An
  app that acts in your name needs that view before it can be trusted.
- **The agent page carries a schedule.** The Agents list has a schedule column ("When you message it"), and its
  subtitle says "schedules, channels and memory". That mixes who an agent is with when it acts, and the design felt
  confusing for that reason (the user, 2026-11-18).
- **The same words mean different things.** `schedule` and `watch` set a reminder in an agent and a routine in a
  project, with different results.
- **26 §10's open question has no good answer.** "Can a project be an agent's home?" Only if a routine can name both a
  project and an agent, and today a routine belongs to one or the other.

## 2. Decisions

| ID | Decision | Was |
|---|---|---|
| AU1 | **One test.** If a person started it, it's a conversation, on whatever channel. If nobody did, it's an automation. A Slack or Telegram message to an agent is a conversation with the agent. "Check in every hour and message me only if something matters" is an automation. | Proactivity as a property of the agent (06 §6) |
| AU2 | **An automation is its own object.** It holds a trigger, who runs it (Piopio or one of your agents), the prompt, a project (optional), where the result goes, what it may do while you're away, on or off, and its runs. It replaces definition schedules, the heartbeat, webhook triggers, reminders, watches and project routines. | Eight kinds with two owners (§1) |
| AU3 | **Agents keep who.** An agent has instructions, a model, tools and the data it may use, memory, channels, and limits (quiet hours, send limits, budget). Setup loses "When it acts". The agent's page links to its automations ("2 automations ›"), and the Agents list loses its schedule column. | 21 D3's Setup with routines; the list's schedule column |
| AU4 | **You make one by asking, anywhere.** In an agent's chat, in a conversation with Piopio, or in a project. The answer is a card with **Open in Automations** and **Undo** (AQ6). The Automations section is for seeing, pausing, editing and running now. Its **New automation** is a form for when you'd rather not ask, not the main way in. | Agents' and projects' own tools; a schedule form in Setup |
| AU5 | **Who may make one.** You may make any automation. Piopio may make one for any runner when you ask (for example "every Monday, ask Rita…"). An agent may make one only for itself. An agent never makes one that runs as another agent or as Piopio, so CL12 holds: agents don't hand out work. | An agent's reminders and watches; Piopio's project routines |
| AU6 | **A project needs Piopio as the runner, in v1.** An automation with a project runs as Piopio there, as a project routine does today. An agent's automation has no project. Agents stay contacts (CL2) and don't work in a project's folder (CL8). Piopio's prompt can still ask an agent ("ask @Rita for this week's prices, then update the sheet"). §9 asks whether "Rita in shop" should become Piopio with an `ask_agent` first. | 26 §10, open |
| AU7 | **Where the result goes** depends on who runs it. An agent can post in its chat with you (the default), send on one of its connected channels, or stay quiet unless it needs you. Piopio can open a conversation (in the project, or loose; the default) or stay quiet unless it needs you. Piopio has no channels, because it isn't a contact. Every run is recorded, quiet ones too. | `deliverTo`, `send_message` and `[Routine]` conversations, set separately |
| AU8 | **While you're away, set per automation.** If it needs your approval, it either waits in Home's Waiting on you (the default) or skips that run. It has a budget per run, and it stops and tells you before going over. It never has more permission than its runner: the agent's limits or the project's permissions. The agent's quiet hours and send limits still hold its messages (PR4, PR5). | The agent's policies only; nothing for project routines |
| AU9 | **Where it runs, said plainly.** Every automation shows "This Mac, only while it's awake". A fire missed while the Mac sleeps runs once when it wakes, as today. When the cloud engine exists (13), an automation can move there if its runner can. | Implied |
| AU10 | **One section.** Automations sits in the sidebar under Home and shows one list for everything. Home's Today and While you were away read from it. A project's Settings shows "N automations work here ›". | Agent Setup, project Settings, Home's agenda stitched together |
| AU11 | **The heartbeat is an automation.** For example: "Every 30 minutes between 08:00 and 22:00, ask Coach to check whether anything needs me, and tell me only if it does." An agent template with a heartbeat makes that automation when the agent is created. | `heartbeat` in the definition (PR2) |
| AU12 | **"Automation" everywhere.** The app, the prompts, the tools, the protocol and the code use it. "Routine" goes, and the `[Routine]` prefix becomes `[Automation]`. It's the better word here because it covers events, not only times, and Mac users know it from Shortcuts. | "Routine" (19, 21, 26) |

## 3. The model

```
Agent        who: instructions, model, tools and data, memory, channels, limits      (06, 26 CL1–CL2)
Project      where: a folder, AGENTS.md, NOTES.md, conversations with Piopio, board   (18, 26)
Automation   when: trigger → runs as → prompt → project? → result; away; on; runs     (this spec)
```

An automation reads as one sentence, and the detail page shows it that way:

> **Every Monday at 09:00**, ask **Rita** to **summarise what competitors shipped last week**, **without a project**,
> and **tell me on Slack**.

```
Automation
  id, name                     "Weekly competitor brief" (the model proposes it; you can rename it)
  trigger                      time: cron + tz, or once (at)
                               email: from?, subject?   (the connected mailboxes)
                               folder: path             (a file appears or changes; not subfolders)
                               webhook: its URL         (the hooks endpoint)
  runsAs                       "piopio" | an agent id
  project?                     a project id; only with runsAs "piopio" (AU6)
  prompt
  result                       agent:  "chat" (+ deliverTo, a contact; default the owner) | "channel:<telegram|whatsapp|…>" | "quiet"
                               piopio: "conversation" | "quiet"
  away                         { approval: "wait" | "skip", budgetPerRunUsd }
  on                           boolean
  by                           "you" | "piopio" | an agent id;  createdAt
  next?                        time: the next fire (kept for a missed fire on wake)
  runs                         firedAt, status (running · done · quiet · waiting · skipped · failed), summary,
                               sent, costUsd, conversation
```

## 4. What you see

**The sidebar:** Search · Home · **Automations** · Agents (your agents, like contacts) · Projects · Conversations. The
Automations row shows how many there are.

**Making one in a conversation.** You ask ("every Monday at 9, send me a summary of what competitors shipped, on
Slack"). The model makes it and answers with a card:
- the name ("New automation · Weekly competitor brief");
- When, Runs as, Does, Tells you;
- Runs on ("This Mac, only while it's awake");
- **Open in Automations** and **Undo**.

**The Automations list:**
- A title, a line ("Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make one here"),
  and **New automation**.
- Filter chips by runner (All · Piopio · each agent) and the "Runs on This Mac, only while it's awake" line.
- One row per automation: its name and when; who runs it (with the project, for Piopio); where it tells you; the last
  or next run; an on/off switch. A paused row is dimmed. A new one has a "New" badge until it's opened.

**An automation's page:**
- Its name and on/off switch.
- The sentence. The runner, the project and the result are blue words that open their choices in place.
- Below the sentence, a line: "To change the time or the task, edit the prompt or ask <runner>". In v1, time and
  trigger are changed by asking. A time picker can come later.
- **What it's told:** the prompt, editable.
- **While you're away:**
  - if it needs your approval: Wait in Needs you · Skip this run;
  - the budget per run;
  - what it may use (the runner's tools, with a link to the agent's Setup, or the project's permissions);
  - runs on.
- **Runs:** the latest, each with its outcome and cost. One opens its conversation. A new automation says when its
  first run is.
- **Run now** and **Delete automation**.

**A run's result in an agent's chat** carries "From <automation> · 08:00". Clicking it opens the automation. That's
how a message you didn't ask for explains itself.

**The agent's page:**
- Two tabs, Chat and Setup. Setup has who it is, what it can use, where you reach it, and its limits.
- At the end of Setup: "Rita runs 2 automations. When they run is set in Automations, not here. You can also just ask
  Rita."
- The header links to them: "2 automations ›".
- The Agents list has no schedule column, and its subtitle loses "schedules".

**A project's Settings:** in place of Routines, "2 automations work here ›" opens the list filtered to the project. It
also has **New automation for this project**.

**Home:** Today and While you were away keep their shape. Each line names the automation, and clicking one opens it.

The mockup differs from this spec in two places, and the handoff should follow the spec:
- Its result picker offers Slack and Telegram for Piopio (AU7 says Piopio has no channels).
- It lets Rita work in a project (AU6 says not in v1).

## 5. Engine

- **One store.** `<home>/automations.json` holds the automations. `<home>/automation-runs.json` holds their runs, the
  last 100 per automation. Both are written the way `work.json` is.
- **One scheduler.** One pi-durable task per time automation (`automation:<id>`), sleeping until `next` (PR6). Every
  fire is idempotent, keyed by `id + fireTime`.
- **One set of watchers.** `AgentWatchers` (`watchers.ts`) becomes the automations' watchers: folders and email for
  every automation, whoever runs it. The work runner's routine watching goes.
- **Webhooks.** The hooks endpoint gains `POST /hooks/a/<automationId>/<token>`. The old URLs (`/hooks/<agentId>/
  <triggerId>/<token>` and the project routines') keep working through an alias table written by the migration, so
  nothing that already calls them breaks.
- **Firing:**
  - Runs as an agent: today's agent run, a `run:<id>` conversation with the prompt (06 PR1). `send_message` delivers
    to the result's target, and quiet hours and limits apply.
  - Runs as Piopio: today's project routine run, a new conversation with Piopio in the project, or a loose one. Its
    first message is `[Automation] <name>: <prompt>`, with what happened (the email, the file, the request body).
  - A run that needs approval: with `wait`, the request goes to Home's Waiting on you, named after the automation,
    and the run is `waiting`. With `skip`, the run ends `skipped` and says why.
- **One tool family** wherever a model may make one: `automate`, `list_automations`, `change_automation` and
  `cancel_automation`.
  - In an agent's sessions, `runsAs` is fixed to the agent.
  - In Piopio's sessions, `runsAs` is any runner, and `project` defaults to the conversation's project.
  - These replace the agent's `schedule`, `watch`, `list_schedules` and `cancel_schedule`, and the project's
    `schedule`, `watch`, `list_routines` and `cancel_routine`. That's four fewer tools in each kind of session
    (26 §7.2).
  - PR7's background run (`schedule` with `when: "now"`) isn't an automation: it's a run the agent starts for a
    conversation. It becomes `run_in_background` on the agent, with the same behaviour.
- **Rules in the tools** (26 §7.2). The tools refuse:
  - an agent making an automation for another runner;
  - a channel the agent doesn't have connected;
  - a project with an agent as the runner (AU6);
  - a time that has passed.

  Each refusal says what to do instead. A new automation's budget per run defaults to $0.25 for an agent and $0.50
  for Piopio in a project.
- **Protocol:**
  - `automations.list`, `.get`, `.add`, `.update`, `.remove`, `.run`, `.runs`, and the `automations.changed`
    notification;
  - `automations.migrationReport` and `.dismissMigrationReport`.

  The `routines.*` calls go. `agents.runs` keeps the agent's runs, and its `upcoming` reads from automations.
- **Home's agenda:** `AgendaInput` takes `automations` (with their runs) in place of agents' `upcoming` and projects'
  `routines`. `buildAgenda` keeps its output.

## 6. Migration

Once, at the first start after this ships, before anything is served. The app then shows a short report, "What changed
in your routines", until you choose **Got it** (as 26 §8 did for teams).

- **Definition `schedules[]`** become automations run by that agent, with the same cron and time zone. A `deliverTo`
  becomes the result's contact.
- **The `heartbeat`** becomes an automation with a quiet result. Its `every` and `activeHours` become a cron (`30m`
  between 08:00 and 22:00 becomes `*/30 8-21 * * *`). The budget skip at 80% (PR2) becomes its budget per run.
- **Webhook `triggers[]`** become webhook automations. Their old URLs are aliased.
- **Reminders and watches** (the agent's state) become automations run by that agent, `by` the agent. A one-off
  reminder that already fired isn't carried over.
- **Project routines** become automations run by Piopio with that project, keeping `by`, `next` and the count of
  runs. Their webhook URLs are aliased.
- **Agent definitions** lose `schedules`, `heartbeat` and `triggers`. Each changed definition is kept beside it as
  `definition.before-27.json`.
- **Runs:** each agent's last 100 runs of these kinds, and each routine's last conversation, are copied into
  `automation-runs.json`. The old records stay where they are.
- **A paused agent** keeps its pause (AS4), and its automations are skipped while it lasts, as its runs are today.

## 7. Phases

| Phase | Scope | Done when | Size |
|---|---|---|---|
| **A1 · One model** | Store, scheduler, watchers, hooks with aliases, firing for both runners, the tool family, approval wait or skip, protocol, migration, agenda from automations. | A migrated home has its agent schedules, a heartbeat, a watch and a project routine as automations; each fires once, on time or on its event, through the new path; old webhook URLs still fire. | M |
| **A2 · The app** | The sidebar row; the list; the page with the sentence; the creation card; agent Setup without "When it acts", the header link and the list without its schedule column; project Settings' link; Home's lines; the migration report. | You can't find "routine" anywhere in the app except the migration report, and every automation can be seen, paused, run now and deleted from one place. | M |
| **A3 · A real trial** | With real models: ask an agent for a weekly brief; ask Piopio in a project for a Monday plan; an email automation that needs approval, once with wait and once with skip; a fire missed while the Mac sleeps; an old webhook URL. | Each card is right the first time, the model never makes a runner it may not, and the costs are in the runs. | S |

**Order:** A1 then A2, on one branch, so the app never shows routines the engine no longer has (as 26's C1 and C2
did). A3 follows.

## 8. What this doesn't do

- **No workflow builder.** There are no chains (when A ends, start B), no branches, and no conditions beyond the
  trigger's filters. A condition goes in the prompt ("only if a price changed"). If chains are ever needed, the first
  step is a trigger "when automation X finishes", not a canvas.
- **No Slack yet.** Slack is a channel (06 §5.5, Later), so it belongs to agents, beside Telegram and WhatsApp. The
  result options are the channels the agent has connected.
- **No cloud.** That's 13. AU9 only makes where it runs visible.

## 9. Open questions

- **An agent in a project (AU6).** Should "ask Rita … in shop" be allowed, as Piopio in the project asking Rita first
  (`ask_agent`) and then doing the work? The guess is yes, after A3, if people keep writing it that way. It keeps CL2
  and CL8, but it's a second hop in every run.
- **One-off reminders in the list.** "Remind me Thursday at 9" is an automation by AU1. Should a fired one-off leave
  the list after a day, with its run kept in the agent's chat? The guess is yes, so the list doesn't fill with
  reminders.
- **Two budgets.** An automation's budget per run and its agent's monthly budget both apply, and the lower one stops
  the run. Is the per-run budget worth showing for agents, or only for Piopio in a project?
- **The name.** "Automations" is chosen (AU12). Look at it again after A3, if people keep saying "routine" when they
  ask.
