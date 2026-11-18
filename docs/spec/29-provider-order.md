# 29 · Provider order: use your plan first, then your credits

Status: draft 2026-11-18, from a question by the user; nothing here is built. It revises spec 10's FR4 ("never
silently switch to another paid provider") and its "out of scope: automatic provider fallback": switching becomes
possible, but only along an order you set, only to **the same model**, and never in silence. Everything else in 10
holds. It sits under [28](28-auto-model.md) (Auto model): 28 decides which model does a piece of work, this spec
decides which of your providers serves that model (§11).

**The question (the user, 2026-11-18):** we can connect several providers, but can we order them? With more than one
connected, what happens to the model picker? Can we say "spend from here first, then from there", for example "use my
ChatGPT subscription first, then OpenRouter"?

**The idea in one line:** your connected providers form one ordered list. When the model you picked is offered by more
than one of them, Piopio uses them top to bottom: the first one that can answer does.

## 1. Today

- **Order is hard-coded.** The picker groups models by provider in a fixed order (`ModelPicker.swift`:
  `["openrouter", "faux", "openai", "openai-api"]`, then alphabetical). The default model for new conversations comes
  from the first connected provider in `FEATURED` (`models.ts` `defaultModel`). Neither is yours to change.
- **The same model shows up more than once.** With ChatGPT and OpenRouter connected, GPT-6 Sol appears under ChatGPT
  (`openai/gpt-6-sol`) and under OpenRouter (`openrouter/openai/gpt-6-sol`), and with an OpenAI key a third time under
  OpenAI API. Spec 10 FR2 made that deliberate ("two distinct choices"), so the bill is never a surprise.
- **A session holds one route.** `{ provider, id }`. When ChatGPT's plan limit is reached, the turn fails with
  `credits` ("you've reached your plan's limit. Try again later, or pick a model from another provider",
  `timeline/errors.ts`). You open the picker, find the same model under OpenRouter and pick it; later you have to
  remember to switch back, or you keep paying per token for something your plan covers.
- **While you're away it just fails.** An automation (27) that hits the plan limit at 03:00 fails its run.
- **pi already does the hard part of switching.** Spec 10 verified that switching provider mid-conversation keeps the
  history; pi-ai's `transformMessages` rewrites tool-call ids and thinking blocks for the next provider. pi-ai retries
  429 and 5xx itself and honours `retry-after` up to 60 s; a longer wait fails with "Server requested Ns retry delay",
  which is the usual shape of a plan limit with a reset time.

## 2. Three ideas inside "order"

"Order the providers" mixes three things that deserve different answers:

| | Idea | Example | Verdict |
|---|---|---|---|
| A | **Order as a preference.** Which provider leads the picker, which one new conversations and background work start on. | ChatGPT first, so new chats start on a ChatGPT model. | Yes. Harmless, and it replaces two hard-coded lists. |
| B | **The same model through another route.** When a route can't answer, the next route for *the same model* does. | GPT-6 Sol on the ChatGPT plan; when the plan runs out, GPT-6 Sol on OpenRouter credits. | Yes, this is the core of the spec. Same model, same behaviour, different bill. |
| C | **Another model.** When no route for this model can answer, a different model takes over. | Claude Sonnet on the Claude plan, then GPT-6 Sol on OpenRouter. | Not now (§10 Q2). A different model mid-task changes how the work is done, not only who pays. |

## 3. Pros and cons

**Pros**
- **Money.** A subscription is paid either way; every token it serves is one you don't pay for on credits. Today the
  cheap path is the one that takes effort (picking the plan route, switching back).
- **Work keeps going.** Plan limits (ChatGPT's and Claude's rolling windows), rate limits and outages stop a turn
  today. With a second route the turn continues. This matters most for automations and agents, which run while
  you're away (27 AU8).
- **A simpler picker.** You choose a model, not a model × provider. GPT-6 Sol is one row, not three.
- **Local first, if you want it.** An Ollama or LiteLLM endpoint serving the same model can sit at the top, with a
  cloud route behind it for when the Mac's server is off.
- **It replaces guesses with your choice.** The hard-coded picker order and `FEATURED` become your order.

**Cons and risks, with what this spec does about each**

