# 36 · Listeners and steps: automations that wake on what matters and run in parts

Status: draft 2026-11-22, from a conversation with the user. The decisions in §11 are proposed, none confirmed yet;
nothing is built. This spec extends [27](27-automations.md) (automations) and shares one piece with
[35](35-apps-and-library.md) (an app's `script` source). The model in 27 §3 stays: who runs it, the project, where
the result goes, what it may do while you're away. Two things are added: a **filter** on the trigger, and **steps**
in the run.

**The idea:** an automation's trigger can carry a small filter written in code, so the runner wakes only for the
events that matter and the rest cost nothing. A run can be a short list of steps, where code steps do the fixed work
and agent steps do the thinking, recorded so the run resumes where it stopped. Piopio or the agent writes the code
when you ask, and you can read it.

## 1. Why

What 27 does today:

| You want | You get today | What it costs |
|---|---|---|
| "Emails from acmecorp.com, this week, urgent only" | An email trigger takes `from` and `subject` (`automations/model.ts`). Either every Acme email wakes the agent, or a time trigger checks every hour. | A model turn per email, most of them ending "not urgent"; or late, plus a turn an hour |
| "Every Monday, if gas prices moved, tell me" | One turn that fetches, compares, decides and writes | A full turn even when nothing moved |
| "…and keep a row per week in prices.csv" | Asking the model in the prompt | Sometimes skipped, the format drifts |
| "…and ask me before switching contract" | The run waits for one approval, in the same turn | Can't wait days. A sleeping Mac restarts the turn |

The memo the user brought (spec 35 §1) puts both on its list: **listeners** ("streams of events… translated,
deterministically or agentically, into signals… buildable on the fly") and **workflows** (long-running, mixing
agent steps and fixed steps, written in code rather than drag and drop). Piopio has every part needed: event
sources (`watchers.ts`: folder watches and the mail poller; the hooks endpoint), a sandbox for code (codemode), a
durable runtime (pi-durable), and automations as the one place for "when".

## 2. The shared piece: a script

Filters (§3), steps (§4) and 35's app sources are the same thing: **a script**.

- **What it is:** one JavaScript module that exports a function. It runs in pi's codemode sandbox (`@earendil-works/
  pi-codemode`, QuickJS in a worker, a 256 MB heap), started by the engine outside any session.
- **What it can reach:** only the tools its header lists. It has no `fetch`, no file system, no network and no
  timers beyond its own run. A filter's tools must be **read** tools (12's `access: "read"`, MCP's `readOnlyHint`).
  A step's write tools are limited by §4.4.
- **Its header** sits next to the code, so "Show code" and the approval show the same thing:
  ```js
  // @tools gmail_search
  // @model quick            (optional: allows models.classify on the Quick role, 28)
  export default async function (event, ctx) { … }
  ```
- **`ctx`:**
  - `ctx.tools.<name>(args)`: the listed tools.
  - `ctx.state`: a small JSON object kept between calls, at most 64 KB.
  - `ctx.now`
  - `ctx.models.classify(text, labels)`: only with `@model`, counted (§3.6).
- **Limits:** 5 s for a filter, 60 s for a code step, 20 tool calls per call. Going over is an error (§3.5).
- **Where it lives:** with its automation, at `<home>/automations/<id>/filter.js` and `steps/<name>.js`. Every change
  keeps the previous version, and the automation's page offers Undo. An app's scripts stay beside the app (35 §3.1).
- **Who writes it:** the runner, when you ask, following 27 AU5. You can write or edit it yourself in the
  automation's page (Edit code), but you never have to.
- **One runner in the engine:** `scripts.ts` serves filters, steps and app sources alike, with one place for limits,
  logs and errors.

## 3. Listeners: a filter on the trigger

### 3.1 The experience

You ask Rita: "For the next week, tell me about urgent emails from acmecorp.com". Her answer is the usual creation
card (27 §4), with two new lines:

> **New automation · Acme, urgent, this week**
> When: an email from acmecorp.com, **filtered** (Show code) · until Sat 29 Nov
> Would have fired **3 times** in the last 30 days: "Deadline moved to Friday" (12 Nov), "URGENT: invoice 2231"
> (5 Nov), "Need this today" (28 Oct)
> Runs as: Rita · Tells you: in her chat · Each event costs: $0 to check, about $0.01 when it fires
> **Open in Automations** · **Undo**

The "would have fired" line is what a form can't give you. Before the automation goes on, you see whether the rule
catches what you meant. If it catches too much or too little, you say so and Rita changes the code.

### 3.2 What a filter gets and returns

| Trigger | `event` |
|---|---|
| email | `{ id, from, to, subject, preview, received, account }` (`MailMessage`; the body through a listed read tool if needed) |
| folder | `{ path, name, size, kind, changed }`; the text of a small text file in `event.text` |
| webhook | `{ body, headers, receivedAt }` |
| time | `{ at }`: a filter on a time trigger is a **check** (§3.4) |

It returns one of:
- `null` or `false`: not this one. Nothing runs, and $0 is spent.
- `{ fire: true, pass?: {...}, note?: "…" }`: run. `pass` goes to the runner as the run's input instead of the
  whole event, and `note` names the run ("Acme: Deadline moved to Friday").
- `{ hold: true }`: keep the event for a batch (§3.3).
- `{ stop: true, note? }`: turn the automation off ("the week is over").

A filter may also update `ctx.state`. Common uses: "only the first email from this sender today", "only if the price
moved since last time", counting.

### 3.3 Batches and limits on time

- **`until`** (a date): after it, the automation turns itself off, and the card says so. This is separate from the
  filter, so "for the next week" works without code.
- **`batch`** (`{ at: "18:00" }` or `{ every: "2h" }`): held events wait and fire once together, with `pass` as a
  list. "Batches of emails across all my accounts" from the memo is a filter returning `hold`, plus `batch`.
- **Dedupe:** every event has a key (message id, file and version, delivery id), as `watchers.ts` already keeps, so
  the same event never reaches the filter twice.

### 3.4 Checks: a time trigger with a filter

A time trigger with a filter is a listener for anything Piopio can read. Every 15 minutes the filter calls a read
tool and decides whether anything changed:
- "Tell me when the train ticket drops under 40 €"
- "When a new release of pi is published" (a GitHub read)
- "When this page says 'in stock'" (a `web_fetch`, which is a read)

The tick is free, and only a change wakes the runner. That's how listeners get built on the fly without Piopio
shipping an integration for each source. The shortest interval is 5 minutes.

### 3.5 Trying it, and when it breaks

- **The backtest (§3.1).**
  - **Email:** the filter runs over the last 30 days from the connected mailboxes, read only.
  - **Folder:** over the files there now.
  - **Webhook:** over the last 50 deliveries. The hooks endpoint starts keeping these with this spec: 7 days, on
    this Mac.
  - **Check:** the filter runs once now.

  The card shows the count and up to three examples. It runs when the automation is made and on every change to the
  filter, and it never fires anything.
- **Errors:** a filter that throws, times out or returns something invalid is logged on the automation's page with
  the event that caused it. After three in a row the automation pauses, and a line in Home's Waiting on you says
  why, with **Fix it** (opens the runner's chat with the error) and **Turn on again**.

### 3.6 Costs

Checking an event costs $0. A filter with `@model` may call `ctx.models.classify` on the Quick role (28) for rules
code can't judge, such as "is this urgent?". Those calls are counted under the automation in 34's ledger. They have a
daily cap, $0.20 by default, shown on the card. At the cap the filter's `classify` returns `null`, and the card says
so. The run itself is budgeted per run, as today (AU8).

## 4. Steps: a run in parts

### 4.1 The experience

You ask Piopio in the household project: "Every Monday, check gas prices. If anything moved more than 2%, tell me
what changed and whether I should switch, ask me before switching, and keep a row per week in prices.csv". The card
shows the steps:

> **New automation · Gas prices, weekly** · Every Monday at 09:00 · Piopio in household
> 1. **Code** · read this week's prices, compare with prices.csv (Show code)
> 2. **Code** · if nothing moved more than 2%, stop here, quietly
> 3. **Agent** · explain what changed and whether to switch (Quick)
> 4. **Ask you** · "Switch to *the cheapest*?" Waits up to 3 days
> 5. **Agent** · switch the contract, with the usual approvals
> 6. **Code** · add this week's row to prices.csv
> Most Mondays cost $0. About $0.02 when prices move. **Open in Automations** · **Undo**

Today's automations are the one-step case: one agent step with the prompt. Nothing existing changes.

### 4.2 The kinds of step

| Kind | Does | Costs |
|---|---|---|
| **code** | A script (§2). Gets the trigger's input and earlier steps' results. Returns a result, or `{ end: "quiet" \| "done", summary }` to finish the run there. | $0 |
| **agent** | A turn of the runner with a prompt, as today, given the earlier steps' results. It may take a role (Quick, Lead, Deep; 28) and a `returns` schema, in which case it ends with a `finish_step(json)` tool so later code gets structure. | The turn |
| **ask** | A question or approval in Home's Waiting on you, with options. The run waits up to `within` (default 3 days), then follows `ifNoAnswer` (`end` or a default option). | $0 |
| **wait** | Until a time ("Friday 09:00", "in 2 days") or an event (a filter, as in §3). | $0 |

Steps have names. A step's result is `steps.<name>` for later code, and `{{steps.<name>}}` in later prompts. A step
can be skipped by a condition on earlier results (`if: "steps.compare.moved"`), which keeps branching out of prompts.
There are no loops: repeating something is another run.

### 4.3 Durable

- **Each step's result is recorded** in the run, in the runner's pi-durable session for agents and in the work
  runner for Piopio, before the next step starts.
- **After a crash, a sleeping Mac or a restart**, the run resumes at the first unfinished step. A finished agent
  step is never run again, so a sleeping Mac doesn't pay twice.
- **A code step that fails** is retried once. Then the run stops as `failed` at that step, with the error.
- **Waiting** is a recorded state with an alarm, not a turn left open. A run can wait days.
- **The run's page** lists the steps, each with its status, duration, cost and result (collapsed). It offers **Run
  again from here** on any step, which reuses the earlier steps' recorded results. That's for fixing a step without
  paying for the ones before it.

### 4.4 What code steps may change

- **Read tools:** as filters (§2).
- **Files:** a code step may write files in the runner's place: the project's folder for Piopio, the agent's
  `files/` for an agent. Each write is a checkpoint like an agent's edit (05). The card and the page list them ("This
  automation writes prices.csv").
- **Connector write tools** (send, pay, delete, post) are **never** in code steps. They stay in agent steps, under the
  runner's permissions and 27 AU8's rules while you're away. An approval can't be skipped by putting a write in code.

## 5. Making and changing them

- **By asking, as today (27 AU4).** The tools `automate` and `change_automation` take `filter`, `until`, `batch` and
  `steps`, each code step and filter with its code.
- **Checked before the card.** The engine parses each script, checks its header against the runner's tools (and the
  read-only rule), and runs the backtest (§3.5). For steps, it runs a **dry run**: code steps for real with reads
  only, agent steps described but not run, writes listed but not done. A problem goes back to the model as the
  tool's result, so it fixes it before you see a card.
- **On the automation's page:**
  - The sentence keeps the trigger ("When an email from acmecorp.com, **filtered**, until 29 Nov").
  - **What it's told** becomes **What it does**: one prompt, or the numbered steps, each with Show code or its
    prompt.
  - **Edit code** opens a script in the file viewer's editor. Saving runs the checks again.
  - Changes are kept with Undo.
- **Show code is always there.** Nothing runs that you can't read.

## 6. Safety

- **Same sandbox as codemode** (QuickJS, no network, no file system, a heap limit), with fewer tools: only the listed
  ones, read only for filters and app sources.
- **No new permission:** a script never has more than its runner. An agent's filter can't read a mailbox the agent
  can't. Piopio's steps in a project follow the project's permissions.
- **Event content is data to code.** A filter reads an email as data, and no model sees it unless the filter passes
  it on. A hostile email can't instruct a filter. It can reach a model only through `pass` or `classify`, where it is
  ordinary tool output, as it is today.
- **Visible:** every script is on its automation's page. The backtest and dry run show what it would have done. Each
  run records which steps ran.

## 7. Under the hood

**Engine**
- `scripts.ts`: the runner for filters, steps and app sources (35). It loads code into `CodemodeSandbox` with a tool
  table built from the header, applies the limits, keeps `state`, and logs.
- `automations/model.ts`:
  - `Automation` gains `filter?: { file, tools, model? }`, `until?`, `batch?` and `steps?: Step[]` (with `prompt`
    kept as the one-step case).
  - `Run` gains `steps: { name, status, startedAt, endedAt, costUsd, result }[]` and `waitingUntil?`.
- `automations/service.ts`: events go through the filter before firing. Held events and batches are kept. Steps run
  in order, each recorded. Waits become alarms.
- `watchers.ts` and the hooks endpoint call the service with the event instead of firing directly. Hooks keep the
  last 50 deliveries.

**Protocol**

| Method | Does |
|---|---|
| `automation.test { id \| draft }` | The backtest or dry run (§3.5, §5) |
| `automation.script { id, name }` | A script's code, header and versions |
| `automation.saveScript { id, name, code }` | Your edit, checked |
| `automation.runFrom { runId, step }` | Run again from a step |

## 8. Where it touches other specs

| Spec | Change |
|---|---|
| 27 Automations | Filter, until, batch and steps on the object; the page's What it does; the card's backtest line; failed filters in Waiting on you |
| 35 Apps | Its `script` source runs on `scripts.ts`, with the same header and limits |
| 28 Auto model | Agent steps and `classify` name a role |
| 34 Overview | `classify` calls and steps' costs in the ledger; "Checks: 1,204 events, 9 runs" in Activity |
| 30 Cloud | Filters and code steps can run in the Worker later (QuickJS runs in Workers); v1 is This Mac (27 AU9) |

## 9. Phases

| # | Delivers | Done when |
|---|---|---|
| **W1 · Filters** | `scripts.ts`; filters on email, folder and webhook; `until`; dedupe; the backtest; errors and pausing; Show code | "Acme, urgent, this week" shows "would have fired 3 times", fires only on urgent mail, and turns off on Saturday |
| **W2 · Checks and batches** | A filter on a time trigger (§3.4), `batch`, `classify` with its cap | A price check every 15 min costs $0 for a week and fires once when the price drops |
| **W3 · Steps** | Code and agent steps, results between them, `if`, file writes, recording and resuming, the run's steps | The gas automation costs $0 on quiet Mondays, keeps prices.csv in one format, and resumes after the Mac sleeps mid-run |
| **W4 · Waiting** | Ask and wait steps, `within` and `ifNoAnswer`, Run again from here | "Ask me before switching" waits two days for an answer, then finishes the run |

W1 is the smallest useful part, and it also gives 35's L4 its script runner.

## 10. Not in this spec

- **A visual editor** (boxes and arrows) or drag-and-drop steps. You ask, and the code is readable.
- **Loops and parallel steps.** Repeat with another run; parallel work is a project's (26 CL3).
- **New event sources** such as Kafka, websockets or database change feeds. Checks (§3.4) cover what a person needs.
  A source that pushes is a webhook.
- **npm packages in scripts.** Only the sandbox's globals and the listed tools.
- **Agents handing work to each other through steps.** An agent step runs as the automation's runner, and 26 CL12
  holds.

## 11. Questions

| # | Question | Proposed |
|---|---|---|
| LS1 | One script runner for filters, steps and app sources | Yes, `scripts.ts` on codemode's sandbox |
| LS2 | Read tools only in filters and app sources | Yes |
| LS3 | Connector write tools in code steps | Never; only in agent steps |
| LS4 | The backtest when making or changing a filter | Yes; 30 days of mail, files now, the last 50 webhook deliveries |
| LS5 | Hooks keep deliveries for the backtest | The last 50, 7 days, on this Mac |
| LS6 | `classify` in filters, and its cap | Allowed with `@model`, Quick role, $0.20 a day by default |
| LS7 | Shortest interval for a check | 5 minutes |
| LS8 | Pause a filter after how many errors in a row | 3 |
| LS9 | How long an ask step waits by default | 3 days, then `ifNoAnswer` |
| LS10 | Can you edit scripts by hand? | Yes, in Edit code, with the checks; never required |
| LS11 | Order of work | W1 before 35's L4 (they share the runner), W3 after |
| LS12 | Name for what a filter on a time trigger is | "Check" |

## 12. Not verified

- Starting codemode's sandbox from the engine without a session, and its startup cost per call. A busy mailbox could
  mean hundreds of filter calls an hour, so the sandbox may need to stay warm.
- That models write correct filters from a sentence, and that the backtest catches the misses that matter.
- Recording step results in pi-durable for agents, and in the work runner for Piopio, with the same shape.
- Backtesting mail over 30 days against Gmail's and Outlook's rate limits.
