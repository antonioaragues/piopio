# 28 · Auto model: Piopio picks the model for each piece of work

Status: draft 2026-11-18, from a conversation with the user; its open questions were answered the same day (§10);
nothing here is built. It adds to 07 §1.3 (defaults per
mode stay), and changes 10 §3 (which put "intelligent model routing" out of scope), 26 §4 (the way of working's build
and review models) and 24 §4 (`side_start`'s `model`). Background work (07 §1.3, "Automatic") stays as it is.

**The idea:** once you turn Auto on, you don't have to pick a model per conversation; you say once which model you want
for each *kind of work*, and Piopio, which already knows what kind of work it is starting, uses the right one. It's off
until you switch it on, and with it off Piopio is exactly as it is today. The strong model talks to you and
orchestrates; a cheap one builds from a clear brief; the strongest one is called in for the hard parts.

## 1. Why

Today each conversation has one model, and everything it starts inherits it:

| Work | Model today | Where it's set |
|---|---|---|
| A conversation | The default per mode, or what you pick in the chip | Settings › Models, the composer chip |
| A `task` subagent | The parent's model (no `model` parameter) | Nowhere |
| A side conversation | The parent's, or `side_start({model})` | The model, by id |
| A board helper | The way of working's `buildModel` / `reviewModel`, else the project's | Project settings |
| An agent | Its `models.default` | Agent Setup |
| Titles, summaries, commit messages | "Automatic": the conversation's provider's small model | Settings › Models › Background work |

What that costs:
- **You pay frontier prices for grunt work.** A conversation on Opus that sends three subagents to read files and
  write boilerplate runs all of them on Opus.
- **Or you get a weak orchestrator.** Pick a cheap model to save money and the planning, the reviewing and the talking
  to you get worse too.
- **The hard part gets no extra help.** When a bug resists or a design decision matters, the only way to bring in a
  stronger model is to switch the whole conversation by hand.
- **The knobs are scattered.** Per-mode defaults, the way of working's two models, `side_start`'s model id, the
  utility slot: five places that each answer part of "which model for what".

## 2. How others do it

Two families. They differ in **who decides** and **what they know**.

**A. An opaque router per request.** A trained classifier looks at each prompt and picks from a pool.
- **Cursor Auto / Cursor Router:** an ML classifier routes each request across a pool; the model can change between
  turns; three dials (Cost, Balance, Intelligence); the chosen model is hidden by default; billed at the routed model's
  price.
- **GitHub Copilot Auto:** picks per prompt from task complexity and live health signals (rate limits, outages),
  respects the org's allowed models, a 10% discount for using it.
- **OpenRouter Auto (`openrouter/auto`):** NotDiamond's router, now being replaced; `allowed_models` narrows the pool.
- **Research:** RouteLLM (a learned router between a strong and a weak model, with a cost threshold) and FrugalGPT (a
  cascade: try cheap, check, escalate). Both rest on predicting difficulty before seeing the answer, and cascades add
  latency that compounds over the many calls of an agent.

**B. Roles the user maps to models, with the harness deciding by structure.** No classifier: the kind of work is known
because the harness is the one starting it.
- **Aider:** architect (plans) / editor (turns the plan into edits) / weak model (commit messages, summaries).
- **Cline:** separate models for Plan and Act; switching mode switches model. The most used pair is a strong planner
  with a cheaper executor.
- **Roo Code / Kilo:** "sticky models", one per mode (Architect, Code, Debug, Orchestrator); a task keeps the model it
  started with.
- **Claude Code:** `opusplan` (Opus while planning, Sonnet while executing); each subagent declares `model` (an alias,
  an id, or `inherit`); the orchestrator can pass a model when it starts one; a default subagent model.
- **OpenCode:** a `model` per agent (Build, Plan, custom ones); subagents without one inherit the agent that called
  them.
- **The advisor pattern (Anthropic's advisor tool, OpenRouter's `advisor` server tool):** a cheaper executor keeps the
  turn and *consults* a stronger model at key moments; you get close to the strong model's quality at mostly the
  executor's price.

**What fits Piopio is B, plus the advisor pattern.** The routers in A are trained on one company's traffic and bill
through one account; Piopio is bring-your-own-keys across many providers (10), promises that billing is explicit and
never silently moves to another paid provider (10 FR4), and has no traffic to train on. Switching model per turn also
throws away the prompt cache, which in long agentic conversations is most of the cost. And the hard part of routing,
knowing what kind of work this is, Piopio already has: since 26 it's the one that plans, makes helpers and starts
subagents.

## 3. Decisions (proposed)

| ID | Decision | Alternative not taken |
|---|---|---|
| AM0 | **You turn Auto on, explicitly.** It's off until you switch it on in Settings › Models › Auto. Until then nothing in this spec happens: no Auto row in the picker, no roles block in prompts, no `think_hard`, no role on cards, and Piopio behaves exactly as today. Turning it on doesn't move any existing conversation, and new conversations keep starting on your default model until you pick Auto in the picker or make it the default for new conversations. Turning it off puts every Auto conversation back on its Lead model, pinned. | On by default once roles are prefilled; offered as a suggestion the first time. |
| AM1 | **Auto is a choice in the model picker** (once AM0 is on), beside the models. A conversation on Auto uses **roles**; a conversation on a named model behaves as today: **pinned means pinned**, and its subagents inherit its model. | Pinning only the Lead, with subagents still on roles. |
| AM2 | **Four roles, plus background work.** *Lead* talks with you and orchestrates. *Deep* takes the hard parts: a design decision, a bug that resisted, a plan. *Build* does a task with a clear brief: writes code, edits files, runs checks. *Quick* reads and finds: explores, searches, summarizes. *Background* is 07 §1.3's slot, unchanged. A role is a model **and** an effort (thinking level). **Reviews use Lead** unless the project sets a review model. | Free-form roles you define; more roles (Review, Debug…); reviews on Deep (better, but costly on every task). |
| AM3 | **Structure decides, not a classifier.** The role comes from where the work runs (§4): a conversation is Lead, a build helper is Build, a review is Deep, an explore subagent is Quick. | A classifier on every message (Cursor/Copilot style). |
| AM4 | **The Lead names a role when it delegates**, never a model id: `task({role})`, `side_start({role})`. It is told what each role is good at and how much it costs, in words, not ids, so the same prompt works on any provider. If *you* name a model in words ("use Fable for this"), it may pass that model. | The Lead picks any model from the catalog. |
| AM5 | **Escalation is a consultation, not a switch.** A `think_hard({question})` tool asks Deep with the conversation's recent context and returns its advice; the conversation keeps its model and its cache. Lead and Build have it; Quick doesn't. | Switching the conversation to Deep for a turn. |
| AM6 | **Models change only at a session's boundaries.** A new subagent, helper or side conversation is a new session anyway. Inside one session, the only switch is Plan → Act (AM7), once. | Per-turn routing inside a conversation. |
| AM7 | **Planning uses Deep** in an Auto conversation (a switch in Settings › Models › Auto, on). In the Plan permission mode the planning turns run on Deep; after you approve, the conversation goes back to Lead. It costs one cache miss per plan; AM-4 measures whether that pays, and the switch's default follows the result. | No planning model (keep Lead throughout). |
| AM8 | **A bounded cascade for helpers.** A build task the review sends back twice is retried once on Deep before it asks you. Nothing else cascades. | FrugalGPT-style cascades everywhere; none at all. |
| AM9 | **Auto only uses the models in your roles.** No catalog-wide picking, no provider you didn't put in a role, no silent fallback to another role's model on an error (10 FR4 holds). An empty role uses Lead's model. | Fallback between roles on rate limits (Copilot's health signals). Later, maybe, as an explicit setting. |
| AM10 | **You always see who did what.** The chip says "Auto"; every answer, task card and helper card says role and model ("Build · DeepSeek V4"); Usage groups by role. | Hidden by default (Cursor). |
| AM11 | **Roles come prefilled** from what you connected (a table per provider, like `PREFERRED_MODEL` and `UTILITY_MODEL` today), and you see them before you turn Auto on, so switching it on doesn't mean filling four rows. | Ask you to fill four rows before Auto can be turned on. |
| AM12 | **A project can override roles**: the way of working's `buildModel` and `reviewModel` become the project's Build and review roles, in the same sheet, with Lead, Deep and Quick added. | A second place for project models. |

