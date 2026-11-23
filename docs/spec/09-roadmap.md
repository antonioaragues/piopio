# 09 — Roadmap

Current implementation and acceptance status: [../status.md](../status.md). The dated notes for each milestone — what was built, when, and what had not been verified — moved to [../history/milestones.md](../history/milestones.md) on 2026-11-09.

Solo developer, no deadline (X9). **Start with the easiest mode.** Each phase ends with something usable every day.

## Where things stand (2026-11-12)

A map of everything open, by track, and a proposed order. The order is a proposal to confirm; the rest of this page
(phases, backlog) is unchanged below and is the detail behind it.

**The pattern:** six areas are built and tested with the scripted model, and none has passed its real-use acceptance
(all eight boxes in [status.md](../status.md) are open). Meanwhile five specs were opened in the last ten days
(19–24), three of them with nothing built. The risk isn't missing features; it's breadth that hasn't been used.

### Tracks

| Track | Specs | Built | Left |
|---|---|---|---|
| **A · Make it real** | [status](../status.md), [acceptance](../acceptance.md) | Scripted tests, captures, one real-model team trial (20 §14) | The eight acceptance items; real providers (ChatGPT sign-in, a real Ollama/LiteLLM); real Google and Microsoft accounts; sleep/wake schedules; VoiceOver |
| **B · Agents and teams** | 06, 19, 20, 21, 26, 27 | 19 T0–T2; 20 P1–P4; 21 D1–D7 | 26 **C1–C4** (teams become a project's way of working and playbooks, decided 2026-11-17); 27 **A1–A3** (automations replace agents' schedules and projects' routines; built 2026-11-18, real-model trial A3 2026-11-19, 27 §11); the "not yet" lists of D2–D4 |
| **C · Conversations** | 18, 24, 17, 37 | 18 phases 1–3; 37 **A** (subagents beside the conversation, 2026-11-22) | 24 side conversations **SD1–SD4**; 17 **DP1** Watchdog rules and **DP4** non-blocking subagents (the router is dropped: from Home, Piopio starts side conversations across projects, 26 CL11); 37 **C** (findings as they come, decided for later; board helpers on the same row). Debate (16) was removed 2026-11-15 |
| **D · Reach** (what the model can touch) | 22, 23, 12, 10, 40, 41 | Connectors C1; providers P0–P1; browser **W1–W4** (22 §6.1, §14–16; agents W3 2026-11-23) | Computer use **U0–U4**; connectors **C2–C3**; custom skills UI (D9); skills from a demonstration **SH0–SH4** (40); Piopio as an MCP server for outside agents **MS0–MS4** (41, decided 2026-11-23, PM1–PM10); MCP Apps (D6); image generation (D11) |
| **E · Cloud and channels** | 13, 19 T3–T4, **30**, 33 | Spikes S4 and S7 (go); Telegram from the Mac; the Worker on a real account (2026-11-19: owner token at the door, a real model, a reminder fired by the alarm with nothing connected; Telegram by webhook; packages/cloud README); **30 K1** (2026-11-19: connect from Settings, agents move up and back, their conversations through the Mac's engine; 30 §13) | 30 **K1 on the account** and its gaps (30 §13); **K2** chats in the cloud; **K3** the iPhone app; K4–K7; channels as add-ons; 33 **Piopio Server** (decided 2026-11-21, PS1–PS8: PS0–PS1 right after K1 on the account, before K2; then PS2–PS3) |
| **F · Ship 1.0** | Phase 6, [releasing](../releasing.md) | Release scripts, bundled engine, update plumbing | GitHub PR and CI loop (G4–G8 and 17 DP5, built 2026-11-17); usage page (34 Overview: OV0–OV4 built 2026-11-23); notarization and Gatekeeper; Sparkle and the cask; docs site |
| **G · Memory** | 14 | M0–M3 | **M4** past chats, **M5** project lessons, **M6** Hindsight |
| **H · Small things** | Backlog below | Most of batch 1 and 2 | /goal in Chat built 2026-11-23 (32 CM4); voice (D5, 42 VC0–VC4), a composer that keeps formatting (D7), web search visible everywhere (D12), Q2 worktree wording, Q3 context files, Q4 where things run, F1 3D |
| **I · Build parity** | 05, 22 §6, 31 | Most of Claude Code's and Codex's surface (approvals, sandbox, plan, `/goal`, rewind, worktrees, diff review, PR loop, MCP, subagents); 31 A1 | **PAR1–PAR12** below (added 2026-11-20) |

### Proposed order

One build track at a time, plus Track A running beside it as use, not as building.

**Done 2026-11-17:** spec 26 C1–C2 (teams became projects' ways of working, 26 §11–§12, merged into main), side
conversations SD1–SD3 (24 §10–§11), non-blocking `task` DP4 (17 §9), the Watchdog's rules DP1 (17 §10), and the
GitHub PR loop G4–G8 with PR events DP5 (05 §8, as built), and C4, the real-model trial (26 §13): about $0.66, three
fixes. The OpenRouter key expired during it.

**Changed 2026-11-19:** the user decided the cloud's order (30 CT5): agents from the Mac app (K1), chats in the cloud
(K2), then the iPhone app (K3); then capabilities, the Mac Bridge, the cloud browser and Build (K4–K7). Cloud moved
from Later to Now.

**Now**
1. **Cloud K1 on the account** (30 §13, built 2026-11-19 and checked in workerd): redeploy the Worker, connect it from
   Settings, move a real agent up and leave the Mac off for a day. Run now, pause, approvals and the Inbox reach
   cloud agents (built the same evening). Left: approval cards in a cloud agent's chat, its memory view and trace, and
   connecting by Cloudflare token with the app deploying the Worker.
2. **Track A** beside it: do the day's real work in Piopio and tick the acceptance boxes as they pass. What breaks goes
   ahead of new features.

**Next**
3. **Piopio Server PS0–PS1** (33, decided 2026-11-21 in PS8): the image and one command, then Rent one on Hetzner.
   Then **Cloud K2** (chats in the cloud), then **K3** (the iPhone app; needs the Apple developer account for push).
4. **Browser: done.** W1–W2 built 2026-11-15 (22 §14–15), W4 (the project preview) 2026-11-21 as PAR3, W3 (agents
   browse in a profile of their own, a new site asks through Needs you, Watch on their page) 2026-11-23 (22 §16).
   Left from W1–W2: "Ask before each submit", a built-in blocked list, the folded "Browsed 4 pages" line.
5. **Build parity PAR2–PAR4** (proposed 2026-11-20, below): background processes, the project preview, agent code
   review. PAR1 is Track A.
6. **Turn context T0–T4** (38, drafted 2026-11-22 from the operational review): what changes per turn leaves the
   system prompt so the prompt cache holds on the default model. T0 first: the prefix test and the cache numbers.

**Later** (each waits for something)
- **Cloud K4–K7 and WhatsApp** (30 §10): after K3.
- **Computer use U0–U4:** after the browser (W1–W4, built) shows how often reading alone is enough.
- **Side conversations:** SD3 is built (24 §11) but untuned; its replay set comes after a week of using SD1–SD3. SD4
  (hand-off mid-task) after that.
- **Connectors C2–C3:** after Piopio's own Google and Microsoft OAuth apps exist.
- **Memory M4–M6, notarization and Sparkle:** when daily use asks for them, or when someone else is
  about to install it.

**Parked** (no spec work until something above is done): image generation, MCP Apps, the connector
marketplace, concept → 3D, rooms and side-by-side agents, cloud sandboxes, the iOS companion.

### Track I · Build parity with Claude Code and Codex (2026-11-20)

From the user's question "what does Piopio lack to have a Build experience on par with Claude Code or Codex?",
answered from the specs, status.md and the code on 2026-11-20. Most of the surface exists; what's missing is
validation, the agent checking its own work, long-running processes and cloud/parallel work. IDs are PAR1–PAR12, so they don't collide with the backlog's B, S and D.

| ID | Gap | Where it stands | Size |
|---|---|---|---|
| **PAR1** | **Proven by real use.** Daily real-model work on Piopio in Piopio and a large repository: long sessions, compaction, big diffs, transcript speed | Track A; status.md's Build acceptance is open | Use, not building |
| **PAR2** | **Background processes.** Start a command that keeps running (dev server, watcher, long test run), read its output later, stop it; the turn doesn't block. Shown in the transcript and the terminal drawer | Built 2026-11-21 (05-build §9 TM4): bash `background: true`, process_output / process_stop / process_list, drawer tabs | Done |
| **PAR3** | **Project web preview.** The pane runs the project's dev server, opens its `localhost` in a profile of its own, `browser_console` / `browser_requests` / `browser_eval` | Built 2026-11-21 (22 §6.1): the session's own ports open without asking, a profile per project, console and requests recorded in the page, Preview from the drawer | Done |
| **PAR4** | **Agent code review.** Review the session's diff, a branch or a PR (correctness first), findings as cards with file and line that become follow-ups; also someone else's PR | Built 2026-11-21 (05 §8 "Review by an agent"): a Read-only reviewer session, findings in a Review panel with Fix and Dismiss; posting to GitHub not built | Done |
| **PAR5** | **Diagnostics.** The project's compiler/type errors after an edit (LSP or the project's own check command), fed back to the agent | Built 2026-11-21 (05 §4 "Diagnostics"): the project's check (detected or set) after edits, errors in the files it changed go back to the agent, twice at most; not for coding agents | Done |
| **PAR6** | **User hooks.** Before/after a tool and when a turn ends, run a command (format after edits, block a pattern), set in Settings or the project's `.pi/` | `hooks.ts` is webhook triggers for agents; pi extensions could do it, no UI | Small–medium |
| **PAR7** | **GitHub loop, the rest.** Issue → session ("Work on #42"); an automatic fix loop for failing CI and comments (Act mode exists, one follow-up at a time); the OAuth device flow (G4) | 05 §8 Later; G4 waits on Piopio's OAuth App | Medium |
| **PAR8** | **Coding agents, the rest.** 31 A2 (Piopio's tools over MCP, switching mid-conversation) and A3 (Codex and Antigravity over ACP) | Built 2026-11-20 (A1–A3, tried with the real agents); A4 (agents and automations on a coding agent) waits on a decision | Done; A4 per 31 §7 |
| **PAR9** | **iOS Simulator.** Build, launch, screenshot and tap a Swift app from a session | 05 §10 Later | Medium |
| **PAR10** | **Cloud and parallel tasks.** Run a session on a remote machine from the GitHub repo, several at once, start and follow from the phone; "try N versions, pick one" over worktrees | 30 K7 and K3 | Large; after K2–K3 |
| **PAR11** | **Headless mode.** Run a Build prompt from a script or CI without the app (like `claude -p` / `codex exec`) | Only the pi CLI, without Piopio's settings, approvals or sandbox | Small–medium |
| **PAR12** | **Smaller items.** `/init` that writes AGENTS.md (and Q3, how context files load); create and edit skills (D9, and 40 SH0: the draft card and `/learn`) and custom subagents; a sandbox option with the network off, and `edit`/`write` under the same confinement | Open | Small each |

**Proposed order:** PAR1 all along (what breaks goes first), then PAR2 → PAR3 (together they close run → see → fix),
then PAR4. PAR5–PAR7 when daily use asks for them; PAR8 per spec 31; PAR10 after cloud K2–K3.

### Only you can do
- Register Piopio's Google and Microsoft OAuth apps (12, C1's "not done yet").
- A Cloudflare account and API token (13, before 5.2); a Telegram bot per cloud agent; for WhatsApp, a Meta app, a
  Business account and a number.
- Developer ID and notarization (Phase 0's open item).
- A real ChatGPT sign-in and a real local server (10's "not verified").

### Questions waiting for you
The table at the foot of this page says none are open; that was true on 2026-10-18. Open today:

| Where | What |
|---|---|
| 21 §6 | What a "job" is for the budget; the team estimate; agent page width; Telegram on the strip |
| 23 §10 | Attended only; browsers see-only; full control as its own milestone; keeping pictures |
| 17 §8 | DPQ1–DPQ6, most of them moot since TD2; DPQ6 (the off-track check) still stands |
| 16 §8 | DQ1–DQ3: the name, you as reviewer, remembering a result |
| 14 §6 | Q1 and Q3, which gate M4 and M5 |
| Below | Q2 worktree wording, Q3 context files, Q4 where things run, Q5 (moot: notebooks are gone) |

### Housekeeping this page needs
- **IDs collide.** "D1–D7" is 21's phases, the backlog's design items and the storage decisions; "B", "S" and "Q"
  repeat too. Proposed: backlog items become BL-n; specs keep their own prefixes.
- **The backlog mixes done and open.** Proposed: move fixed items to [history](../history/milestones.md) and keep
  only what's open.
- **The phase table stopped describing the work** after Phase 4: most of what happened since is under "outside a
  phase". Proposed: keep the table as history and make the tracks above the working view.

## Why Chat Threads first
- **Smallest UI surface:** no file system, git, diffs or safety model.
- It still builds **most of the shared foundation**: app shell, Local Engine sidecar, Engine Protocol, transcript renderer, composer, model picker, cost tracking, search.
- It exercises **pi-durable locally from day one**. That's the riskiest dependency, and Spaces and Agents both depend on it.
- Build comes next. It reuses the transcript and adds tool renderers. Spaces and Agents reuse the pi-durable runtime.

## Phases

Each phase ends with something usable every day. What each milestone delivered, with dates and what was and wasn't verified, is in [docs/history/milestones.md](../../docs/history/milestones.md); what is true today is [../status.md](../status.md).

| Phase | Scope | Acceptance | State |
|---|---|---|---|
| **0 · Foundations & spikes** | Engine sidecar (S1), native transcript (S2), OpenRouter details (S3), Cloudflare harness (S4), packaging (S5) | A Swift CLI streams from both runtimes; a DMG installs and runs | Done with the scripted model; real-provider details, notarization and Gatekeeper pending |
| **1 · Chat: threads** | 04-chat §1 (T1–T12), Quick Chat (§4), 07-shared §1 and §8, 08 app shell | A week using Piopio instead of a web chat; 1,000-message threads smooth; costs within 2% of the provider's dashboard | Built; the daily-use acceptance is open |
| **2 · Build MVP** | 05-build §1–7, §9, G1–G3, bundled approvals/checkpoints/todos/notify/subagents, MCP | Real work on Piopio in Piopio; CLI interop both ways; no approval lost across a restart; correct checkpoint restore with untracked files | Built; real-model daily work and large repositories open |
| **3 · Projects lens and Spaces** | 04-chat §2–3, global memory (07 §5), MCP in pi-durable | One real Space with 5+ topics; routing ≥ 90% on the 50-message replay; corrections learned | Built; the replay scored 49/50, daily use open |
| **4 · Local agents** | 06-agents §2–4, §6–9, §11 (local), Apple app tools, Inbox, background mode | Two agents for a week; schedules fire with the app closed; delegation with loop guards | Built; real schedules across sleep/wake, permissions and budgets open |
| **5 · Cloud agents and channels** | Cloud Engine (02 §5), deploy/rollback from the app, Telegram, WhatsApp, approvals over channels | Two agents 24/7 with the Mac off; both channels; owner approvals by button | Spikes S4 and S7 pass; nothing deployed to a real account yet |
| **6 · 1.0 polish** | GitHub PR/CI loop (G4–G8, built 2026-11-17 except the OAuth device flow), worktrees UX, usage page, export everything, accessibility pass, Sparkle + Homebrew cask, docs site | — | G4–G8 built; the rest not started |

**Spikes:** S1–S5 in Phase 0; S6 Hindsight as an opt-in memory provider; S7 the cloud harness (go); S8 the memory review. Reports are in [../spikes](../spikes), [packages/cloud](../../packages/cloud/README.md) and [14-memory](14-memory.md).

**Work that started outside a phase:** onboarding and areas ([15](15-onboarding-and-areas.md)); conversation first ([18](18-conversation-first.md), phases 1–3 built 2026-11-07); what came from deepseek-harness (Build's sandbox, `/goal`, `present_files`, earlier conversations, auto review, Claude Code and Codex as subagents); Dispatch ([17](17-dispatch.md), planned); Debate ([16](16-debate.md), built, then removed 2026-11-15); side conversations ([24](24-side-conversations.md), decided 2026-11-12, not built).

## Backlog from the v2 review (2026-10-22)
Noted by the user after using the v2 redesign. Not scheduled into a phase yet.

**Bugs**
- B1 · The agent's icon (avatar) picker looks broken. **Fixed 2026-10-22:** a tile that opens a grid of common emoji, with a field for any other and None.
- B2 · The Questions UI ("The agent asks") draws each option as a one-line capsule that doesn't wrap, so long answers run past the card's right edge and over the transcript. Options should wrap inside the card. Screenshot: [docs/design/feedback/questions-overflow.png](../design/feedback/questions-overflow.png). **Fixed 2026-10-22:** a long answer wraps in a rounded box no wider than the card; short ones stay capsules.

**Small changes**
- S1 · After you answer through the Questions UI, the chat shows nothing of it. Show the question and the chosen answer inline in the transcript, as Cursor and Claude do. **Fixed 2026-10-22:** an answered question stays out of the folded activity line and shows as "The agent asked … ↳ your answer".
- S2 · Thinking lines read "Thought x words": drop the word count ("Thought for 4s" or just "Thought"). **Fixed 2026-10-22:** it reads "Thought" (pi doesn't time thinking separately).

**Plan mode**
- P1 · Show the plan inline in the transcript, not in a pop-up. **Done 2026-10-22:** the plan is its own card in the transcript with Keep planning… / Edit… / Approve and build; above the composer only a one-line bar remains (with ⌘↩). **Changed 2026-11-21** ([plan-flow](../design/plan-flow/README.md)): the card has no buttons; the composer's tray is the one place that answers, an answered plan folds to one line, and the side panel's Plan shows the proposal.
- P2 · Give it real formatting (headings, numbered steps, checkboxes, code) instead of flat text. **Done 2026-10-22:** summary, numbered steps in circles with inline Markdown, the files it expects to change and its risks (`propose_plan` gained `files` and `risks`); once answered it says Approved, Approved with your edits, or Sent back with your note.
- P3 · Let the user edit the plan before approving it. **Done 2026-10-22:** Edit… opens the plan to change, reorder, remove or add steps; Approve and build sends your version and the agent builds it instead of its own.

**To design further**
- D1 · Connected apps (Gmail, Calendar, …). Open question: where they live. Per agent (Setup › Abilities), per project, or app-wide in Settings with each agent or project choosing which to use? Overlaps with MCP servers and Mac apps (4.5). **Spec 2026-10-23:** [12-connectors.md](12-connectors.md): connect once, use in every chat, changes ask first; milestone C1 is Google Calendar and Outlook. **C1 built 2026-10-23** (needs Piopio's own Google/Microsoft OAuth apps registered; notebooks not wired yet).
- D2 · More model providers beyond OpenRouter: ChatGPT/Codex subscription and OpenAI API first, several connected at once, reusing pi's own provider and auth infrastructure. Requirements: [10-model-providers.md](10-model-providers.md). **P0 built 2026-10-22** (10-model-providers §11); a real ChatGPT sign-in isn't verified yet. Related: "direct providers + local models + subscription logins" in Later.
- D3 · Truly proactive agents: agents that don't need you to chat with them. They observe their environment (mail, calendar, files, Mac apps), decide when something matters, ask you questions and act. Builds on 4.3 proactivity (schedules, heartbeat, triggers).
- D4 · Create agents by chatting: describe what you want and Piopio drafts the definition (instructions, schedule, abilities, people) for you to confirm, replacing or complementing the form in the new agent sheet.
- D5 · Voice input in the composers (dictation, push to talk). **Spec 2026-11-23:** [42-voice.md](42-voice.md), dictation (VC1), files and voice notes (VC2), talk mode (VC3), cloud voices (VC4) after a VC0 spike on Apple's transcriber; not built.
- D6 · MCP Apps support: MCP servers that return interactive UI, rendered in the transcript. **Spec 2026-11-16:** drawn in the visual card of [25-visuals.md](25-visuals.md) (milestone V4). Not built yet: pi's MCP extension drops tool `_meta` and `ui://` resources (25 §16).

**Future idea**
- F1 · Concept → simple 3D visualization: say a concept and Piopio shows it in 3D (reference: https://x.com/elvar_official/status/2111831136171151589). Open question: a skill, a mode, or its own item type in the sidebar. **2026-11-16:** a visual with three.js, [25-visuals.md](25-visuals.md); a button of its own later (25 §10).

### Second batch (2026-10-22)

**Bugs**
- B3 · The model picker in a notebook's settings sheet looks broken: the sheet forces it into a 420×380 frame (`SpaceViews.swift`, `.popover(item: $picking)`), but the v2 picker lays out at 760×520, so its list and detail pane are squeezed and clipped. **Fixed 2026-10-22:** the fixed frame is gone; the picker opens at its own 760×520 size.

**Small changes**
- S3 · Follow-up suggestion chips are cut to one line (`FollowUps` in `ChatExtras.swift`, `lineLimit(1)`), so long ones can't be read. Let them wrap like the Questions UI options (B2), or at least show the full text as a tooltip. **Fixed 2026-10-22:** long suggestions wrap in a rounded box no wider than the column, and the full text shows on hover.
- S4 · Attach folders as well as files from the composer's +. Today the file panel only accepts files (`Composer.swift`, `canChooseDirectories = false`); @-mentions already reach folders in Build. **Fixed 2026-10-22:** the + accepts folders. In Build a folder goes in as an @path the agent reads; elsewhere its first 20 readable files are attached, skipping hidden files, dependencies and build output.

**To design further**
- D7 · A composer that keeps formatting: pasting Markdown (or rich text) today loses it. Show it formatted while typing, or at least keep the Markdown source intact and preview it.
- D8 · A file viewer for Markdown (rendered), PDF, images and more, used everywhere: chat attachments, notebook files, Build's Files tab. Build's `FileViewer` (`BuildFiles.swift`) showed files as text. **Built 2026-11-05** (`FileView.swift`): one viewer shows Markdown rendered in a reading column (Rendered | Source), PDFs as continuous pages with the page count, images fitted (double-click for actual size, pixel size shown), code and text with line numbers, highlighting and the target line marked, and anything else through Quick Look. Used by Build's file viewer (Edit and Open in an editor stay for text; PDFs and images get Reveal in Finder and Open), a folder chat's preview panel, and a notebook's files (the Files sheet and the right column's rows now open the file). Files you send in a conversation (chats, notebooks, agents, debates) open too: the engine keeps a copy in `<home>/attachments/<conversation>/`, the original when the app says where it is on this Mac (a PDF stays a PDF, an image keeps its full size) and otherwise what was sent; a branched chat copies them and deleting the conversation removes them. Their chips in the transcript and the rows in a chat's Summary open the viewer. Files sent before this have no copy, so their chips don't open.
- D9 · Custom skills: create, edit and enable skills from the app. Today skills are read from `~/.pi/agent/skills` and enabled pi packages (`tools/chat-resources.ts`), offered as `/skill:name`, with no UI to make or manage them.
- D10 · Computer use: let agents and chats drive the Mac's screen (screenshots, clicks, typing), with approvals. Builds on Mac apps as tools (4.5). **Spike done 2026-10-22:** [11-computer-use.md](11-computer-use.md) recommends accessibility-first tools built on Peekaboo's Swift automation kit, reached through `app.tool`. **Design drafted 2026-11-12:** [23-computer-use.md](23-computer-use.md) (Mac apps) and [22-browser.md](22-browser.md) (websites, in a built-in browser that is also Build's web preview).
- D11 · Image generation in Chat (and as an agent ability), through a provider that offers it (see D2).
- D12 · Web search: Chat has it already (OpenRouter web plugin, CQ3) and agents have `web_search`. Check it's on and visible in Build sessions, notebooks and the composer, and make it obvious when a turn searched the web.
- D13 · Visuals in the conversation: the model shows charts, diagrams and UI options as live HTML in the transcript, and `.html` files open rendered (reference: T3 Code, https://x.com/itssotsot/status/2122282435971092760). **Spec 2026-11-16:** [25-visuals.md](25-visuals.md): one sandboxed web view card with no network, Piopio's tokens, a click that answers; saved visuals are files; milestones V1–V4. Also covers D6 and F1. **V1 built 2026-11-16:** `.html` files open rendered, offline, in the file viewer (25 §13). **V2 built 2026-11-16:** `show_visual` draws live, sandboxed HTML cards in chats, Build and agents' chats, with bundled Chart.js, d3, three.js and KaTeX, Open in a sheet, Save…, and `piopio.send` (25 §14). **V3 built 2026-11-16:** the app draws each visual first and tells the model its height, script errors and failed loads (and with `look`, a picture); `piopio.prefill` (25 §15). **V4 built 2026-11-16 (export, Telegram):** exports carry visuals (HTML frames, Markdown pictures), saved visuals work in any browser, Telegram gets a picture of each; agents now actually get the tool. MCP Apps (D6) waits on a decision: patch pi's MCP extension or connect separately (25 §16).

**Open questions**
- Q1 · **Resolved 2026-10-24 by chat v3 (docs/design/chat-v3):** checkpoint dividers are gone; Rewind (chat and files, or chat only) is on each of your messages and in the inspector's Turns, and Fork is on each answer. **Checkpoints vs fork.** Today a checkpoint is a snapshot of the project's *files* taken before each turn that writes (a shadow git dir, 05-build §7, `checkpoints.ts`); "Restore to here" rewinds the files, not the conversation. Fork (pi's session tree, BR6) branches the *conversation*. Claude Code's rewind and Cursor's "restore checkpoint" put both on each message: hover a message → restore code, conversation, or both. Proposal to evaluate: drop the separate checkpoint items from the transcript and the inspector timeline, put Restore on each of your messages with those three choices, and draw forks as a small branch marker on the message they start from.
- Q2 · **"Worktree" at the top of a Build session.** A worktree is a second working copy of the repo on its own branch (BP5), so several sessions can change the same project at once without stepping on each other; when the session ends you merge, open a PR, keep or discard it. The word is git jargon: consider "Separate copy (branch piopio/…)" in the header and new-session sheet, with worktree in the tooltip.
- Q3 · **How pi uses context files and skills.** To verify against pi's docs and write down in 07-shared-resources: which files pi reads into the prompt (AGENTS.md and CLAUDE.md from the project and its parents, `~/.pi/agent/AGENTS.md`, SYSTEM.md / APPEND_SYSTEM.md?), how skills (`SKILL.md` folders) load on demand, and whether anything like OpenClaw's SOUL.md exists or should exist for agents (an agent's persona today is its Setup › Instructions). The app reads AGENTS.md/CLAUDE.md only to show it per project (`projects.ts`).
- Q5 · **Where a notebook's Files live.** Today Files is a button in the notebook's toolbar that opens a sheet. Options: the left sidebar (under the notebook, like a project's sessions), or the notebook's right-hand panel, next to Progress and Memory. The right panel looks like the better fit: it already holds what every topic shares, and the left sidebar stays a list of places.
- Q4 · **Decided 2026-11-19 in [30-cloud-target.md](30-cloud-target.md)** (CT1–CT6: a location chip; agents start on the Mac and move up; an iPhone app; capabilities by place; phases K1–K7). **Where things run.** Claude and Codex let you pick, per chat, whether it runs on this Mac or in the cloud. Research per kind: Build sessions (this Mac, a worktree, or a cloud machine from the GitHub repo), chats and notebooks (this Mac or the cloud engine), agents (this Mac or a Durable Object, Phase 5). Decide whether the choice lives in the composer, the new-session sheet, or per project/agent, and how a running item moves between them. Related: "cloud Threads/Spaces" and "cloud Build sessions" in Later.

## Later (unordered)
Mac Bridge · cloud Threads/Spaces · iOS companion · direct providers + local models + subscription logins · artifacts/canvas (→ [25-visuals.md](25-visuals.md): saved visuals are files) · code execution in Chat · email/Slack/Discord channels · group chats & agent rooms · cloud Build sessions · web preview · semantic search.

---

## Open questions

**None open** as of 2026-10-18. The resolved ones are below. New questions found during the Phase 0 spikes get added here.

| ID | Question | Decision |
|---|---|---|
| D5 | License | MIT |
| OQ1 | Support Intel Macs? | No, Apple silicon only |
| CQ1 | How routed topic replies appear in Main | Link card only (04-chat S1) |
| CQ2 | Suggest moving threads into a matching Space? | Yes, ships with Spaces (04-chat S11) |
| CQ3 | Web search provider | OpenRouter web plugin + optional key |
| BQ1 | Default approval mode | Auto-edit |
| BQ2 | Worktree location | App support folder |
| BQ3 | Default-on extensions | todos, notify, subagents. Plan mode off |
| AQ1 | Telegram | One bot per agent |
| AQ2 | WhatsApp | One number for a single front agent in v1 |
| AQ3 | Identity across channels | One conversation per person |
| AQ4 | Converge Spaces and Agents? | No, kept separate |
