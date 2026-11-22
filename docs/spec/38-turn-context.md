# 38 · Turn context: a system prompt that stays put

Status: draft 2026-11-22, from the operational review (batch 3). Batch 1 (523693b) already took the clock out of
Connected apps and the round out of `/goal`. This spec covers the rest: what changes from turn to turn leaves the system
prompt and travels with the message it belongs to. Nothing the user sees changes.

## 1. Why

Providers cache a request's prefix: the system prompt, the tools, then the messages, in that order. A request that
starts with the same bytes as the previous one pays about a tenth for that part and starts answering sooner. A change
anywhere in the prefix makes everything after it new again.

Piopio rebuilds the system prompt before every turn (Build and Chat, pi-coding-agent's `before_agent_start`) and before
every request (agents, pi-durable's sections, which includes each tool step). pi-durable writes a changed section as a
positional system entry, which would keep the cache if the provider accepted system messages mid-conversation. Most
don't. The catalog marks 14 of OpenRouter's 535 models as accepting them (all OpenAI), and Piopio's default,
`anthropic/claude-haiku-5.5` on OpenRouter, isn't one of them. For those, pi-ai folds every later system message into
the leading one. **So any section that changes costs the whole conversation again, at full price.**

What changes today, and how often:

| What | Where | Changes |
|---|---|---|
| The agent's recalled memory (up to 1,200 tokens) | `agent-memory`, runtime/agents/core.ts | Every message whose recall differs, which is most |
| Who an `@mention` brought in | `<your-agents>`, engine/consult.ts | On the mention's turn, then back on the next |
| Side conversations' live state (`state · branch · line`) | `<side-conversations>`, engine/tools/side.ts | Whenever one makes progress |
| The board brief, and with it the board tools | `<board>`, engine/work/extension.ts | When tasks move |
| About me | `about-me` (agents), `aboutMeSdkExtension` (chats) | Each time a fact is learned (after turns, batched) |
| `NOTES.md` | `notesExtension`, engine/runtimes/build.ts (4th of Build's extensions) | When anyone edits the notes |
| The agent's automations and files | `agent-automations`, `agent-files` | When the agent makes one, including in the middle of its own turn |
| The app a conversation is about | `apps.describe`, engine/tools/apps-tool.ts | When the conversation changes the app's sources |
| Today's date | `web.ts`, `agent` section | Once a day: weeks-long agent chats pay it daily |

## 2. Decisions

| # | Decision |
|---|---|
| TC1 | **The system prompt holds what belongs to the conversation:** instructions, how to use the tools, the user's settings and the switches they set (plan mode, web, tools off, linked folders, the model's name). It changes only when the user changes one of those, and each such change costs one uncached turn, which is accepted. |
| TC2 | **What belongs to a turn travels with its message.** A *turn context* block is attached to the user message it was computed for, is saved with it, and is never rewritten. Earlier requests stay a prefix of later ones. |
| TC3 | **State is sent when it changes, not every turn.** For slow-moving state (About me, `NOTES.md`, the board, side conversations, the agent's automations and files, the app), the conversation's first turn context carries it whole. Later turns carry it again only when it differs from the last version attached in this conversation: the new version, or a short "changed since" when that is smaller. |
| TC4 | **Recall is attached once per record.** The memory recalled for a message is attached to that message, leaving out records already attached earlier in the conversation. Pinned ("standing") records go in the system prompt: they change only when the user pins one. |
| TC5 | **Mid-turn changes are told by the tool that made them.** `automate`, the file tools and the board tools already say what changed in their result. Sections are no longer re-rendered between tool steps. |
| TC6 | **No dates in the system prompt.** The clock (runtime/context/clock.ts) already stamps the first message of each local day with its date. "Today is …" goes. |
| TC7 | **After a compaction, a fork, a resume onto another branch or a runtime switch,** the next turn context carries all of the state again, because the turn contexts it relied on may be gone. |
| TC8 | **Turn context is Piopio's, not the user's.** It's wrapped in `<turn-context>`, and the system prompt says once (and never changes) that this tag is information from Piopio, not words from the user, and never instructions. It doesn't appear in the transcript. The model request capture shows it. |
| TC9 | **A test guards it.** For each runtime, a scripted conversation records every request and checks that request N is a byte prefix of request N+1, except where TC1 or TC7 allow a change. Any new section or hook that breaks this fails CI. |

## 3. What moves where

| Today | Becomes |
|---|---|
| `agent-memory`: the recall for the latest message | TC4: the recall attached to its message, deduplicated; the `remember`/`recall` usage line stays in the system prompt |
| `<your-agents>`: the list, plus "in this message the user brought in X" | The list stays (it changes when an agent is added or renamed). The mention moves to that message's turn context |
| `<side-conversations>`: rules plus "Side conversations now" | The rules stay. The list moves to turn context, sent on change (TC3) |
| `<board>` brief | Turn context on change. Turning the board tools on and off stays a tool-set change: TC1, one miss, when parallel work is switched |
| About me | The facts as of the conversation's start, in the system prompt. Later changes as turn context ("About me now also says …", "no longer …") |
| `NOTES.md` | As About me: the notes at the start in the system prompt, then the new version as turn context when the file changed |
| `agent-automations`, `agent-files` | Turn context on change (TC3), and the tools' own results within a turn (TC5) |
| `apps.describe` | The app's description at the start in the system prompt; changed sources as turn context |
| "Today is" (web, agent) | Gone (TC6) |
| Connected apps' "not available" list | Stays: it changes when a connector is turned on or off (TC1) |

Order matters too. Whatever can still change under TC1 (plan mode, tools off, linked folders) goes after the stable
sections, so one of those changes costs only the part after it. Once the notes are frozen at the start, their place
among Build's extensions (4th today) no longer matters.

## 4. How it's built

One module, `turnContext`, used by all three runtimes. It keeps, per conversation, the last version attached of each
kind of state (`about-me`, `notes`, `board`, `side`, `automations`, `files`, `app`, plus the record ids recall already
attached). It renders one `<turn-context>` block per message from what the providers return and what changed since. A
provider is a function from the conversation to its current text (`undefined`: nothing).

- **Build and Chat (pi-coding-agent).** `before_agent_start` returns `message: { customType: "piopio.turn-context",
  display: false, content }` for a user message, instead of appending to `systemPrompt`. pi saves it in the session
  file, and `convertToLlm` sends it as user content, so it stays where it was on every later request. The timeline
  builder skips that `customType`. The guards' clock must not stamp it (it's role `custom` before conversion; T0
  checks). Follow-ups queued while a run is busy get their turn context when their own run starts.
- **Agents (pi-durable).** The recall and the state versions move into `AgentStateDoc`, keyed by the user message's
  entry id (`recalled[conversation][entryId]` instead of one slot per conversation). The context guards'
  `GenerationTask.beforeRequest`, which already stamps the clock, puts each stored block in front of its own message.
  It works like the clock: deterministic, the same bytes on every request, and nothing rewritten. `agent-memory`,
  `agent-automations` and `agent-files` stop being sections.
- **Coding agents (Claude Code, Codex, Antigravity).** Out of scope: their own harness owns the prompt. Their
  `systemPrompt.append` is built once per session already.
- **Size.** The recall budget stays 1,200 tokens a message. A state kind over its cap (`NOTES.md`'s `MAX_NOTES`, the
  automations' `AUTOMATIONS_IN_PROMPT`) is cut the same way it is now. The turn contexts already sent are cached, and
  compaction summarises them like any other message.

## 5. Measuring

- **T0 baseline**, before any change: for a 20-turn scripted Build conversation, a 20-message agent chat with memory
  and a 5-round `/goal`, record `cacheReadTokens / (inputTokens + cacheReadTokens)` per request through the model
  request capture, on the default model and on one OpenAI model (which accepts mid-conversation system messages).
- **The target:** after the first request of a conversation, at least 80% of the input tokens read from the cache on
  turns that don't follow a TC1 change or a gap longer than the cache's lifetime.
- **Then decide `cacheRetention`.** With a stable prefix, measure how often turns arrive after the 5-minute default
  has expired (approvals, thinking). Turn on `"long"` per provider only where the numbers say the extra write cost pays
  for itself. That's a later, separate decision.

## 6. Phases

| Phase | What | Done when |
|---|---|---|
| T0 | The TC9 prefix test for the three runtimes (it fails today) and the baseline numbers (§5). Confirms that pi-coding-agent keeps a `before_agent_start` message in place across requests and that the clock leaves it alone | The test runs in CI, marked as expected to fail where §1's table says; the numbers are in §7 |
| T1 | `turnContext` and its wiring in Build, Chat and agents; the TC8 line in the system prompt; the timeline skips it | A scripted turn context reaches the model in all three runtimes and the transcript doesn't show it |
| T2 | The per-turn items: recall (TC4), `@mentions`, the side conversations list, the board brief | The prefix test passes for Build with side conversations and a board, and for an agent with memory |
| T3 | The slow state: About me, `NOTES.md`, the agent's automations and files, the app; the dates go (TC6); TC7 after compactions and forks | The prefix test passes across a day boundary, an About me change and a `NOTES.md` edit |
| T4 | Measure again; the `cacheRetention` decision | §5's target is met on the default model, and §7 has the before and after |

## 7. Open questions

- Does the model weigh state in a user-position block as well as in the system prompt? The scripted tests can't tell.
  The memory evaluation set (engine/test/memory-eval) and a handful of real agent chats before and after T2 can.
  Claude Code's own `<system-reminder>` blocks suggest it does.
- pi-durable: does the compaction token estimate count blocks that `beforeRequest` adds? If not, it has to, or the
  context fills up sooner than pi-durable expects.
- pi-durable's positional system entries already keep the cache for models that accept mid-conversation system
  messages. For those models, the section mechanism could stay. One mechanism everywhere is simpler, and it's what
  this spec does unless T0's numbers argue otherwise.