## 4. Who gets which role

| Work | Role on Auto | Pinned conversation (today) |
|---|---|---|
| A conversation you start (Home, a project, Quick Chat) | Lead | The pinned model |
| Plan permission mode, until you approve | Deep (AM7) | The pinned model |
| `task` subagent | What the Lead passes; without one: read-only tools → Quick, otherwise Build | The parent's model |
| Side conversation | What the Lead passes; default Lead (you'll talk to it) | The parent's model, or `side_start`'s |
| Board helper, kind `build` | Build (project override first) | `buildModel`, else the project's |
| Board helper, kind `review` | The project's review model, else Lead | `reviewModel`, else `buildModel` |
| A build task sent back twice | Deep, once (AM8) | — |
| `think_hard` | Deep | Not offered (pinned means pinned) |
| An automation that runs as Piopio (27) | Lead, unless the automation pins a model | The automation's model |
| An agent | Its own model (an agent is *who*, 26 CL1) | Same |
| Titles, summaries, commit messages, learned facts | Background ("Automatic") | Same |

Agents on Auto, and `ask_agent`, stay out of v1: an agent's model is part of who it is.

## 5. What the Lead is told

Under Auto the Lead's prompt gets a short block, built from your roles:

```
Models for delegation (pass a role, not a model):
- quick: Claude Haiku 5.5 · fast, cheap · reading, searching, summarizing, simple questions
- build: DeepSeek V4 · cheap · doing a task with a clear brief: code, edits, checks
- deep: Fable 5.2, high effort · expensive · hard design, a bug that resisted; also think_hard
You are lead: Claude Opus 5.5. Delegate grunt work; keep talking to the user and judging results yourself.
Write briefs a cheaper model can follow: files, what done looks like, how to check it.
```

The price words come from the catalog (the picker's price tiers). If two roles are the same model, the block says so,
so the Lead doesn't delegate for nothing. The block is cut when no role differs from the Lead's model.

## 6. What you see

**The picker.** Only once Auto is on: "Auto" is the first row, with one line under it: "Lead Opus 5.5 · builds with
DeepSeek V4 · Fable 5.2 for hard parts". Picking a model pins the conversation, as today. With Auto off the picker is
unchanged.

**The transcript.** Each answer's footer names the model, as now, with the role when it's not Lead. Task and helper
cards show "Build · DeepSeek V4 · $0.03". A `think_hard` call shows as a compact line: "Asked Fable 5.2 · 12s · $0.21",
expandable to the question and the advice.

**Settings › Models › Auto.** A card under the providers, beside "Default per mode", which stays:
- A switch, **off**: "Auto: Piopio picks a model for each piece of work". One line says what changes when it's on.
- Four rows (Lead, Deep, Build, Quick), each a model and an effort, with "Suggested" on prefilled ones and a way back
  to the suggestion. They're visible and editable while the switch is off, so you can see what you'd turn on.
- With the switch on: "Plan with Deep" (AM7) and "Retry sent-back tasks on Deep" (AM8), both on, and "New
  conversations start on: your default model / Auto", on your default model.

**Project settings › Way of working.** With Auto on, the build and review models become "Models in this project", the
same four rows plus review, each "Same as Auto" by default (review: "Same as Lead"). With Auto off they stay the two
rows they are today.

**Usage.** A "By role" view beside "By model".

## 7. Engine and protocol

- **Roles in settings:** `settings.models.auto: { enabled: false, roles: { lead?, deep?, build?, quick? }, planWithDeep,
  retryOnDeep, newConversations: "default" | "auto" }`, each role `{ model: ModelRef, thinking? }`. `enabled` is false
  until you switch it on, and every path below checks it first: off, `{ auto: true }` is refused by
  `sessions.create` / `configure`, `task` and `side_start` don't offer `role`, and `think_hard` isn't registered.
  Switching it off rewrites each auto session to its resolved Lead model. A project's way of working gains the same
  `roles` and keeps reading `buildModel` / `reviewModel` (migrated into `roles.build` and `reviewRole`).
- **One resolver:** `roles.ts` — `resolveRole(role, { projectId? }) → { model, thinking }`: the project's override,
  else yours, else the suggestion for your connected providers, else Lead's. Everything in §4 asks it; nothing else
  reads role settings.
- **Sessions:** a session's model becomes `ModelRef | { auto: true }`. An auto session stores the role it runs as
  (`lead`, or what its parent gave it), and resolves the model at the start of each turn, so changing a role in
  Settings applies from the next turn without touching history. `sessions.configure` can switch between Auto and a
  pinned model.
- **Timeline:** `assistant` items gain `role?`; the cost ledger rows gain `role`.
- **Tools:** `task` gains `role?: "quick" | "build" | "deep"`; `side_start`'s `model` becomes `role` (a model only
  when you named one); `think_hard({ question })` is a new extension in Build and chat profiles. It sends Deep the
  question, the conversation's last turns (capped, as `side_read` does) and AGENTS.md, as one call without tools, and
  returns the text. At most two calls per turn; the third returns "ask the user instead".
- **Plan mode:** the planning turns run with the Deep role; Approve sets the role back to Lead before the first Act
  turn.
- **Work runner:** `modelFor(kind)` asks the resolver; the "sent back twice" path (26 §7's review limit) retries once
  with Deep before it pauses for you.
- **Suggestions:** `ROLE_MODELS[provider]` beside `PREFERRED_MODEL` and `UTILITY_MODEL`, with Lead, Deep, Build and
  Quick for OpenRouter, Anthropic, OpenAI and the subscriptions; endpoints and other providers get Lead = their
  preferred model and nothing else (so Auto is the same as pinned until you fill the rows).
- **Tests** (faux provider with four models, fake clock): with Auto off, nothing changes (no picker row, no role
  parameter, no `think_hard`, `{ auto: true }` refused); turning it off moves auto sessions to Lead, pinned;
  resolution order; a subagent with and without a role; helpers
  with project overrides; Plan → Approve switch; the review-twice retry; `think_hard`'s limit; changing a role mid-
  conversation applies next turn; a pinned conversation unchanged; a provider disconnected under a role says so and
  doesn't fall back.

## 8. Milestones

| Milestone | What | Done when | Size |
|---|---|---|---|
| **AM-1 · Roles** | The switch (off), settings, resolver, suggestions, Auto in the picker, auto sessions, subagents and helpers by role, labels, Usage by role. | With the switch off, Piopio is unchanged; with it on, a conversation on Auto sends a read-only subagent to Quick and a build helper to Build, and every card says so. | M |
| **AM-2 · Delegation and escalation** | `task({role})`, `side_start({role})`, the Lead's block, `think_hard`. | The Lead picks roles on its own in a three-task job, and calls `think_hard` once on a planted hard bug. | M |
| **AM-3 · Plan and retry** | Plan with Deep; retry on Deep after two send-backs. | A planted task that the build model fails twice gets done on Deep before it asks you. | S |
| **AM-4 · A real trial** | Like 26 C4: the same three jobs on a throwaway project, once pinned on Opus, once on Auto (Opus / Fable / DeepSeek / Haiku). | Auto costs clearly less with no worse result, or this spec says why not and what changes. | S |

## 9. Later

- **A first-message triage** for conversations started from Home with no project: the background model decides Lead or
  Quick for "what's 15% of 80" versus real work. Only if AM-4 shows a lot of trivial conversations on Lead.
- **Native advisor tools** (Anthropic's advisor tool, OpenRouter's `advisor`) where the provider has them, instead of
  our `think_hard` call: cheaper (no extra round trip) but provider-bound.
- **Fallback within a role** on rate limits, as an explicit list per role ("if Fable is busy, use Opus"), never across
  providers without saying so.
- **Agents on Auto**: an agent's own conversation stays its model, its subagents use roles.

## 10. Questions answered (2026-11-18)

| Question | Answer |
|---|---|
| The role names | **Lead, Deep, Build, Quick**, as proposed. |
| Auto as the default for new conversations? | **No: opt-in.** Auto is something you turn on explicitly (AM0), and even then new conversations start on your default model unless you choose Auto for them. |
| Does a pinned conversation still delegate by role? | **No**, pinned means pinned (AM1), the simpler and more predictable choice. |
| Reviews on Deep or Lead? | **Lead** (AM2); a project can set its own review model. |
| Is planning on Deep worth one cache miss per plan? | **Kept, as a switch that's on** (AM7); AM-4 measures it, and the default follows the result. |

## Sources

- Cursor: [Cursor Router](https://cursor.com/help/models-and-usage/cursor-router), [Auto per request](https://startdebugging.net/2026/07/cursor-router-makes-auto-a-per-request-model-decision/)
- GitHub Copilot: [Auto model selection](https://docs.github.com/en/copilot/concepts/auto-model-selection), [GA in Copilot Chat](https://github.blog/changelog/2026-06-17-auto-mode-in-copilot-chat-available-for-all-users/)
- OpenRouter: [Auto Router](https://openrouter.ai/docs/guides/routing/routers/auto-router), [Advisor server tool](https://openrouter.ai/blog/announcements/advisor-server-tool/)
- Anthropic: [Advisor tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool), [Claude Code model config](https://docs.anthropic.com/en/docs/claude-code/model-config)
- Aider: [Architect / editor](https://aider.chat/2024/09/26/architect.html)
- Cline: [Plan and Act](https://docs.cline.bot/core-workflows/plan-and-act), [Plan/Act usage patterns](https://cline.bot/blog/plan-act-model-usage-patterns-in-cline)
- Roo Code: [Using modes (sticky models)](https://docs.roocode.com/basic-usage/using-modes)
- OpenCode: [Agents](https://opencode.ai/docs/agents/)
- Research: [RouteLLM](https://arxiv.org/html/2406.18665v3), [Routing vs cascades](https://web.stanford.edu/~shuhuiq/blog/review-routing-cascades.html)