| Risk | Mitigation |
|---|---|
| **A surprise bill.** The plan runs out at 10:00 and a long Build session quietly burns OpenRouter credits all day. | Moving to a route that bills per token **asks first** by default (PO6). Every switch leaves a line in the conversation and changes the composer chip (PO8). Automations keep their budget per run (27 AU8). |
| **"The same model" is fuzzy.** Ids differ (`gpt-6-sol` vs `openai/gpt-6-sol`, `claude-sonnet-5-5` vs `anthropic/claude-sonnet-5.5`), and so can context window, image input and reasoning levels. | A conservative match (PO3): same maker and the same normalized id, never variants (`:free`, `:online`, `-batch`). A route is skipped when the conversation doesn't fit it (longer than its context, images it can't take). Settings lists each model's routes so a wrong match can be seen and split. |
| **The cache is lost on a switch.** The next provider sees the whole conversation uncached: on a long conversation the first reply after a switch costs several times a normal one. | The ask card shows the estimate for that first reply (PO6). Piopio stays on a route for the rest of a turn and only moves back at the start of a turn (PO5), so there's at most one switch each way. |
| **Partial output.** A route fails after the model already streamed half a reply or called tools. | Switching happens per model request, before anything streams (PO4). Tools already run stay run. A failure mid-stream shows the error card as today, with "Continue via OpenRouter" as its action. |
| **Harder to tell what happened.** "Which account answered this?" | Each reply's footer names its route next to its cost; switches are lines in the transcript; Settings shows a resting provider and when it's back (PO8, §6). |
| **More UI.** Drag handles, a policy, route lists. | One ordered list and one setting. With one provider connected, nothing in this spec is visible. |
| **It reverses a rule the user wrote** (10 FR4). | It keeps the rule's intent: you set the order, money moves only with your yes (or a standing yes you gave), and nothing is silent. |

**Conclusion:** worth building, as A + B. C waits.

## 4. Decisions

