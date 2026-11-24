# Evals of real use (launch plan §5), first slice

Real models and the real coding agents doing real jobs in a small project, checked on the result (files, the
typecheck, which tools ran, what asked for approval), never on the words. The scripted suites prove the plumbing; these
say whether a model, with Piopio's prompts and tools, gets the job done, and they catch what only real models and real
agent CLIs show: the bugs the 2026-11-24 pass found by hand ([par-pass-2026-11-24.md](../../../../docs/research/par-pass-2026-11-24.md))
are the first scenarios.

**Opt-in.** They cost money and take minutes, so they never run on push or on CI: by hand, or nightly.

```bash
corepack pnpm -r build                       # the runner uses packages/engine/dist
export OPENROUTER_API_KEY=…                  # Piopio's own agent; the coding agents use their CLIs' sign-in
node packages/engine/test/evals/run.mjs      # default runners, every scenario, $2 budget
```

| Option | |
|---|---|
| `--runners a,b` | `<provider>:<model id>`. Default `openrouter:anthropic/claude-haiku-5.5,claude-code:haiku`. Also `codex-cli:gpt-6.2-sol`, `antigravity-cli:gemini-3.8-flash`, any OpenRouter model |
| `--scenarios a,b` | Some of them (`--list` names them) |
| `--budget 2` | Dollars for the whole run. A scenario that goes over is stopped; the ones after it are skipped |
| `--repeat 3` | Each scenario this many times (pass rates, not one roll) |
| `--label nightly` | Names the results file |
| `--verbose` | The engine's log and every approval as it's asked |

A runner whose key or CLI is missing is skipped with a line saying why, and listed under `notRun` in the results.

**Piopio's own agent hasn't run yet**: the first run (2026-11-25) had no OpenRouter key in its environment, so only the
coding agents ran. With `OPENROUTER_API_KEY` set in your own shell:

```bash
node packages/engine/test/evals/run.mjs --runners openrouter:anthropic/claude-haiku-5.5
```

## How it runs

