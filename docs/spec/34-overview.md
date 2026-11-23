# 34 · Overview: what Piopio costs, what you've set up, and what it has done

Proposed and decided 2026-11-22 (§11). OV0–OV1 built 2026-11-23 (§13). From the user's ask for a stats section (costs, a visual map of the system:
agents, cloud and so on, and other numbers worth seeing), and a read of what Piopio records today
([costs.ts](../../packages/engine/src/costs.ts), `usage.summary` and `usage.extras` in
[protocol](../../packages/protocol/src/index.ts), [CostDetails.swift](../../apps/mac/App/Piopio/CostDetails.swift),
the sidebar footer in [MainSidebar.swift](../../apps/mac/App/Piopio/MainSidebar.swift)). Mockup:
[docs/design/overview/Overview.html](../design/overview/Overview.html).

## 1. Why

Piopio now runs in many places at once: conversations and Build sessions on the Mac, agents that start there and move
to Cloudflare or a server of your own (30, 33), automations that run while you're away (27), coding agents on your
own plans (31), several providers in an order (29). Each piece shows its own small number (a conversation's estimate
in the inspector, an agent's "$0.31 this month", an automation's budget per run, "$0.91 today" in the sidebar), but
nothing answers the three questions you ask about the whole:

1. **What is this costing me, and on what?**
2. **What have I set up, and where does each piece run?**
3. **What has Piopio actually done for me?**

One page answers them. It reads what Piopio already stores; it never sends anything anywhere (D3, no telemetry).

## 2. What exists today (2026-11-22)