| ID | Decision | Was |
|---|---|---|
| PO1 | **One ordered list.** Settings › Models › Connected is your provider order, dragged into place. A newly connected provider goes under the ones that already have a plan or run on this Mac, and above the ones billed per token, so "plan first, then credits" is what you get without dragging. | Fixed order in the picker, `FEATURED` for defaults |
| PO2 | **The order is a preference everywhere.** It sets the picker's section order, which provider a new conversation's default comes from when its mode's default isn't available, and which provider background work falls back to (10 §11's utility fallback). | Hard-coded |
| PO3 | **Routes of one model.** Models from different providers are the same model when they have the same maker and the same id once normalized (vendor prefix dropped, lowercase, `.` and `-` treated alike, date suffix dropped), and neither is a variant. A small table in `providers.ts` covers the known exceptions. Custom endpoints match only when their model id normalizes to the same id. You can split a wrong match in Settings (§6.1). | Each provider's model is a separate choice (10 FR2) |
| PO4 | **Switching is per model request, before output.** A request that fails before streaming anything, for a reason in §5's "moves on" column, is tried on the next route of the same model, as long as the conversation fits that route. Partial output never moves silently. | Error card, you pick another model |
| PO5 | **Resting routes, and coming back.** A route that hit a limit rests: until the reset time when the provider gives one, otherwise for a while (§5). Resting is shared by every conversation and automation. A turn sticks to the route it's on; each new turn starts at the first route that isn't resting, so you're back on the plan as soon as it resets. | n/a |
| PO6 | **Ask before money.** Moving to a route billed per token asks first (a card in the conversation). Moving to a plan, a free model or something on this Mac doesn't ask; it's noted. The setting "When a provider can't answer" has three choices, explained: **Ask before using credits** (default), **Switch and tell me**, **Never switch** (today's behaviour). The ask card's "Always" sets the second choice. | Never switch (10 FR4) |
| PO7 | **You pick a model, the order picks the route.** In the picker a model with several routes is one row, in the section of its first route, with the rest named on the row. Picking it follows the order. "Only via OpenRouter" (right-click, or ⌥ while picking) pins a conversation to one route; a pinned conversation never switches. Sessions made before this spec are pinned, so nothing changes for them. | One row per route |
| PO8 | **Always visible.** The composer chip names the route in use once more than one provider is connected (as today), and shows ↪ after a switch, with why in its tooltip. A switch leaves one quiet line in the transcript. Each reply's footer names the route next to its cost. | Chip names the picked provider |
| PO9 | **While you're away, the automation's rules hold.** An automation or agent run follows the same order. "Ask before using credits" means the run waits in Home's Waiting on you, or skips, as its "If it needs your approval" says (27 AU8). Credits it spends count against its budget per run; plan routes count as $0. | The run fails |
| PO10 | **Not now:** another model as a backup (idea C), several accounts of one provider, cheapest-route or load-balancing, splitting one turn across routes. OpenRouter's own routing between its upstream hosts stays OpenRouter's. | — |

## 5. When Piopio moves on

Classified with `describeModelError`'s kinds (`ErrorKind`), after pi-ai's own retries.

| Kind | Moves to the next route? | Rests the route for |
|---|---|---|
| `credits`: plan limit, quota, out of credits | Yes | The reset time when the error or `retry-after` gives it; otherwise 30 min for a plan, until you add credits (checked hourly) for credits |
| `rate_limit` (still failing after pi's retries, or a `retry-after` over 60 s) | Yes | `retry-after`, else 2 min |
| `provider`: 5xx, overloaded | Yes | 2 min |
| `model`: not available on this route | Yes | Until the model list is refreshed |
| `auth`: key rejected, sign-in expired | Yes, and the provider is marked Needs attention as today | Until you reconnect it |
| `network` | Only to a route on this Mac (the cloud ones share the outage) | Not rested |
| `context`, `other`, aborted | No: same error card as today | — |

When no route is left, the error card is today's, naming each route and why it couldn't answer ("ChatGPT: plan limit
until 14:20 · OpenRouter: out of credits").

## 6. What changes in the app

With one provider connected, none of this shows.

### 6.1 Settings › Models
- **Connected** gets drag handles and a line above it: "Used top to bottom when a model is available from more than
  one."
- Each row says how it bills, in one word, plus its state: "Plan", "Credits · $12.40 left", "On this Mac"; a resting
  one says "Resting until 14:20" (or "Out of credits"), with **Use now** to stop the rest early.
- A new row under Connected: **When a provider can't answer**, with PO6's three choices as an explained menu, each
  with an example ("ChatGPT's plan runs out: Piopio asks before continuing with OpenRouter credits").
- The provider detail page lists, for its models, the other routes ("Also via OpenRouter"), with **Not the same
  model** to split a wrong match (PO3).
- **Default model** per mode is still one model; it now follows the order like any pick. Its row shows the route line
  ("GPT-6 Sol · ChatGPT, then OpenRouter").

### 6.2 The model picker
- Sections follow your order, not the hard-coded one.
- A model with several routes appears once, in its first route's section. The row's tail names the rest: "then
  OpenRouter". The OpenRouter section lists only what isn't offered higher up, so it gets shorter, not longer.
- Search finds one row per model.
- Right-click (or ⌥ while picking) → "Only via ChatGPT" / "Only via OpenRouter" pins. A pinned pick shows a pin in the
  chip. A "Show every route" toggle at the bottom, like "Show variants", lists the routes as separate rows again.
- The row's price follows the first route: "Plan" for ChatGPT, a tier for credits.

### 6.3 The conversation
- **The chip:** "GPT-6 Sol · ChatGPT". After a switch: "GPT-6 Sol · OpenRouter ↪", tooltip "ChatGPT's plan limit is
  reached; back on it after 14:20."
- **The transcript line**, quiet, between steps: "Continued on OpenRouter: ChatGPT's plan limit is reached until 14:20."
  And when it comes back: "Back on ChatGPT."
- **The ask card** (PO6 default), in place of the error card: "ChatGPT's plan limit is reached until 14:20. Continue
  with GPT-6 Sol on OpenRouter credits? About $0.40 for the next reply, as this conversation is long." Buttons:
  **Continue**, **Always switch**, **Wait until 14:20**. "Wait" holds the turn and resumes it when the route is back,
  like a sleeping automation.
- **The reply footer:** "$0.12 · OpenRouter", or "Plan · ChatGPT".

### 6.4 Agents and automations
- An agent's model (Setup) is a model like any other: it follows the order unless pinned. A pin is how you say "this
  agent only uses my local server."
- An automation's runs follow PO9. Its run history shows which route each run used, and a run that waited for your yes
  to use credits says so in Waiting on you: "Morning brief wants to use OpenRouter credits: ChatGPT's plan is out until
  14:20."

### 6.5 Build
Build sessions follow the same rules. Long Build turns are where the cache cost bites most, so the ask card's estimate
matters there; nothing else differs.

## 7. Engine and protocol

**A routing provider, registered with pi.** `ModelHub` registers one more native provider, `route`, whose models are
the merged models (PO3) and whose `stream` tries the real routes in order. pi-durable, pi-coding-agent and `utility()`
see an ordinary provider and need no change. Precedent: `openrouter-live.ts` already wraps a pi provider
(`live.wrap`).
- Its `stream` resolves the route list for the model (your order, minus resting routes, minus routes the conversation
  doesn't fit), starts the first, and forwards events. If the first event is an error that §5 says moves on, it rests
  that route and starts the next, emitting a `route` event first. Once anything has streamed, errors pass through.
- The assistant message keeps the **real** provider and model, so pi-ai prices it with that route's pricing,
  `transformMessages` prepares the history for the next one, and costs land under the right account.
- A **`RouteBook`** (new, `routes.ts`) holds the order, the merge table, the splits and the resting state, in
  `routes.json` (no secrets). Resting state survives an engine restart.

**Session model.** A session's model stays a `ModelRef`; a new optional `routing: "order" | "only"` goes beside it.
Absent means `"only"`, so every existing session, agent and automation keeps exactly its route. New picks from a
merged row are `"order"`. `sessions.configure` maps `"order"` to the `route` provider when the session starts or
changes model.

**Protocol.**
- `providers.list` gains `order` (its place) and `resting` (`{ until?, reason }`); `providers.reorder { ids }` sets the
  order.
- `ModelInfo` gains `routes?: { provider, id, providerName, billing }[]` on merged models; `models.list` returns
  merged rows unless asked for every route.
- `providers.split { a, b }` / `providers.unsplit` for "Not the same model".
- Settings gain `models.switching: "ask" | "switch" | "never"`.
- A `session.route` notification (`{ from, to, reason, until? }`) for the chip and the transcript line, and an
  ask card that is a `confirm` request in what the session waits on you for (the same kind of request tool approvals
  and `ask_user` use), so automations' Waiting on you handles it with no new plumbing.
- `ErrorKind` is unchanged; the "no route left" error carries every route's reason.

## 8. Phases

1. **Order (A).** Drag to order in Settings; the picker's sections, `defaultModel` and the utility fallback read the
   order. No switching yet. Small, useful on its own.
2. **One row per model.** The merge (PO3), merged picker rows with the route tail, pins, "Show every route", the split
   in Settings. Still no switching: a merged pick uses the first route.
3. **Switching (B).** The `route` provider, resting, §5, the ask card, the chip and transcript lines, the reply
   footer, the setting.
4. **Away.** Automations and agents: waiting for a yes in Waiting on you, budget, run history per route.

## 9. Acceptance criteria

- With one provider connected, Settings, the picker and conversations look and behave exactly as today.
- Dragging providers changes the picker's section order and the default model's provider, and survives a restart.
- With ChatGPT and OpenRouter connected, GPT-6 Sol is one row under ChatGPT, saying "then OpenRouter"; search finds it
  once; "Show every route" lists both.
- A conversation on ChatGPT that hits the plan limit (faux provider returning the limit error) shows the ask card;
  Continue answers the same turn through OpenRouter; the chip, transcript line and footer say so.
- The next turn after the reset time starts on ChatGPT again, with "Back on ChatGPT."
- "Never switch" gives today's error card; a pinned conversation never switches whatever the setting.
- A conversation longer than the next route's context, or with images it can't take, skips that route.
- A failure after output streamed never moves on by itself; its card offers "Continue via …".
- An automation run that needs credits while you're away waits in Waiting on you (or skips, per its setting), and its
  credits spend counts against its budget.
- Existing sessions, agents and automations keep their route (absent `routing` = pinned).
- Tests (engine, faux providers as two routes of one model): merge and split; order persistence; each §5 kind moves on
  or doesn't; resting until reset and across restart; coming back at the next turn; ask, switch and never; pinned;
  context and image skipping; mid-stream failure passes through; costs recorded under the real route; automation
  approval and budget.

## 10. Open questions

1. **Default for moving to credits.** Recommended: **Ask before using credits** (PO6), which keeps 10 FR4's spirit and
   costs one click, with "Always switch" for those who want "plan first, then credits" to just happen. The other
   option is switching and telling by default, which matches the question more literally but can spend money on the
   first day without a yes.
2. **Another model as a backup (idea C).** Recommended: later, and as an explicit choice per default (for example
   "Build: Claude Sonnet, backup GPT-6 Sol"), always asked, never chained silently. Worth it only if plan limits keep
   stopping you after B is in.
3. **Where a merged model lives in the picker.** Recommended: in its first route's section (§6.2), which keeps today's
   grouping by provider. The other option is grouping by maker (Anthropic, OpenAI, Google…) with the route on each row,
   which reads better with many providers but changes the picker more.
4. **Waiting vs switching on short limits.** A `retry-after` of 90 s: wait and stay on the plan, or switch? Recommended:
   wait when the reset is under 2 minutes, in an attended conversation only.

## 11. With 28 (Auto model)

The two specs answer different questions and stack:

- **28 picks the model, 29 picks the route.** A role (Lead, Deep, Build, Quick) names one model. When that model has
  several routes, it follows your order like any pick: "Build: GPT-6 Sol" runs on the ChatGPT plan, then on OpenRouter
  credits. A role can be pinned to one route, as a conversation can (PO7).
- **28's AM9 holds.** No switching to another role's model on an error; this spec never changes the model either. 28's
  "fallback within a role" (its Later) is this spec's idea C and waits with it (§10 Q2); if it comes, it should be one
  mechanism for both.
- **28's suggestions read the order.** Prefilling roles from connected providers (AM11) uses the first provider in your
  order that has a suggestion, as `defaultModel` does here (PO2).
- **Costs.** 28 sends grunt work to cheaper models; this spec sends it to the plan first. Both count spend under the
  route that actually answered, so 28's per-role costs and this spec's per-route costs come from the same records.