- **The engine** is `packages/engine/dist/main.js`, started per scenario as the app starts it, with a data folder of its
  own in the temp folder (`PIOPIO_HOME`, pi's folders, agents, teams; webhook triggers move off a taken port by themselves), so nothing touches your
  Piopio. The runner talks to it over its socket as `test/client.ts` does (`engine.hello` with `engine.token`, then
  `projects.add`, `sessions.create`/`submit`/`open`/`respond`/`review`/`reviewFinding`). It answers `secrets.get` with
  nothing, so the key comes from the environment (`PIOPIO_ALLOW_ENV_SECRETS=1`). Claude Code, Codex and Antigravity
  are the CLIs on this Mac, signed in as you; they run as the engine's children, as in the app.
- **The project** is [fixtures/par-shop](fixtures/par-shop), copied to a temp folder per scenario, given a free port
  (the copy's `server.mjs` default replaces 5173, so runs never meet a dev server of yours), TypeScript linked in from
  the repo's `node_modules`, and `git init` at one commit on `main`. Added as a new project: untrusted, network
  filtered, Auto-edit, its check detected as `npm run typecheck`.
- **The browser** is a stand-in for the Mac app, [browser.mjs](browser.mjs): it answers the engine's `app.tool` calls
  for `browser_*` with headless Google Chrome over the DevTools protocol. The page's scripts run for real, and the
  preview's console and requests come from the app's own recorder script, read from `BrowserPreview.swift` at start.
  So the preview scenarios run without the app; what they don't cover is WebKit itself and the app's panel. It reads
  pages and doesn't act on them: click, type, screenshots and tabs answer that it can't. `PIOPIO_EVAL_CHROME` points at
  another Chrome.
- **Approvals** follow one policy: allow each (and count it); a question gets its first option or "use your judgment".
  Every approval is recorded with its tool, title and detail, and whether it was for one of Piopio's own tools.
- **Cost** is the sessions' own `usage.costUsd` (the review's session included). Claude Code, Codex and Antigravity on a
  plan cost nothing by key (spec 31 CA6), so their results show $0 and the tokens.
- **Results** go to [results/](results/), one JSON per run: when, the engine's build, pi's and the agents' versions,
  each scenario × runner with pass, every check, cost, tokens, seconds, approvals, tool calls and browser calls. A
  failed scenario keeps its project folder and the engine's log in the temp folder, and says where.

## The fixture: par-shop

| File | What it is |
|---|---|
| `server.mjs` | A node `http` server on `PORT` or 5173: `public/` and `GET /api/products` (three products: Blue mug, Steel kettle, Oak tray, as JSON). Anything else is a plain-text 404 "Not found" |
| `public/index.html` | "Par Shop", a status line and an empty list, loading `/app.js` |
| `public/app.js` | **The planted bug:** fetches `/api/items` (a 404), then `res.json()` throws on "Not found", so the console says `Couldn't load the products: Unexpected token 'N'…` and the page "Couldn't load the products." |
| `src/cart.ts` | `type Item = { name: string; price: number; qty: number }` and `total(items): number`, `sum + item.price * item.qty` on line 5 |
| `src/checkout.ts` | `receipt(items)`, using `item.qty` and `total(items).toFixed(2)` on line 5, so a `total()` returning a string breaks it |
| `tsconfig.json` | `strict`, `nodenext`, `noEmit`, `src/` only |
| `package.json` | `"type": "module"`, scripts `dev` (`node server.mjs`) and `typecheck` (`tsc --noEmit -p .`) |

## The scenarios

| Id | Runners | Start state and prompt | Pass when |
|---|---|---|---|
| `preview-fix` | every runner | "Start the dev server in the background, open the preview, find why the list of products doesn't load, fix it, and check it in the preview." | `public/app.js` asks for `/api/products` (not `/api/items`); the project typechecks; the last browser read (`browser_read` or `browser_open`) lists the three products; no `browser_eval`; no approval for Piopio's own tools (`browser_*`, `process_*`, however the agent names them: F5, F6, F8) |
| `diagnostics-baseline` | Piopio's agent | "Change total() in src/cart.ts to return a string with two decimals, like "12.50". Don't run any commands." | A "Checked with … N new problem(s) since its first edit" entry is in the conversation (F3); `total()` returns `string`; the project typechecks at the end |
| `review-fix` | every runner | A branch `simplify-total` on top of main, one commit changing `item.price * item.qty` to `item.price + item.qty`. `sessions.review`, then Fix as `ThreadModel.fix` sends it (the finding as a message, then `reviewFinding` → `fixing`) | The review is `done` with a `bug` at `src/cart.ts` within two lines of the change; after Fix the finding is `fixed`, the multiplication is back and the project typechecks |
| `background-stop` | Piopio's agent | "Start the dev server in the background and tell me its address.", then "Stop the dev server." | The server was running and listening; `process_stop` ran; nothing listens on the port; no command is left running |

The review scenario plants its bug on a branch rather than asking the agent to write it: the review then compares the
branch with `main` (the session has no changes of its own), the same diff whoever runs it, at no cost.

## Results

See [results/](results/). Latest:

**2026-11-25** ([results/2026-11-25-coding-agents.json](results/2026-11-25-coding-agents.json)), the engine as built at
`20ea3cd`, pi 1.6.0, Claude Code 2.1.319, Codex 0.170.0 (codex-acp), Antigravity CLI 1.5.13. All on plans, so $0 by key.

| Scenario | Runner | Result | Time | Asked |
|---|---|---|---|---|
| preview-fix | Claude Code · haiku | pass | 30 s | 3 |
| preview-fix | Codex · gpt-6.2-sol | pass | 53 s | 2 |
| preview-fix | Antigravity · gemini-3.8-flash | pass | 63 s | 6 |
| review-fix | Claude Code · haiku | **fail** (passed in an earlier try the same night: 35 s) | 13 s | 0 |
| review-fix | Codex · gpt-6.2-sol | pass | 77 s | 0 |
| review-fix | Antigravity · gemini-3.8-flash | **fail** (twice more the same way while building this) | 9 s | 0 |
| every scenario | Piopio · openrouter:anthropic/claude-haiku-5.5 | **not run**: no `OPENROUTER_API_KEY` in this run's environment | | |

No approval for Piopio's own tools on any runner, and no `browser_eval`: the fixes for F1, F2, F5, F6 and F8 hold. What
the runs found:

- **E1 · Claude Code as the reviewer reported to its own `ReportFindings`.** Claude Code 2.1.319 has a built-in tool
  of that name, and the reviewer called it instead of Piopio's `report_findings` (MCP). The finding was right
  (`src/cart.ts:5`, bug, the fix), but it never reached Piopio, so the review ended "without reporting findings". It
  happens on some runs and not others.
- **E2 · Antigravity's review in Read only ends at once.** Its one command (`git status; git branch -a; git diff
  main..simplify-total`, in its own `plan` mode) failed with no output, and the turn ended without
  `report_findings`. Every try failed the same way.
- **E3 · Piopio's `bash` runs zsh with `nomatch`.** `grep -rn "total(" --include=*.ts .` failed with "no matches
  found: --include=*.ts" (Claude Code's reviewer, E1's run). The agents write bash.
- **Not checked yet:** whether the Fix turn changed other files. Claude Code's Fix, in one try, also added a test file and
  a `test` script, so a "nothing else changed" check would belong here.

## Next

- **A key without seeing it.** The 2026-11-24 pass let a test instance of the Debug app (its own `PIOPIO_HOME`) answer
  the engine's `secrets.get`; the driver answered null, so the broker fell through to the app. The runner could attach
  to an engine the app is serving instead of starting its own: no key in any environment. Not built.
- **The rest of §5's set** (25–30 scenarios), `--repeat` for pass rates on the recommended models, and a baseline a
  release mustn't fall below.

## Adding a scenario

A scenario in [scenarios.mjs](scenarios.mjs) is an `id`, the runners it's for (`"all"` or `"piopio"`, Piopio's own
agent, for what only pi's extensions do), a timeout, an optional `setup(ctx)` that changes the project before the
session starts, and `run(ctx)` that returns checks `{ name: { pass, detail? } }`. `ctx` has `session()`,
`turn(ref, text)`, `snapshot(ref)`, `summary(ref)`, `until(read, ready)`, `read(file)`, `write(file, text)`,
`git(...args)`, `typecheck()`, `tools(items)`, `approvals`, `browser.calls`, `port` and `client` for anything else. Check
the result, not the words; a bug found in real use goes in as a scenario before it's fixed.
