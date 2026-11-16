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
| **B · Agents and teams** | 06, 19, 20, 21 | 19 T0–T2; 20 P1–P4; 21 D1–D7 | The "not yet" lists of D2–D7; the real-model trial |
| **C · Conversations** | 18, 24, 17 | 18 phases 1–3 | 24 side conversations **SD1–SD4**; 17 **DP1** Watchdog rules and **DP4** non-blocking subagents (the rest of 17 became teams, TD2). Debate (16) was removed 2026-11-15 |
| **D · Reach** (what the model can touch) | 22, 23, 12, 10 | Connectors C1; providers P0–P1; browser **W1–W2** (22 §14–15) | Browser **W3–W4**; computer use **U0–U4**; connectors **C2–C3**; custom skills UI (D9); MCP Apps (D6); image generation (D11) |
| **E · Cloud and channels** | 13, 19 T3–T4 | Spikes S4 and S7 (go); Telegram from the Mac | 13 **5.1–5.5**: deploy, Telegram by webhook, Mac Bridge, WhatsApp. Nothing is on a real account |
| **F · Ship 1.0** | Phase 6, [releasing](../releasing.md) | Release scripts, bundled engine, update plumbing | GitHub PR and CI loop (G4–G8, which 17 DP5 and 24's Create PR wait for); usage page; notarization and Gatekeeper; Sparkle and the cask; docs site |
| **G · Memory** | 14 | M0–M3 | **M4** past chats, **M5** project lessons, **M6** Hindsight |
| **H · Small things** | Backlog below | Most of batch 1 and 2 | Voice input (D5), a composer that keeps formatting (D7), web search visible everywhere (D12), Q2 worktree wording, Q3 context files, Q4 where things run, F1 3D |

### Proposed order

One build track at a time, plus Track A running beside it as use, not as building.

**Now**
1. **Finish spec 21: D5, D6, D7,** then its real-model trial. It's mid-flight: the agent pages follow the new design
   and the team pages don't yet.
2. **Track A alongside:** do the day's real work in Piopio and tick the acceptance boxes as they pass. What breaks
   goes ahead of new features.

**Next**
3. **Side conversations SD1–SD2** (24) with **Watchdog DP1** (17). Neither needs anything unbuilt, both help daily
   use at once, and the report bridge they add also serves teams.
4. **Browser W4** (22, WebKit in the app; decided 2026-11-15). **W1 and W2 built 2026-11-15** (22 §14–15): the model
   reads pages and, asking per site, clicks and types in a Browser panel; the interim Playwright browser is gone.
5. **GitHub PR loop G4–G8** (Phase 6). It closes Build's loop and unblocks Create PR on team, worktree and
   side-conversation cards.

**Later** (each waits for something)
- **Cloud 5.1–5.5 and WhatsApp:** for agents proven locally first (Track A's schedule item) and your Cloudflare
  account.
- **Browser W2–W3, computer use U0–U4:** after W1 shows how often reading alone is enough.
- **Side conversations SD3–SD4:** after a week of SD1–SD2 by hand, which produces the replay set.
- **Connectors C2–C3:** after Piopio's own Google and Microsoft OAuth apps exist.
- **Memory M4–M6, notarization and Sparkle:** when daily use asks for them, or when someone else is
  about to install it.

**Parked** (no spec work until something above is done): image generation, voice, MCP Apps, the connector
marketplace, concept → 3D, rooms and side-by-side agents, cloud sandboxes, the iOS companion.

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
| **6 · 1.0 polish** | GitHub PR/CI loop (G4–G8), worktrees UX, usage page, export everything, accessibility pass, Sparkle + Homebrew cask, docs site | — | Not started |

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
- P1 · Show the plan inline in the transcript, not in a pop-up. **Done 2026-10-22:** the plan is its own card in the transcript with Keep planning… / Edit… / Approve and build; above the composer only a one-line bar remains (with ⌘↩).
- P2 · Give it real formatting (headings, numbered steps, checkboxes, code) instead of flat text. **Done 2026-10-22:** summary, numbered steps in circles with inline Markdown, the files it expects to change and its risks (`propose_plan` gained `files` and `risks`); once answered it says Approved, Approved with your edits, or Sent back with your note.
- P3 · Let the user edit the plan before approving it. **Done 2026-10-22:** Edit… opens the plan to change, reorder, remove or add steps; Approve and build sends your version and the agent builds it instead of its own.

**To design further**
- D1 · Connected apps (Gmail, Calendar, …). Open question: where they live. Per agent (Setup › Abilities), per project, or app-wide in Settings with each agent or project choosing which to use? Overlaps with MCP servers and Mac apps (4.5). **Spec 2026-10-23:** [12-connectors.md](12-connectors.md): connect once, use in every chat, changes ask first; milestone C1 is Google Calendar and Outlook. **C1 built 2026-10-23** (needs Piopio's own Google/Microsoft OAuth apps registered; notebooks not wired yet).
- D2 · More model providers beyond OpenRouter: ChatGPT/Codex subscription and OpenAI API first, several connected at once, reusing pi's own provider and auth infrastructure. Requirements: [10-model-providers.md](10-model-providers.md). **P0 built 2026-10-22** (10-model-providers §11); a real ChatGPT sign-in isn't verified yet. Related: "direct providers + local models + subscription logins" in Later.
- D3 · Truly proactive agents: agents that don't need you to chat with them. They observe their environment (mail, calendar, files, Mac apps), decide when something matters, ask you questions and act. Builds on 4.3 proactivity (schedules, heartbeat, triggers).
- D4 · Create agents by chatting: describe what you want and Piopio drafts the definition (instructions, schedule, abilities, people) for you to confirm, replacing or complementing the form in the new agent sheet.
- D5 · Voice input in the composers (dictation, push to talk).
- D6 · MCP Apps support: MCP servers that return interactive UI, rendered in the transcript. **Spec 2026-11-16:** drawn in the visual card of [25-visuals.md](25-visuals.md) (milestone V4).

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
- D13 · Visuals in the conversation: the model shows charts, diagrams and UI options as live HTML in the transcript, and `.html` files open rendered (reference: T3 Code, https://x.com/itssotsot/status/2122282435971092760). **Spec 2026-11-16:** [25-visuals.md](25-visuals.md): one sandboxed web view card with no network, Piopio's tokens, a click that answers; saved visuals are files; milestones V1–V4. Also covers D6 and F1. **V1 built 2026-11-16:** `.html` files open rendered, offline, in the file viewer (25 §13).

**Open questions**
- Q1 · **Resolved 2026-10-24 by chat v3 (docs/design/chat-v3):** checkpoint dividers are gone; Rewind (chat and files, or chat only) is on each of your messages and in the inspector's Turns, and Fork is on each answer. **Checkpoints vs fork.** Today a checkpoint is a snapshot of the project's *files* taken before each turn that writes (a shadow git dir, 05-build §7, `checkpoints.ts`); "Restore to here" rewinds the files, not the conversation. Fork (pi's session tree, BR6) branches the *conversation*. Claude Code's rewind and Cursor's "restore checkpoint" put both on each message: hover a message → restore code, conversation, or both. Proposal to evaluate: drop the separate checkpoint items from the transcript and the inspector timeline, put Restore on each of your messages with those three choices, and draw forks as a small branch marker on the message they start from.
- Q2 · **"Worktree" at the top of a Build session.** A worktree is a second working copy of the repo on its own branch (BP5), so several sessions can change the same project at once without stepping on each other; when the session ends you merge, open a PR, keep or discard it. The word is git jargon: consider "Separate copy (branch piopio/…)" in the header and new-session sheet, with worktree in the tooltip.
- Q3 · **How pi uses context files and skills.** To verify against pi's docs and write down in 07-shared-resources: which files pi reads into the prompt (AGENTS.md and CLAUDE.md from the project and its parents, `~/.pi/agent/AGENTS.md`, SYSTEM.md / APPEND_SYSTEM.md?), how skills (`SKILL.md` folders) load on demand, and whether anything like OpenClaw's SOUL.md exists or should exist for agents (an agent's persona today is its Setup › Instructions). The app reads AGENTS.md/CLAUDE.md only to show it per project (`projects.ts`).
- Q5 · **Where a notebook's Files live.** Today Files is a button in the notebook's toolbar that opens a sheet. Options: the left sidebar (under the notebook, like a project's sessions), or the notebook's right-hand panel, next to Progress and Memory. The right panel looks like the better fit: it already holds what every topic shares, and the left sidebar stays a list of places.
- Q4 · **Where things run.** Claude and Codex let you pick, per chat, whether it runs on this Mac or in the cloud. Research per kind: Build sessions (this Mac, a worktree, or a cloud machine from the GitHub repo), chats and notebooks (this Mac or the cloud engine), agents (this Mac or a Durable Object, Phase 5). Decide whether the choice lives in the composer, the new-session sheet, or per project/agent, and how a running item moves between them. Related: "cloud Threads/Spaces" and "cloud Build sessions" in Later.

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