| What | Where it comes from | Shown |
|---|---|---|
| A conversation's cost and tokens | pi's `Usage` on each assistant message (input, output, cache read, cache write, USD), summed in `ThreadState.usage` | Inspector footer; CostDetails popover |
| Utility requests and web search | `extra_costs` (at, scope, kind, model, usd or null), per conversation or `app` | CostDetails ("Additional requests") |
| What the provider billed | `usage.summary`: the OpenRouter key's today / month / total, cached a minute; includes other apps on that key | Sidebar footer "This Mac · $0.91 today" |
| An agent's month | Agent `status.spendUsd` against `budgetUsd` (AS3) | Agent info panel footer |
| Automations and jobs | `budgetPerRunUsd`, `work.job` (a conversation's helpers against `budgetPerJob`) | Automation page, the way of working |
| Cloud usage | Planned for Settings › Cloud (30 §7): requests, duration, browser hours, machine time | Not built |

The honest-numbers rule already lives in CostDetails and stays the law here: **an estimate and a provider's bill are
different scopes and are never added together**; unknown prices are counted, never shown as $0; a subscription is
not free.

What's missing: no history (only totals), no way to group by agent, project, automation, model or provider, nothing
across the cloud, and no picture of the setup.

## 3. The idea in one paragraph

**Overview** is a page with three tabs, **Spend**, **Setup** and **Activity**, opened from the sidebar footer (the
cost line that's there today) and from ⌘K. Spend is this month's money by day and by what spent it, with each
provider's own bill beside Piopio's estimate and budgets as plain progress lines. Setup is one map of everything you
have: you and your devices on the left, where Piopio runs in the middle (This Mac, the cloud), what it uses on the
right (providers, connectors, tools, memory), with a line wherever something needs you; every node opens its page.
Activity is what got done: conversations, Build's changes and PRs, agents' runs and messages, automations' runs,
approvals, and how much disk it all takes. Every number is a link to the things it counts.

## 4. Where it lives

- **The sidebar footer.** "This Mac · $0.91 today" stays; clicking it opens Overview › Spend (today it opens the
  CostDetails popover, which becomes the conversation-only view in the inspector).
- **⌘K:** "Overview", "Spend", "Setup", "Activity".
- **Not a sidebar row.** It's a page you open a few times a week, not a place you work (OV1).
- **Links in:** an agent's "$0.31 this month" opens Spend filtered to that agent; Settings › Cloud's usage opens
  Spend filtered to the cloud; an automation's budget line opens its runs.

Layout: the Settings page template (43b953e) in the content card, one centered column (max 760, wider than
Settings' 640 for charts), title 20 bold, the tab control under it (neutral segmented, grey 9a), a range selector on
the right as plain text ("This month", hover `sel`, no chevron): Today · 7 days · This month · Last month · 12 months.

## 5. Spend

### 5.1 The headline

One row of four numbers, no boxes (grey §5: no decoration), each a 20pt figure over a 12pt `fg3` label:

| Number | Means |
|---|---|
| **$18.42** · Piopio's estimate this month | Sum of every request Piopio made: conversations, helpers, agents, automations, utility, web search, on This Mac and in the cloud |
| **$24.10** · on track for the month | Straight-line from the days so far (labelled "about"; hidden before day 5) |
| **$21.06** · OpenRouter billed | The provider's own number (`usage.summary`), with "includes other apps on this key" as its tooltip. One per provider that reports billing |
| **38%** · of plan limits used | Subscriptions (Claude Code, Codex, ChatGPT plan through pi), shown as the share of the current window, never as dollars |

The estimate and the bill sit side by side and are **never summed**. When they differ by more than 10% a `fg3` line
says why it might ("The bill includes other apps on this key" / "12 requests had no price").

### 5.2 By day

A bar chart of the range, one bar per day (per month on 12 months), stacked by **where it ran** in two greys (This
Mac `fg2`, Cloud `fg3`). Charts are the one place grey ink allows a second tone; no hues. Hovering a bar shows that
day's total and its top three spenders. Today's bar is outlined, not filled, while the day is open.

### 5.3 By what

A grouped list under the chart, with a selector for the grouping (plain text, as above): **What** (default) · Model ·
Provider · Project · Where.

- **What:** Conversations · Build sessions · Agents (each agent its own row) · Automations (each) · Piopio's own
  work (titles, memory, organizer, search). Rows: glyph, name, a thin 3pt bar (`fg2` on `track`) against the
  biggest row, the amount, the share. Up to eight, then "N more".
- **Model:** each model with its route (29): `Sonnet 5.5 · OpenRouter`, `Opus 5.5 · Claude Code plan`. Plan rows
  show tokens and "on your plan", not $.
- **Provider:** each provider with its estimate and, where it reports one, its bill.
- A row opens the list of things it counts (conversations, runs) sorted by cost, each opening the thing itself.

### 5.4 Budgets

Every budget Piopio has, in one list, as `name · $spent of $limit · resets 1 Dec`: an agent's month (AS3), an
automation's run (27), a project's budget per job (26). A line in amber when one is past 80%, the only colour on
the page. Plus one new budget: **Piopio this month** (OV3), off until you set it; at 80% it notifies once, at 100%
background work (automations, agents' own runs) waits for your yes in Needs you, and your own conversations keep
going with a composer notice. It never stops a conversation you're in.

### 5.5 Cheaper next time

At most three plain suggestions under the list, only when the numbers support them, each with the saving it's based
on and one action: "Morning briefing spent $4.10 on Opus 5.5; Haiku 5.5 would have been about $0.80 · Change model",
"Cache reads saved about $6.20 this month" (information only), "Titles and memory use Sonnet; an on-device model
would make them free (AQ7) · Use on-device". No suggestion without a number behind it.

## 6. Setup

### 6.1 The map

One diagram, three columns, drawn by the app (not a canvas you edit):

| You | Piopio | Uses |
|---|---|---|
| This Mac · your iPhone (30 §6) · channels: Telegram bots, the WhatsApp number (each with the agent it reaches) | **This Mac:** the engine, projects (count, linked folders), agents that run here, automations here. **Cloud:** Cloudflare Worker or Piopio Server (33), its agents and conversations, the Mac Bridge between them | Model providers in your order (29) with the default model and the roles (28) · coding agents (31) · connectors (12) · MCP servers · skills · memory provider (14) · built-in browser and computer use |

- **Nodes** are hairline boxes (`line`, radius 10) with a 16pt glyph, the name and one `fg3` line of what matters:
  `3 agents · 4 automations`, `Cloudflare · Mac Bridge on`, `OpenRouter · first`, `Google Calendar · signed in`.
- **Lines** are 1pt `line` curves: a channel to the agent it reaches, an agent to where it runs, a place to the
  providers it uses. Hover a node and its lines go `fg2`, the rest fade: "what does Rita touch?" in one glance.
- **Needs you:** a node with a problem gets the blue 6pt dot and its line says why (`key rejected`, `Mac Bridge off ·
  2 steps waiting`, `plan limit until 18:00`). That's grey's needs-you dot, used for what it's for.
- **Click** a node: its page or its Settings pane (an agent opens the agent, a provider opens Settings › Providers at
  it, Cloud opens Settings › This Mac & cloud).
- **Off or unused** things are drawn in `fg3` with a dashed border: a connected provider nothing uses, an agent with
  no automations and no channel, a skill never used in 30 days. The map is also a cleanup list.

### 6.2 What runs where

Under the map, the same facts as a table for reading: each agent, automation and cloud conversation with **Runs on**
(This Mac / Cloud), **Model**, **Reaches you in**, **Next run**, **This month**. This is the "what runs where" list
Settings › Cloud planned (30 §7); Settings links here instead of keeping its own copy.

### 6.3 Not in v1

Editing on the map (dragging an agent to the cloud), a history of the setup, the map on the phone.

## 7. Activity

What Piopio did in the range, in plain rows grouped by area. Each row is a number, a label and a comparison with
the range before in `fg3` (`+12 vs last month`); a click opens the list behind it.

| Group | Rows |
|---|---|
| **Conversations** | Conversations started · messages you sent · side conversations (24) · in the cloud |
| **Build** | Sessions · files changed and lines +/− (from checkpoints) · commits · PRs opened and merged · checks run |
| **Agents** | Runs (by agent) · messages in each channel · things remembered (14) · results undone (AQ6) |
| **Automations** | Runs · finished · skipped · failed · waited for you, with the one that failed most |
| **You and Piopio** | Approvals asked, allowed, denied, and "Always allow" rules added · questions answered · time the work ran (sum of turn durations) · most-used tools, skills and MCP servers |
| **Reliability** | Provider errors · times another route answered (29) · retries · compactions |

Above the groups, one quiet chart: **a year of days** (a 7-row grid of squares, `track` to `fg2` by how much
happened), like a contribution graph, because it's the one view that shows rhythm at a glance (OV5). It starts on the
day Piopio did, so it's mostly empty at first.

What Activity never shows: "time saved" or anything else Piopio can't count. No scores, streaks or badges.

### 7.1 Storage

The last group, because worktrees and browser data grow quietly: **Disk** with sessions, worktrees (per project),
browser data, memory, attachments and agents' files, each with its size and one action where one makes sense
(`Clean up merged worktrees`, `Clear browser cache`). Totals from the app support folder; nothing outside it.

## 8. Under the hood

### 8.1 A ledger, written as it happens

Totals can't be grouped by day or agent, and scanning every session file on each open won't scale. One new table in
the engine's SQLite, written at the end of every request (beside where `extra_costs` is written today, which it
absorbs):

```
usage_ledger(
  at, place,            -- ISO time; "mac" | "cloud:<id>"
  kind,                 -- turn | helper | utility | web_search | embedding | automation | agent_run
  conversation, project, agent, automation,   -- nullable refs
  provider, route, model, role,               -- 29's route, 28's role
  input, output, cache_read, cache_write,
  usd,                  -- null when unknown
  plan                  -- true when billed to a subscription
)
```

- **Backfill:** on first open, Piopio reads existing pi sessions (each assistant message carries its `Usage` and
  timestamp) and `extra_costs` into the ledger, once, with a progress line. Rows from before the ledger have no
  role or route.
- **The cloud** writes the same rows in its own store; the Mac pulls them with the sync it already does (30 §8) and
  keeps them with `place = "cloud:<id>"`. While the cloud is unreachable, Spend says "Cloud usage up to 14:02".
- **No prompts, no content, no credentials** in the ledger; it holds refs and numbers, like `extra_costs` today.

### 8.2 Engine methods

| Method | Returns |
|---|---|
| `stats.spend { range, groupBy, filter? }` | Totals, per-day series, grouped rows, unknown count, forecast |
| `stats.billing` | Each provider's reported bill (OpenRouter's `usage.summary` today; others as they offer it) and plan windows |
| `stats.budgets` | Every budget with spent, limit, resets |
| `stats.setup` | Nodes and edges for the map, with each node's state and the reason when it needs you |
| `stats.activity { range }` | The rows of §7, each with the refs behind it |
| `stats.storage` | Sizes by kind, with the cleanup actions available |

Activity counts come from what's already stored (sessions, checkpoints, automation runs, approvals, Inbox, git via
the project); no new tracking beyond the ledger.

### 8.3 Export

"Export CSV" on Spend writes the ledger for the range (one row per request). It's your data; it stays a file.

## 9. Phases

| Phase | What | Shows it works |
|---|---|---|
| **OV0** · the ledger | `usage_ledger`, written per request, backfill from sessions and `extra_costs`, `stats.spend` | A month of past usage appears grouped by day and model, matching the conversations' own totals |
| **OV1** · Spend | The page, the headline, by day, by what, budgets, the footer link, CSV | This month's estimate is within 2% of OpenRouter's bill when nothing else uses the key (09 Phase 1's bar) |
| **OV2** · Setup | `stats.setup`, the map, What runs where, Settings › Cloud links here | A broken provider key shows as a dot on the map with its reason, and the click opens the fix |
| **OV3** · Activity and Storage | The groups, the year of days, Disk with cleanups | Cleaning merged worktrees frees the space it said |
| **OV4** · Budgets and suggestions | Piopio this month (§5.4), Cheaper next time (§5.5), cloud rows pulled into the ledger | Background work waits at 100% and resumes on your yes |
| **Later** | Overview on the phone, editing on the map, other providers' billing APIs, EUR display | |

**Where it fits:** OV0–OV1 need nothing new and can go any time; OV2 is more useful after K1 (agents in the cloud)
and 33's PS0; the cloud half of OV4 needs K1's sync.

## 10. What you see, in short

- Sidebar footer: unchanged text, opens Spend.
- Spend: four numbers, a chart of days, a list by what, budgets, at most three suggestions.
- Setup: a map you hover and click, then the same facts as a table.
- Activity: a year of days, plain groups of numbers with comparisons, Disk at the end.
- No colour except amber for a budget past 80% and the blue dot for something that needs you.

## 11. Decisions (2026-11-22)

The user took every proposal.

| ID | Decision |
|---|---|
| OV1 | The page is **Overview**. It opens from the sidebar footer's cost line and ⌘K; it has no sidebar row |
| OV2 | **One page, three tabs:** Spend, Setup, Activity. The range picker applies to Spend and Activity |
| OV3 | **A budget for Piopio this month**, off until you set it. At 80% it notifies once. At 100% background work (automations, agents' own runs) waits for your yes in Needs you, and your own conversations keep going with a composer notice |
| OV4 | **Tokens only where dollars aren't the unit:** subscription-plan rows and the By model grouping. Everywhere else shows dollars |
| OV5 | **The year of days stays**, as one quiet row at the top of Activity. No streaks, scores or badges |
| OV6 | **USD**, as providers bill. EUR comes later as an opt-in setting, because the rate needs a request |
| OV7 | **Cheaper next time is on**, with at most three suggestions. Each shows the number it's based on and one action |

## 12. Not verified

- Whether every runtime records `Usage` with a timestamp per message: pi does; coding agents through 31 report usage
  differently (Claude Code gives cost per turn, Codex tokens), and plan windows may not be readable at all.
- Whether Anthropic, OpenAI and Google expose a per-key billing number like OpenRouter's (§5.1 shows one per
  provider that does).
- Backfill time on a year of sessions.
- The cloud's ledger: Cloudflare's own usage (requests, duration) needs its analytics API and a token scope 30's K1
  token may not have.

## 13. Built: OV0–OV1 (2026-11-23)

**The ledger** ([ledger.ts](../../packages/engine/src/ledger.ts)) is `usage.db` in the data folder, one row per
request, with §8.1's columns. Rather than a hook in every runtime, it is fed where the search index already is: every
finished answer a session shows carries its `Usage`, so the same events (live, a reopen, a resnapshot) write it, for
chats, Build, subagents, side conversations, agents' conversations and runs, and coding agents.

- **One request, one row.** A row's id is its container (a session, or the agent: one pi-durable session, so entry ids
  are unique across its conversations), the answer's item id and its four token counts. Reading a conversation again
  never counts an answer twice, and an answer on a branch you left, or replaced by a retry, stays: it was paid for.
- **Prices that come late.** Claude Code's cost arrives with the turn's result, after its last answer was shown;
  `chargeLastAnswer` now puts it on that answer (an `item.updated`), and the ledger takes a later, larger price.
- **Unknown is unknown.** An answer that reports $0 for a model with no price is `usd = null`, counted in
  `unknownCalls`, never added as $0. A plan's requests (a coding agent that didn't charge, a provider signed in with a
  subscription) are `plan = true`: tokens, never dollars (OV4).
