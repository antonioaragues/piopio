# 16 — Debate

Written 2026-10-29. DB1 and DB2 (Review style, engine and app) built the same day; see §9.

## 1. The experience

You give Piopio a goal and two models, and they work on it together until they agree.

1. **Start a debate.** New Thread › **Debate** (or `/debate` in an empty thread). You write the goal ("A one-page plan to migrate our billing to Stripe, for the CTO"), optionally what a good result must have ("covers rollback; under 600 words"), and pick two models, say Claude as the author and GPT as the reviewer. Piopio shows an estimate ("up to 6 rounds, about $0.40") and **Start**.
2. **Watch them work.** The transcript shows each model's turn with its name and colour, with a divider per round: *Round 2 · Claude revised, GPT has 2 objections left*. A panel on the right holds the **current draft** (with what changed since the last round) and the **open objections**.
3. **Step in whenever you want.** Typing while they work steers both ("forget the cost section, the CTO doesn't care"). **Stop** ends the debate where it is.
4. **Get the result.** A final card: **Agreed** with the draft, or **No agreement after 6 rounds** with what is still disputed and each side's position. Copy, export, or **Keep going** for more rounds.
5. **Carry on as a normal thread.** After the result, the thread is an ordinary thread with the author model, which has the whole debate in its context: "make it shorter", "now write the email that goes with it".

### Rules
- **Two models, two roles, one draft.** There is always exactly one current version of the deliverable, and every round either changes it or explains why not.
- **Disagreement is a result, not a failure.** If they don't converge, you see the open points clearly rather than a forced compromise.
- **You can always see what it costs.** The estimate before starting, and the running cost in the thread's footer. Both models' spend counts toward the thread.
- **Nothing new is sent anywhere.** A debate only calls the models you picked, with the providers and keys you already set up (local by default holds).

## 2. Styles

| Style | How it goes | Good for | Milestone |
|---|---|---|---|
| **Review** (default) | The author writes a draft. The reviewer checks it against the goal and criteria and raises objections. The author revises or pushes back with a reason. Repeat until the reviewer approves. | Deliverables: documents, plans, emails, specs, code snippets | DB1 |
| **Debate** | Round 1: each model writes its own answer without seeing the other's. Then each criticises the other's latest version and revises its own, until both say they agree on one version. | Open questions where you want different ideas first ("which database for…") | DB3 |
| **Judged** | Like Debate, plus a third model (or you) that reads both final positions and decides, explaining why. | Choices that must end in a decision | DB3 |

Review converges most reliably and is what most goals need, so it ships first and is the default.

## 3. How a round works (Review)

1. **Author turn.** The author sees the goal, the criteria, the current draft (none in round 1) and the open objections. It ends by calling `debate_submit`:
   - `draft` — the full new version (or `unchanged: true`),
   - `changes` — one line per change, tied to the objections it addresses,
   - `pushback` — objections it won't act on, each with a reason.
2. **Reviewer turn.** The reviewer sees the goal, the criteria, the new draft, the author's changes and pushback, and its own earlier objections. It ends by calling `debate_review`:
   - `objections` — each with an id, the text, `blocking` or `minor`, and `open`, `resolved` or `withdrawn` (for earlier ones),
   - `approve` — true when nothing blocking is open.
3. **The engine decides what's next** (§4) and starts the next round, or ends.

The two tools are the only way a turn ends; if a model answers without calling one, the engine asks once more ("End your turn by calling debate_review"), then treats the turn as unchanged/no-new-objections and says so in the transcript.

### Keeping it honest
Models in a debate tend to agree too fast ("great point, I fully agree"). The system prompts and the tools push against that:
- The reviewer is told it is judged on the quality of the final draft, not on being agreeable, and that approving with blocking problems left is a failure.
- `withdrawn` needs a reason; `pushback` needs a reason. Both show in the transcript.
- The criteria are written once, up front, and quoted in every reviewer turn, so the bar doesn't drift.
- In Debate style, round 1 is blind: both answers are written before either sees the other.
- Picking models from **different providers** is suggested in the start sheet (two models of one family tend to share blind spots), but not required.

## 4. When it ends

