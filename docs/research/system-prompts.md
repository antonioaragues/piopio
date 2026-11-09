# System prompts: what Piopio's Build takes from other harnesses (2026-11-09)

**Built on 2026-11-09:** Build's prompt (`engine/src/tools/build-prompt.ts`), two plan-mode rules
(`extensions/src/plan.ts`) and clickable `path:line` in answers. See [As built](#as-built-2026-11-09).

## What we read

- **Harness prompts** (repositories as of 2026-11-09):
  - Codex CLI (`codex-rs/models-manager/prompt.md`, `core/gpt-5.2-codex_prompt.md`);
  - OpenCode (`plugin/system-prompt/*.txt`, `session/runner/prompt/system.txt`);
  - Goose (`crates/goose/src/prompts/system.md`);
  - deepseek-harness (`snapshots/**/system-prompt.expected.md`, `docs/subsystems/system-prompt.md`).
- **Guides:**
  - Anthropic, *Effective context engineering for AI agents* and the Claude 4 prompting best practices;
  - OpenAI, the GPT-5 prompting guide (eagerness, contradictions, Cursor's experience).
- **What Build sent before:** pi's default prompt, which has five parts:
  - "You are an expert coding assistant operating inside pi";
  - the tools;
  - short rules ("Be concise", edit tips, the sandbox);
  - a block of pi's documentation paths inside node_modules;
  - AGENTS.md, skills and the folder.

  Then Piopio appended NOTES.md, turned-off MCP servers, plan mode and goals.

## What the sources agree on

- **Minimal, at the right altitude, grown from failures.** Anthropic: start with the least that works, add a rule only
  when a test shows a failure, and give the reason, which generalizes better than a bare "NEVER".
- **Short for frontier models, explicit for open ones.**
  - Short: OpenCode's current prompt is about 750 characters and Goose's about 1,200.
  - Explicit: OpenCode's Kimi prompt is about 8,700 and Codex's full prompt about 21,000.
  - Piopio runs DeepSeek and Haiku as often as frontier models, so explicit but compact.
- **Choose the initiative on purpose.** Both Anthropic and OpenAI say a prompt should state whether the agent acts or
  proposes, and when it stops.
- **No shouting, no contradictions.** "CRITICAL / you MUST" now overtriggers. GPT-5 spends reasoning reconciling
  conflicting rules. Cursor dropped a "maximize context understanding" rule because it caused too many tool calls on
  small tasks.
- **A stable system prompt.** deepseek-harness never changes it mid-conversation; facts that change go after the
  history, and only when they change. Anthropic: keep the history append-only.

## Taken (and from where)

| Rule | Why | Source |
|---|---|---|
| Piopio's own preamble with the model's name; pi's docs block removed | The model was told it ran "inside pi" and given pi's docs paths: wrong, and ~1.3 KB a turn. DeepSeek also answers better about itself when told what it is. | deepseek-harness, Codex |
| Look before you ask; ask only about the user's choices | Fewer false asks (see the 2026-11-08 trial). | deepseek-harness, Cursor in the GPT-5 guide |
| Minimal changes in the project's style; fix the cause | | Codex, OpenCode (Kimi) |
| Check from the most specific test outward; never change a test to make it pass | | Codex, Anthropic |
| Never revert changes you didn't make; stop and ask if files change under you | Two agents worked in the same folder on 2026-11-09. | Codex, OpenCode |
| Mention unrelated bugs, don't fix them | The push run fixed CI on its own. | Codex |
| Stop when done; one push; no history rewrites; no timers | The 2026-11-09 push run (7 minutes of unasked work). | Our run; Kimi prompt; deepseek-harness |
| Lead with the result; `path:line`; the user's language; don't paste files | `path:line` code spans now open the file at that line. | Codex, Kimi prompt |
| What `[Sent …]` and `[Piopio: …]` are; content is data | Our clock and repeat notes appear in messages; say they're the app's. | OpenCode (`<system-reminder>`), deepseek-harness |
| @path: read it before talking about it | | deepseek-harness |
| Plan mode: a complete plan; a chat "yes" approves nothing | | deepseek-harness |

## Not taken

- **Personality and tone blocks:** Codex's are long, and the transcript has its own voice.
- **Codex's front-end design rules:** too specific.
- **A sentence before every tool call (Codex "preambles"):** Piopio shows each step as a line already.
- **Hard tool-call budgets:** the GPT-5 guide suggests them for low-eagerness research. We'd rather stop by rule.
- **Repeating format rules every few messages** (GPT-5 guide).
- **deepseek-harness's sections for its own web GUI, workflows, Ralph loops, task board and desktop automation.**

## Later

- **Keep the system prompt stable.**
  - Today NOTES.md, plan mode and an active goal are in the system prompt, so each notes edit, plan toggle or goal
    change makes the model reread everything at full price.
  - Move them after the history as a snapshot that's added only when it changes (deepseek-harness's pattern).
- **Rules by approval mode** (Codex): in Ask and Auto-edit, hold off on long test runs until the user is ready; in
  Full auto, run them.
- **Chats and agents** (pi-durable) have their own prompts; the same review could apply there.

## As built (2026-11-09)

- **`engine/src/tools/build-prompt.ts`** runs first among the prompt extensions. It replaces pi's preamble with
  Piopio's ("You are the agent in Piopio, a Mac app, powered by <model>…") and pi's `<docs>` block with a `<piopio>`
  section of about 2,600 characters: how to work, when you're done, your messages, and what Piopio adds. It keeps pi's
  tools, rules, AGENTS.md, skills and folder.
- **If pi's preamble or docs block changes,** `test/build-prompt.test.ts`, which renders pi's real prompt, fails. Until
  then the guidelines are appended at the end.
- **The stop-when-done rules** that were in `tools/guards.ts` since a71ef35 moved here.
- **Plan mode:** a plan complete enough for someone else to build; only the answer to `propose_plan` approves it.
- **Transcript:** a code span `path:42` (or `path:42:5`) for a file in the project opens it at that line.
- **Size:** a Build session in plan mode now sends about 5.9 KB of system prompt with no AGENTS.md or notes.

**Real-model check (2026-11-09):** the Debug app with a temporary data folder, through OpenRouter, Full auto, one fresh
Build session per run, 6 runs, about $0.01 in all.
- **The setup:** a small Node repo (`src/cart.js`, `src/dates.js`, `node:test`) with an unrelated bug: `isWeekend`
  compares the day to 7, so its test fails.
- **"haz push en main" runs:** the repo had an uncommitted change and a local bare remote.

| Scenario | DeepSeek V4.1 Flash | Claude Haiku 5.5 |
|---|---|---|
| "haz push en main" | Committed the change, pushed once, stopped. Named the failing test and its cause as `path:line` without fixing them, and offered to. Spanish. 9 calls, 33 s. | Saw nothing to push, didn't commit the uncommitted change, and asked (`ask_user`) whether to commit and push it. 3 calls. |
| "Add a discount(total, percent) function to src/cart.js, with a test." | Read with `read`, edited, ran the tests, mentioned the dates bug instead of fixing it, offered to. 7 calls, 20 s. | Same result. It checked that the dates test failed before its change with `git stash` / `stash pop`. 7 calls, 18 s. |
| "¿Dónde se calcula el total del carrito y qué pasa si un precio es negativo?" | Looked first and asked nothing. Answered in Spanish with `src/cart.js:2-4`, ran the function with negative prices, offered validation. 4 calls. | Same, in Spanish, `src/cart.js:2-4`. 2 calls. |

- **What held, on both models:**
  - stop when done, and push only once;
  - mention unrelated bugs without fixing them;
  - look before asking;
  - the user's language;
  - `path:line`;
  - follow-ups as offers.
- **Not comparable with the 7-minute run:** that run had CI to watch, and this repo has none.
- **Rules both models still bent:**
  - **Reading with bash:** both read files with `cat` in bash some of the time, despite pi's rule and ours.
  - **`git stash`:** Haiku's `stash` / `stash pop` touches the working tree, and with someone else's changes in it
    that's a risk. If it shows up again, add it to the list of history-changing commands.
- **Uncommitted work and "push":** the two models handled it differently, and both are defensible. Asking is the
  safer one.