- **extra_costs** keeps its table (agents' budgets read it), and each new row is also written to the ledger; the rows
  from before are read in once. A scope that's a conversation or an agent counts there; `app` is Piopio's own work.
- **What the backfill reads.** A conversation's view isn't its whole cost: Build's and chats' files keep branches you
  left and what a compaction folded, and an agent's views show a window of its latest entries. So the backfill also
  reads every answer in the file (`fileAnswers`) and every `pi.assistant` entry in an agent's harness
  (`AgentRuntime.answers`). A file's answer has no item id to match what's shown: it's added only when its
  conversation has no row with the same model and token counts.
- **Checked on real data (2026-11-23),** a copy of the user's data folder: 909 requests since 8 Nov, $11.82. Turns
  match the session files' own sums ($11.6286 vs $11.6263; the difference is a chat's earlier part, which the ledger
  reads), extra costs match `extra_costs` exactly (108 rows, $0.1804), and the agent matches its own month
  ($0.03209). Before the two reads above, the ledger missed $0.78 of left branches and $0.005 of the agent.
- **Backfill** runs on Spend's first open: every conversation whose `updatedAt` changed since it was last read (an
  agent's also when its month's spend changed, since runs don't touch the catalog). Spend waits for it 1.5 s, then
  answers with what's there and `backfilling: true`; the page says "Reading past conversations…" and asks again.
- **Not yet:** `route` and `role` stay empty for turns (29's route and 28's role aren't on the timeline item), cloud
  agents aren't read (their views are, live, with `place = "cloud"`; OV4 pulls their rows), and `stats.billing` is
  still `usage.summary` (OpenRouter only).

**Methods:** `stats.spend` (range, grouping, filter by agent, automation or place; totals, days with Mac and Cloud and
the top three, groups, forecast from day 5, `planTokens`), `stats.items` (what a row counts, costliest first),
`stats.budgets` (each agent's month and each enabled automation's latest run against its budget per run; a project's
budget per job isn't listed yet), `stats.export` (CSV, refs and numbers only).

**The page** ([OverviewView.swift](../../apps/mac/App/Piopio/OverviewView.swift)): Spend only until OV2 adds tabs.
The sidebar footer's cost line opens it (CostDetails stays the conversation's view in the inspector); ⌘K has
Overview and Spend; `overview:<agent>` opens it filtered to an agent (the agent page doesn't link there yet). The
plan-limit figure isn't shown: no plan window is readable yet (§12).

**For L4 and OV4:** `stats.spend` is the data a `piopio` source reads (35 AL12), and `UsageLedger.monthUsd` is what
OV3's Piopio-wide budget will check.