In this order:
1. **Agreed:** the reviewer approves (Review), or both sides' last turns say they agree with the same draft version (Debate).
2. **Stalled:** two rounds in a row with no change to the draft and the same open objections. Ends as *No agreement*, listing them.
3. **Round limit:** default 6, settable 2–12 in the start sheet. Ends as *No agreement*, listing what's open.
4. **Stopped by you,** or a model error that a retry doesn't fix. Ends as *Stopped*, with the latest draft.

**Keep going** on the result card adds rounds (the same number again) and continues from where it ended. In Judged style, *No agreement* goes to the judge instead of ending.

## 5. What the user sees

- **Start sheet:** goal, criteria (optional), style, author and reviewer models (each a normal model picker with its thinking level), rounds, and the estimate. Defaults: the Chat default model as author, the last reviewer used (or a different provider's flagship) as reviewer.
- **Transcript:** your goal as the first message. Each model turn is an assistant message with a speaker badge (name and colour) above it; the tool call shows as a compact line (*Submitted draft v3 · 4 changes · 1 pushback*, *2 objections, 1 resolved*) that expands. A round divider between rounds. Your steering messages show as yours, in place.
- **Draft panel** (right side, like a notebook's Progress panel): the current draft rendered, a *v3 · changed in round 3* header, Show changes (a diff against the previous version), Copy. Below it, **Objections**: open ones first, each with who raised it, blocking/minor, and its history (raised in round 1, pushed back in round 2, resolved in round 3).
- **Result card:** Agreed / No agreement / Stopped, the final draft, open objections with both positions, rounds and total cost; Copy, Export, Keep going.
- **Sidebar:** a debate thread has a small two-speaker icon; while running, the usual working indicator.

## 6. How it's built

### Engine
- **A debate is a thread** (`kind: "thread"`) with a `debate` setting, stored in the same pi-durable session file as any thread, so threads' durability, search, export and the catalog all apply.
- **New `runtimes/debate.ts`**, a `Runtime` that owns the thread while the debate runs. The session holds **one conversation per participant** (author, reviewer; later a second debater and a judge). In each, that participant's own turns are `assistant` messages and the other's turns come in as `user` messages framed with who wrote them, so each model knows which words are its own. Each conversation has its own model, thinking level and system prompt, and only its own tool (`debate_submit` or `debate_review`) on top of the thread's usual tools (web, connectors, MCP).
- **The runtime is the moderator:** it runs one turn at a time, reads the tool result, updates the **debate state** (draft versions, objections and their history, round, status) and builds the next turn's input. The state is a pi-durable doc in the session, so a debate interrupted by a quit or crash resumes at the turn it was on (as threads already resume).
- **Relay input stays small:** the next turn gets the goal and criteria, the latest draft, the other side's changes or objections and the open-objection list, not the other model's whole history. Each conversation's own history grows by one exchange per round; with the round limit and prompt caching that stays cheap. Older drafts are not repeated.
- **Steering:** your message goes into both conversations as a user note ("The user says: …") before their next turns; while a turn is streaming it uses `whenBusy: "steer"` on that conversation.
- **The shown transcript** is assembled from both conversations in turn order: participants' answers as `assistant` items with a `speaker`, tool calls as tool items, round dividers as system items, and the result as a new `debate_result` item.
- **After the result** the thread switches back to `ThreadRuntime` on the **author's conversation**, which already holds the whole debate from the author's side. That conversation is the thread's root from then on, so edit, regenerate and fork work as in any thread. (In Debate style, the side whose draft was agreed on, or the first model if none.)
- **Cost:** both conversations' usage adds up into the thread's usage, as subagents' cost counts toward the parent.
- **Estimate:** rounds × (author + reviewer turn) using each model's prices and a token estimate from the goal, criteria and a typical draft size; shown as "up to".

### Protocol
- `sessions.create` (kind `thread`) takes an optional `debate: { style, goal, criteria?, participants: [{ role, model, thinking? }], maxRounds }`.
- `AssistantItem` gets an optional `speaker: { role, label }`.
- New `DebateResultItem` (`kind: "debate_result"`): status, final draft, open objections with both positions, rounds, cost.
- `Snapshot` gets an optional `debate` with the state the panel shows (draft versions, objections, round, status).
- `sessions.debate.continue` (more rounds), `sessions.debate.stop` (end now; `sessions.abort` keeps meaning "stop this turn").

### App
- Start sheet (from New Thread and `/debate`), speaker badges and round dividers in the transcript, the draft and objections panel, the result card, the sidebar icon.

### Tests
With the scripted model, as other runtimes: agree in round 2; stall detection; round limit; a turn without its tool call; steering mid-debate; quit and resume mid-round; Keep going; continuing as a normal thread afterwards with edit and fork; cost adding up across both models.

## 7. Milestones

- **DB1 — Review style, engine.** `runtimes/debate.ts`, the two tools, the state doc, ending rules, the protocol additions, tests with the scripted model.
- **DB2 — Review style, app.** Start sheet, transcript speakers and dividers, draft and objections panel, result card, Keep going. Try it on real goals with real models and tune the prompts.
- **DB3 — Debate and Judged styles.** Blind round 1, symmetric turns, the judge (a model, or you choosing on the result card).
- **Later.** A debate as an **agent recipe** (06-agents): it runs in the background on a schedule or when asked and hands back the result in Inbox. Debates in Build sessions (an author writes the change, a reviewer reads the diff). More than two participants.

## 8. Open questions

- DQ1 · **Name in the app.** "Debate" fits the Debate style but not Review, which is the default. Alternatives: "Second opinion", "Review loop", "Two models". Decide before DB2.
- DQ2 · **Can you be the reviewer?** A "you review" mode (the model revises, you raise objections) is cheap once DB1 exists. Worth it, or is that just a normal thread?
- DQ3 · **Memory.** Should a finished debate offer to remember its conclusion (14-memory), like Remember this on answers?

## 9. DB1–DB2 status (2026-10-29)

**Built**
- **Engine:** `runtimes/debate.ts`. A debate thread is a thread with a `debate` record in the catalog (settings, the reviewer's conversation id, status, round limit, endings). The author is the session's root conversation and the reviewer a second one. Relayed work is stored as `piopio.debate` entries, which are hidden in the transcript except for your goal and notes. Drafts, objections and each turn's summary are read back from the `debate_submit` / `debate_review` calls, so nothing else needs saving and a debate picks up again after a restart. Invalid calls are refused so the model can retry in the same turn: pushback on an objection that isn't open, approving with blocking objections open, or no draft in round 1. When a turn ends without its tool call, the model is asked once more. The debate stops if the author never writes a draft or a model keeps failing.
- **Protocol:** `sessions.create` takes `debate`; `AssistantItem.speaker`; a `debate` timeline item (round divider, turn summary, result); `SessionState.debate`; `SessionSummary.debate`; `sessions.debate.continue` and `sessions.debate.stop`.
- **App:** New Debate sheet (⌥⌘N, File menu, palette, the sidebar's new menu, the Chat empty state) with goal, criteria, the two models (the last reviewer is remembered, and a hint suggests models from different makers), rounds and a rough cost estimate. In the transcript, each answer carries its speaker's color and name, plus round dividers, turn summaries, and the result card (Copy draft, Keep going) followed by the final draft. A panel shows the status, the draft with version picker, Changes (a line diff) and Copy, and the objections with severity, pushback and history. The header has Stop debate or Keep going and toggles the panel. The composer says where your message goes. The sidebar marks debate threads.
- **Verified:** 3 engine tests with the scripted model: agreeing in round 2 with the transcript, panel state, chat afterwards and a restart; the round limit, Keep going and a note from you; a missing draft, a nudge, validation and stopping. App captures of a running debate, a finished one and the sheet.

**Different from the spec above**
- Edit, Regenerate and Fork aren't offered in debate threads (the moderator decides who speaks next). Moving one to a Notebook isn't offered either.
- Debates use web tools and About me, not MCP or connected apps.
- The composer's stop button ends the debate, like Stop debate.
- A note you send while a debate runs reaches each side at the start of its next turn, not mid-answer.

**Not verified:** how real models behave, including prompt quality and whether reviewers approve too easily. That needs real goals with real models (DB2's "tune the prompts"). The estimate is a rough formula, not checked against real costs.
