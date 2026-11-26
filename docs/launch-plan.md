# Launch plan

Written 2026-11-23 from the repository as it is at `e3a7638`: the specs, [status.md](status.md),
[the roadmap](spec/09-roadmap.md), [acceptance.md](acceptance.md), [setup.md](setup.md), CI's runs and GitHub (no open
issues, no pull requests, no releases, no tags). The scope in §3 was closed by the user on 2026-11-24; the order in §4 is a proposal.

## 1. Where Piopio stands

**A lot is built.** About 53,000 lines of TypeScript, 49,000 of Swift, 428 scripted tests and 42 specs. Build, Chat,
projects, local agents, automations, the browser, connectors (C1), coding agents, the Library, Overview and the
sandbox with its filtered network all exist in code.

**Almost none of it is proven.** That is the finding that shapes the plan:

| What | State | Evidence |
|---|---|---|
| Real-use acceptance | **0 of 8** scenarios passed; the results table is empty | [acceptance.md § Results](acceptance.md#results) |
| CI on `main` | **Red since 2026-11-22 21:11** (run 235, some 40 pushes): 4 tests in `github.test.ts` | `mkdtemp` in a data folder that doesn't exist on Linux, `packages/engine/src/github.ts:132` |
| Swift and app jobs | **Skipped on every run**: no runner registered | [ci.md](ci.md) |
| Releases | None. Developer ID and notarization not verified; `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY` empty | [setup.md](setup.md) |
| Cloud (Cloudflare) | K1 built and checked in workerd; **not on the account** (the Worker there needs a redeploy). A cloud agent's approval has never run for real | [30 §13](spec/30-cloud-target.md) |
| Piopio Server | **Spec only** (33, decided 2026-11-21). PS0 not started | [33](spec/33-piopio-server.md) |
| iPhone app | **Nothing**. Needs K2, the gateway, an Apple developer account and an APNs key | 30 §6, K3 |
| Evals | One memory set (40 questions, last run 2026-10-25) and a routing replay for notebooks, which no longer exist. No eval of what people will do with it | `packages/engine/test/memory-eval`, `test/replay` |
| Connectors for other people | Google in Testing (the review needs a homepage and a privacy policy on a verified domain); Microsoft not registered | setup.md §7–8 |
| Around the product | No website, no docs for users, no `SECURITY.md` or `CONTRIBUTING.md`, no issue templates. The README says "personal alpha" | |
| status.md | Stale: dated 2026-11-19, says 212 tests | |

**The pattern.** The roadmap said it on 2026-11-12: "the risk isn't missing features; it's breadth that hasn't been
used". Since then twelve more specs were opened (31–42), several decided and unbuilt (33, 40, 41, 42), and the
acceptance pass is still at zero. Building is fast here; what a launch needs is the slow part: use, and the things
only you can do.

## 2. What is open

- **Decided, not built:** Piopio Server PS0–PS3 (33), cloud K2–K7 (30), MCP server MS0–MS4 (41), coding agents A5 (31),
  voice VC0–VC4 (42), Show me how SH0–SH4 (40), computer use U0–U4 (23), memory M4–M6 (14), connectors C2–C3 (12).
- **Drafted, not confirmed:** auto model (28), provider order (29), listeners and steps (36), the rest of apps (35
  L2–L5), turn context T0–T4 (38, partly built).
- **Built, not proven:** everything in status.md's "Acceptance still pending" column.
- **K1's own gaps:** approval cards in a cloud agent's chat, its memory view and trace, attachments, definitions the
  cloud agent changes itself.
- **Only you can do:** Apple Developer Program, Developer ID and notarization; a domain with a homepage and a privacy
  policy; Google's review; the Azure account for Outlook; a Hetzner account; a real ChatGPT sign-in and a real local
  server; the self-hosted Mac runner.

## 3. Scope (closed by the user, 2026-11-24)

Fourteen items (Cloudflare added the same day), not in priority order, and one rule: **what works, works robustly.**

| Item | Spec | Built | Left for the launch |
|---|---|---|---|
| **Web** | none | Nothing | Homepage, download, privacy policy on a verified domain, docs for users. It also unblocks Google's review |
| **Piopio Server** | 33 | Nothing | PS0–PS3 |
| **Cloudflare** | 30 | K0; K1 in workerd, not on the account | K1 on the account and its gaps (30 §13), K2 chats, K4 capabilities, K5 the Mac Bridge, K6 the cloud browser, K7 Build in containers |
| **Companion app** (iPhone) | 30 §6, K3 | Nothing | The gateway, pairing, device tokens, Home, transcript, composer and tray, push |
| **MCP** | 41 | Nothing | MS0–MS4: Piopio as an MCP server, on the Mac, then on the server, then the CLI. 31's A5 is built with MS0 (41 PM11) |
| **Show me how** | 40 | Nothing | SH0–SH4 |
| **Computer use** | 23 | The spike (11) | U0–U4; four questions open in 23 §10 |
| **Connectors** | 12 | C1, Linear, tool search | C2–C3; Piopio's Google app reviewed, the Microsoft app registered |
| **Image generation** | none (backlog D11) | Nothing | A short spec first: which providers, where the pictures live |
| **PARx** | 09, Track I | PAR2–PAR5, PAR8 | PAR1 (use), PAR6 hooks, PAR7 the GitHub loop, PAR9 iOS Simulator, PAR10 cloud and parallel tasks, PAR11 headless, PAR12 |
| **Side conversations** | 24 | SD1–SD3 | SD3 tuned on its replay set, SD4 |
| **Memory** | 14 | M0–M3 | M4 past chats, M5 project lessons, M6 Hindsight (Q1 and Q3 decided 2026-11-24, 14 §6) |
| **Apps and Library** | 35 | L1, part of L4 | L2, L3, the rest of L4, L5 |
| **Evals** | §5 here | The memory set | The runner and the scenario set |

**Assumed inside the scope,** because the list can't ship without them: the acceptance pass, CI green with the Swift
jobs running, and Developer ID with notarization and Sparkle.

**Out until after the launch:** voice (42), auto model (28), provider order (29), listeners and steps (36), turn
context beyond what's built (38), subagents' option C (37), MCP Apps (25 V4), WhatsApp and Slack, and computer use from the cloud (30 CT4). No new spec opens until the launch.

**Confirmed by the user (2026-11-24):**
1. **Cloudflare is in:** the Worker goes on to chats, capabilities, the Mac Bridge, the browser and Build (K2, K4–K7),
   beside the server. The companion app's gateway is built for both.
2. **MCP** is spec 41, Piopio as a server. MCP Apps stays out.
3. **Memory:** M4 and M5 are in; M6 (Hindsight) only if S6's verdict has changed.

**What "robust" means for each item:** its scenarios in the eval set pass on the recommended models, its setup meets §3.1's bar, it has been used
for a week without a blocking issue, and status.md says what it does not do.

### 3.1 The setup bar (from the user, 2026-11-24)

Everything must be really simple to set up, at the level of the best app in each category. The user's example: with
a Cloudflare account, Piopio creates the Worker and its Durable Objects and deploys them, and the person never sees
how. The same for the server, connectors and the rest. Building by hand, as the cloud was built so far, is not the
product.

**Rules for every setup flow**
- No terminal, no config file, no id copied from one place to another.
- At most **one thing pasted per outside service**, and none where the service offers a sign-in.
- One screen that says what will be created, what it costs and what leaves the Mac; then one progress view that can
  be left and resumed.
- A failure says what to do next, in the app, and never leaves half a setup behind.
- **Update** follows the app's version by itself; **Remove** is one button that also stops the bill.
- Measured, not judged: steps and minutes from a fresh account, by someone who isn't you, as scenarios in the evals.

| Item | Today | The bar |
|---|---|---|
| **Cloudflare** | One API token made from a dashboard template and pasted; Piopio deploys the Worker, the objects' migrations, the secrets and the workers.dev name (30 §13). Built, never run from the app on the real account | The same with nothing to understand: the button opens the token page ready to confirm, Piopio picks the token up, deploys, and shows a card with cost. Later migrations and Worker updates go with app updates, unasked. A sign-in instead of a token if Cloudflare offers one to apps like Piopio (30 §13 found none; to check again) |
| **Piopio Server** | Nothing | 33 §4's Rent one: a provider token, about three minutes, no domain or DNS |
| **Connectors** | Google needs Developer setup with your own client unless the release secret is there; the app is in Testing | Connect → the service's own sign-in → done. Needs Piopio's verified apps (Google, Microsoft) and, for MCP apps, sign-in with no client to register |
| **Models** | Paste a key at first run | Sign in or paste one key; a local server found by itself; the first conversation works before any other setup |
| **Companion app** | Nothing | Scan a QR code on the Mac. No account, no address typed |
| **MCP server** | Nothing | "Add to Claude Code / Codex / Claude Desktop" writes that client's configuration; consent is one sheet in the app |
| **Telegram** | A bot token from BotFather, pasted; pairing by a link | The token is Telegram's rule and stays; everything after it is one link |
| **Computer use, Show me how** | Nothing | One permissions page that asks for each macOS permission when it's first needed and says why |
| **Install and update** | A local build | A DMG or `brew install`, updates by themselves, and the background engine restarts itself after one (today that's a manual Restart in Settings) |

**What this adds to the plan:** each wave ends with its flows run from a fresh account by a tester, and a flow that
needs you beside them doesn't pass. K1's connect flow is the first to hold to this, on the real account.

### 3.2 Local models: a gate before going out (from the user, 2026-11-24)

Not a new feature: a check that must pass. Ollama and LM Studio on this Mac are found and added with one click, and
any OpenAI-compatible server can be added by address (10 §11), but all of it was tested against a fake server only.
No real local model has run a Piopio conversation.

- **Servers:** Ollama and LM Studio (MLX and GGUF), and one LiteLLM or vLLM on another machine.
- **Models:** two or three that people really run on a Mac, in two sizes (one that fits 16 GB, one for 32–64 GB).
  Which ones is decided when the pass starts, from what is current then.
- **What to check, per model:** streaming and Stop; tool calls, where most local models fail (malformed arguments,
  calls written as text, none at all); a context window far smaller than Piopio's system prompt and tools assume,
  and compaction when it fills; images; thinking shown or hidden; background work (titles, summaries, memory) staying
  on the local model; an agent's scheduled run; cost shown as none, not unknown; nothing leaving the Mac, checked on
  the network; what happens when the server is stopped mid-answer or the model isn't loaded.
- **In the evals:** the same scenario set runs against local models, as its own column. They won't match the hosted
  ones; the result is a published list of which model does which jobs (chat, Build, agents) and Piopio saying so in
  the picker instead of failing mid-task.
- **The setup bar:** from "Ollama is installed" to a first answer with nothing typed but the message.
- **Gate:** at least one local model recommended for chat and one for Build with tools, each passing its scenarios;
  for the rest, a clear message about what they can't do.

## 4. The order

The list has dependencies, and they set the order more than priority does:

- **Web → connectors:** Google's review needs the homepage and privacy policy, and takes weeks.
- **Piopio Server and Cloudflare → MCP on the server (MS3), PAR10 and the companion app:** the phone needs a gateway
  and cloud chats. On a server those are the engine's own sessions (PS3); on the Worker they are K2's `ConversationDO`.
- **The agent host extraction (33 §8) → both clouds:** done first, the Worker and the server share one agent host and
  K4–K5 are written once.
- **Computer use → Show me how:** SH1 onward records what you do in apps through the same accessibility plumbing.
  SH0 (`/learn` and the draft card) stands alone.
- **Evals → everything:** each item's "robust" is measured there.

Durations assume one person. They are set by use and by outside parties, not by how fast code gets written.

### Wave 0 · Green (2–3 days)
- Fix `main`: `GitHub.git` makes its folder before `mkdtemp`, and the tests pass a scratch `home`.
- Register the Mac runner and set `PIOPIO_SWIFT_CI`.
- status.md up to date; this scope as GitHub milestones and issues.
- **Start the long waits:** the Apple Developer Program, a domain, the Azure account, a Hetzner account.

### Wave 1 · The ground (3 weeks)
- **Evals:** the runner and the first 25–30 scenarios (§5).
- **Local models** (§3.2): the pass with real servers, early, because what it finds changes prompts and tools.
- **The acceptance pass,** eight scenarios, and daily work in Piopio (PAR1).
- **Installable:** Developer ID, notarization on a clean Mac, Sparkle with a real update, a report button.
- **Web, first version:** homepage, privacy policy, download. Then submit Google's review and register Microsoft's app.
- **Gate:** 8 of 8, evals at a baseline, a signed 0.1.0 that someone else installed.

### Wave 2 · Finish what's half built (3–4 weeks)
- **Side conversations:** the replay set, SD3 tuned to its acceptance, SD4. **2026-11-24:** the set and its runner
  built, the rule tuned and accepted at 85% of new tasks with no false offers (24 §12); SD4 left.
- **Apps and Library:** L2, L3, L4's rest, L5.
- **Memory:** M4 and M5 (Q1 and Q3 decided 2026-11-24: past chats on and local, lessons into `AGENTS.md`). **Built 2026-11-24:** M4 with temporary chats, M5 as one `/learn` (14 §8–§9).
- **Build parity, the local part:** PAR6 hooks, PAR11 headless, PAR12, PAR7's issue → session and CI fix loop.
- **Connectors C2,** as each OAuth app is approved.
- **Image generation:** the spec, then the tool and how a picture shows and is kept.

### Wave 3 · The two clouds (9–11 weeks)
- **K1 on the account** and its gaps, as the reference the server must match.
- **PS0** (after the spike on splitting `agent-do.ts`), **PS1** Rent one, **PS2** over SSH, **PS3** chats, Build, Chromium
  and local MCP on the server.
- **MCP:** MS0–MS2 on the Mac while PS0–PS1 are built, MS3 on the server, MS4 the CLI.
- **Coding agents A5** (31 §7), built with MS0 on the same tool catalog (41 PM11). Claude Code, Codex and Antigravity
  get Piopio's tools and their own sandbox, named in the toolbar, with checkpoints around each turn. A `task` to Claude
  Code or Codex becomes a side conversation you can open, listed in Background, and `external-agents.ts` goes. Today
  such a task is a blocking one-off run, drawn as a plain tool row (seen 2026-11-25). Answer 31 §8's four CA11–CA14
  questions first.
- **Cloudflare K2** (chats), then **K4** (web, connectors signed in from the cloud) and **K5** (the Mac Bridge), both
  for the Worker and the server at once.
- **K6** the cloud browser (Browser Run) and **K7** Build in containers. Both have unverified parts in 30 §12 (cookies
  across sessions, container sizes and rates, pi-coding-agent driven from a Durable Object): a spike each before building.
- **PAR10** on the server first, then on K7: sessions from the GitHub repo, several at once.
- A security review of both front doors and of the MCP server's grants.

### Wave 4 · Hands (4–5 weeks)
- Answer 23 §10, then **computer use U0–U4.**
- **Show me how:** SH0 can come in wave 2; SH1–SH4 here.
- **PAR9,** the iOS Simulator, which the companion app's own development will use.
- **Connectors C3.**

### Wave 5 · The companion app and the launch (6–8 weeks)
- A spike first: how much of the transcript, composer and models builds for iOS as is.
- The gateway on the server and on the Worker, pairing by QR, device tokens, then the app; push; TestFlight.
- The web's docs finished, a video, the Homebrew cask, the README without "personal alpha".
- **Gate:** every item of §3 meets "robust", and two weeks of testers with no data loss and no approval that ran
  differently from what it showed.

**In all, about seven to eight months** of one person's time if nothing else is added. Waves 2, 3 and 4 don't depend on
each other, so their order can change; a beta for a few people can go out after wave 1 and be updated through the rest.

## 5. Evals of real use

Today's tests prove the plumbing with a scripted model. Nothing says whether a real model, with Piopio's prompts and
tools, gets a real job done, and that is what changes when a prompt, a tool or pi changes (pi went 1.4 → 1.6 in three
weeks).

- **The runner:** the engine headless, driven over its socket as `test/client.ts` does, against real providers, with a
  budget per run. On demand and nightly, never on every push. First slice (2026-11-25):
  [packages/engine/test/evals](../packages/engine/test/evals/README.md), four scenarios from the PAR pass.
- **The set, 25–30 scenarios to start**, each a starting state, a prompt and a check on the result, not on the words:
  - *Build:* fix a failing test in a fixture repository (the test passes, nothing else changed); a change across
    several files; a denied command with a note (the next approach differs); plan, then build; a review that finds a
    planted bug.
  - *Chat:* a question about a PDF and an image; a fact that needs web search; a project's `NOTES.md` kept by one
    conversation and used by another.
  - *Agents and automations:* "remind me at 9" becomes the right automation; a schedule fires and the run stays in
    budget; memory across days (the existing set); an agent asked by another.
  - *Connectors and browser:* tomorrow's calendar from a test account; a page read and summarized; acting on a site
    asks first.
  - *Cloud:* the same agent scenarios against the Worker and against a server.
  - *Safety:* a prompt injection in a fetched page or a repository file doesn't run a command or leak a secret; the
    sandbox holds.
- **Where the scenarios come from:** the acceptance scenarios made automatic, your own conversations from wave 1
  (what you asked and whether it worked), and every bug the beta finds, added as a case before it's fixed.
- **What it reports:** pass rate, cost and time per scenario, per model, for the three or four models you would
  recommend. Results kept in the repo as memory-eval's are.
- **How it gates:** a release, a pi upgrade or a prompt change doesn't ship below the last baseline.
- The side-conversation replay (24 SD3, about 60 real messages) joins it; the notebook routing replay can go.

## 6. Risks

- **The scope is fourteen items for one person.** It holds only if the list stays closed: one more week like
  2026-11-23 and everything moves a week.
- **Robust costs more than built.** Each item needs its eval scenarios and a week of use; plan that time, not only
  the building.
- **Subscription sign-ins in a public app.** ChatGPT sign-in and coding agents on your own plan are fine for you; check
  each provider's terms before the README offers them to everyone (33 PS7 already asks this for the server).
- **pi moves fast.** Pin it for the beta and upgrade only with the evals green.
- **macOS 27 and Apple silicon only** keeps the first audience small. That suits a beta; say it on the site.
- **Support with no telemetry.** One person, public users: the report button and the issue templates are what stand
  between you and guessing.
- **The server's agent host** is the one piece of engineering with an unknown size. Do its spike early in wave 3.
