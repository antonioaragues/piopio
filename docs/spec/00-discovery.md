# Piopio: Discovery & Open Questions

> Status: **Answered** (2026-10-18). The decisions are recorded in [README.md](README.md#decisions-log), and the detailed spec lives in the numbered docs next to this one. This file is kept as the historical record of the discovery round.
> Questions not answered explicitly took the ⭐ proposal.

---

## 1. Product framing (my synthesis)

**Piopio** (working name) is a native macOS app with a front-end for the **pi** family of harnesses:

| Mode | One-liner | Primary harness | Runs where |
|---|---|---|---|
| **Build** | Agent-first dev environment (Claude Code desktop / Codex app / Cursor agent pane) | `pi-coding-agent` (SDK) | Local Mac (later: cloud sandboxes) |
| **Chat** | Conversations with an assistant: loose threads, folder projects, and "Spaces" with an organizer agent | `pi-durable` | Local, optionally synced to the cloud |
| **Agents** | Persistent personal agents you build, reachable on channels (WhatsApp, Telegram…), running 24/7 | `pi-durable` on Cloudflare Durable Objects | Cloud (with a local dev/test loop) |

**Models:** any model, starting with OpenRouter (BYOK).

### Key insight that shapes the design
Pi Durable's data model fits two of your modes almost one-to-one:
- A **session** holds **many conversations**. You can fork a conversation from any committed entry, and tasks or subagents can own conversations. A session also has a doc store (`tx.doc`).
- That is exactly your **Chat project type 2** ("one session, many topic threads, an agent organizing them"). It also fits an **Agent**: one DO = one agent, with conversations per channel/contact, a scheduler, and a durable inbox.

So my proposal: **Build uses pi (coding agent). Chat and Agents both use pi-durable.** A Chat Space and an Agent are close relatives. The main difference is where they run and who can talk to them.

---

## 2. Proposed architecture (to challenge)

```
┌──────────────────────── macOS app (SwiftUI) ────────────────────────┐
│  Build  │  Chat  │  Agents  │  Settings / Models / Skills / MCP      │
└───────────────┬──────────────────────────────────────┬──────────────┘
                │ Engine Protocol (JSON-RPC over WS)    │ same protocol
       ┌────────▼─────────┐                   ┌────────▼──────────────┐
       │  Local Engine     │                   │  Cloud Engine          │
       │  (bundled Node    │                   │  (Cloudflare Worker +  │
       │   sidecar daemon) │                   │   Durable Objects)     │
       │  • pi SDK (Build) │                   │  • pi-durable PiHarness│
       │  • pi-durable +   │                   │  • channel webhooks    │
       │    SQLite (Chat)  │                   │  • alarms / schedules  │
       └───────────────────┘                   └────────────────────────┘
```

- **Swift app = thin client.** All agent logic lives in TypeScript, because pi is TypeScript. We bundle a Node runtime inside the `.app` as a **sidecar daemon**, launched via `SMAppService`/launchd so Chat and local Agents keep running when the window is closed.
- **One Engine Protocol** for local and cloud. The UI doesn't care where a session runs. That makes "move this to the cloud" a real feature and not a rewrite.
- **Interop with the pi CLI:** Build sessions read and write the standard pi session files (`~/.pi/agent/sessions/`). You can start in the terminal and continue in the app, or the other way around.
- **Distribution outside the Mac App Store** (notarized DMG + Sparkle). The MAS sandbox would block spawning shells in arbitrary folders.

### Technical risks I see up front
1. **pi-durable is experimental** and `PiHarness` is beta. Missing today: no tool-approval step, sessions can't be deleted, event streams can't resume from a cursor, and model streams over 15 min can be cut off. We'll need an adapter layer and should expect churn.
2. **Workers ≠ a computer.** On Cloudflare, agents get a durable virtual filesystem and sandboxed JS `exec`, but no real bash. Anything that needs a real machine needs a different approach (see A7).
3. **WhatsApp is the hardest channel.** The official Business Cloud API needs Meta business verification, a dedicated number, and 24h-window/template rules. Unofficial libraries break ToS and get numbers banned.
4. **pi extensions that render TUI components** can't be shown in a native UI. We need a policy on which extension capabilities we support (see B7).

---

## 3. Questions

### X — Cross-cutting / product

**X1. Who is this for?**
a) Just me (personal tool) · b) Open-source project for power users · c) Commercial product (accounts, billing, hosted cloud)
⭐ **b now, keep c possible.** BYOK, BYO-Cloudflare-account, no Piopio backend in v1. The choice drives auth, multi-tenancy and whether *we* host the cloud engine.

**X2. "Native" means:**
a) SwiftUI/AppKit, Mac-only · b) Tauri/Electron, cross-platform later
⭐ **a.** You said native, and it's the differentiator against Electron-based competitors. Minimum target: **macOS 26 (Tahoe)** for Liquid Glass and the latest SwiftUI. Do you agree, or do you need macOS 15?

**X3. Name.** Is "Piopio" the product name or just the folder?

**X4. Mode boundaries.** How separate are the three modes?
a) Three separate "apps" behind a mode switcher · b) One sidebar with shared global search, command palette, notifications, and shared resources (models, skills, MCP, memory)
⭐ **b.** Modes are lenses over one data model. A Build project and a Chat folder project can be **the same folder** (see C2).

**X5. iPhone / remote access.** Is an iOS companion in scope at any point?
⭐ **Not in v1, but design for it.** Cloud-engine sessions are reachable from anywhere by design. A later iOS app is mostly UI. In the meantime the Agents channels (Telegram/WhatsApp) *are* your mobile access.

**X6. Shared resources: global or per mode?** Skills, prompt templates, MCP servers, memory, custom instructions.
⭐ **Global library, opted in per project/agent.** Defined once, enabled where needed.

**X7. Sync between Macs?** (iCloud / your own cloud)
⭐ **No in v1.** Cloud-engine sessions are naturally shared. Local stays local.

**X8. Team / sharing.** Share a session, agent or Space with someone else?
⭐ **No in v1.** Exporting a session (markdown/HTML) is enough.

**X9. Team & timeline.** Is it you alone? Is there a target date for a first usable version? I'll use this to size the phases.

---

### M — Models

**M1. Providers in v1.**
⭐ **OpenRouter only in v1** (pi-ai supports it), with the abstraction ready for direct providers. **v1.x:** Anthropic/OpenAI/Google direct, local (Ollama / LM Studio), and **subscription login** (Claude Pro/Max, ChatGPT) where pi supports it. Do you care about subscription logins? Many power users want them for cost reasons.

**M2. Model selection UX.**
⭐ A searchable picker fed by OpenRouter's `/models` (price, context, capabilities: tools/vision/reasoning), plus favorites and per-mode defaults (e.g. Build: a strong coding model, Chat: a fast one, Agents: a cheap one). Switching model mid-session is allowed. Thinking level is set per session.

**M3. Cost visibility.**
⭐ Live token and $ meter per session, rolled up per project/agent, with optional monthly budget alerts per agent. Important for 24/7 cloud agents.

**M4. Key storage.**
⭐ macOS Keychain locally. Pushed to Worker secrets when deploying an agent. Never stored in plain files.

---

### B — Build mode

**B1. What kind of tool?**
a) **Agent-first** (chat + diffs + file viewer + terminal; open files in your editor) · b) **Editor-first** (full code editor with agent pane, like Cursor)
⭐ **a.** A full editor is a huge project and Xcode/VS Code/Zed already exist. We'd add a great **diff/review view**, a read-only syntax-highlighted file viewer with quick edits, an integrated terminal, and "Open in <Editor>".

**B2. Organization.** Project = folder (usually a git repo) → sessions inside. Sessions show status (running / waiting for you / done / error).
⭐ Plus **parallel sessions via git worktrees** (one worktree per session, optional), like Claude Code desktop and Codex. Agree?

**B3. GitHub scope for v1.**
⭐ Auth via `gh` CLI if present, otherwise GitHub OAuth device flow. v1: clone, branch, commit, push, **create PR**, see **CI status**, read **review comments** and let the agent address them. Later: issues → session ("work on issue #42"), PR review mode, auto-fix CI.
Do you also want GitLab/Bitbucket at some point?

**B4. Permissions & safety.** pi is deliberately "YOLO": no permission prompts.
a) Keep YOLO · b) Optional approval gates (per tool / per command pattern) · c) Plus OS-level sandboxing (Seatbelt / container)
⭐ **b, with modes:** *Ask* / *Auto-edit (ask for bash)* / *Full auto*. Implemented as a pi extension so it also works in the CLI. **c** later.

**B5. Checkpoints / undo.**
⭐ Snapshot the working tree on every agent turn (shadow git refs), with "revert to this point". Essential once agents edit freely.

**B6. Pi CLI interop.** Share sessions with terminal `pi`? (see §2)
⭐ **Yes.** Agree?

**B7. pi extensions & packages.**
⭐ Support installing pi packages (extensions, skills, prompts, themes). Tools, hooks and skills work fully. **Custom TUI widgets don't render.** We can define a small "native UI hint" spec later. OK to ship with that limitation?

**B8. Cloud build sessions** (run the coding agent remotely so it keeps going with the Mac closed: Cloudflare Sandbox/Containers, or an SSH devbox).
⭐ **Post-v1**, but keep sessions engine-agnostic. Is this important to you early?

**B9. Subagents / plan mode / todos.** pi core excludes them on purpose; they come as extensions.
⭐ Ship a curated default extension set (plan mode, todos, subagents) that can be turned off. Or do you want to stay pure-pi by default?

**B10. Previews.** Built-in browser preview for web apps, and/or iOS Simulator integration?
⭐ Web preview in v1.x. Simulator later.

---

### C — Chat mode

**C1. Three containers. Confirm my reading:**
1. **Threads**: loose conversations, no project.
2. **Folder projects**: a folder, with sessions inside. The agent can read and write the files.
3. **Spaces** (proposed name for your "Claude-style" type): a single pi-durable session. You talk in it, and an **organizer agent** creates, forks and routes **topic conversations**, and maintains shared knowledge.

**C2. Folder project vs Build project.** What's the difference for you?
⭐ My take: **same entity, different lens.** A folder project in Chat is a knowledge/docs folder (notes, research, PDFs) with a chat-first UI and no git/diff/terminal by default. You can open any folder in either mode. Agree, or should they be fully separate?

**C3. Spaces: how does the organizer work?** This is the most ambiguous part. Options:
a) **Front door:** you always write in one main conversation. The organizer decides whether to answer, route to an existing topic, or spin up a new topic conversation. Topics show up in the sidebar and you can jump into any of them directly.
b) **Librarian:** you create topics yourself. The organizer runs in the background, keeping a Space summary/knowledge doc, linking related topics, suggesting merges and splits.
c) Both.
⭐ **c**, with **a** as the default entry point. Also: can topics talk to each other ("ask the Budget topic what we decided")? ⭐ Yes, via an organizer tool.

**C4. Space knowledge.** Can a Space hold files and documents (like Claude Project knowledge) plus custom instructions?
⭐ Yes: instructions + attached files + an organizer-maintained "Space memory" doc that the user can view and edit.

**C5. Chat tools in v1.** Pick:
web search · web fetch · file/image attachments · image generation · code execution (sandboxed) · **artifacts/canvas** (rendered HTML/markdown docs) · MCP connectors · memory across chats
⭐ v1: web search, web fetch, attachments (PDF/images), MCP, cross-chat memory (opt-in). v1.x: artifacts/canvas, code execution.

**C6. Where do chats run?**
⭐ Local engine by default. A Space or thread can be **"moved to cloud"** so it's reachable from channels/other devices. Is that in v1 for Chat, or only for Agents?

**C7. Quick chat.** Global hotkey with a floating mini-window (Spotlight-style) that starts a thread?
⭐ Yes. Cheap to build and high value.

---

### A — Agents mode

**A1. Inspiration check.** What exactly do you like about the Grok bot and ChatGPT examples you mentioned? Persistent persona? Proactive check-ins? Living inside messaging apps? Scheduled tasks? Each one shifts the priorities.

**A2. What defines an Agent?**
⭐ Name, avatar, persona/instructions, model, **skills & tools** (incl. MCP), **memory** (durable, user-visible), **schedules** (cron and one-off reminders), **triggers** (webhooks, email-in, RSS…), **channels**, **access list** (who can talk to it), and a budget.
Should agents be authorable by **talking to a "builder" agent** ("make me an agent that tracks my gym sessions")?
⭐ Yes, plus a form editor. Both write the same definition (a versioned file in a repo-like format, so you can diff and roll back).

**A3. Channels: priority order?** Candidates:
Telegram (easiest, free, bots are first-class) · WhatsApp (Business Cloud API) · Slack · Discord · Email (in/out) · SMS (Twilio) · iMessage (**Mac-only**, can't run on Cloudflare) · In-app · Web widget
⭐ **v1: In-app + Telegram + WhatsApp (official API).** v1.x: Email, Slack, Discord. iMessage only via the Mac bridge (A7).

**A4. WhatsApp approach.**
a) Official Business Cloud API (needs a Meta Business account and a dedicated number; reliable) · b) Unofficial (Baileys-style, uses your personal number; fragile, ban risk)
⭐ **a only.** We guide the user through setup. OK?

**A5. Who talks to an agent?**
a) Only me · b) Me + allowlisted people (family, friends) · c) Public (anyone with the link/number)
⭐ **b**, with per-contact conversations and memory isolation. One agent in a **group chat**? ⭐ v1.x.

**A6. Deployment target.**
⭐ The **user's own Cloudflare account**: the app deploys a Worker + DO via the Cloudflare API with a token the user provides, one DO per agent. Abstract a `DeploymentTarget` interface so "similar" platforms can come later. Alternative: **we** run a hosted Piopio Cloud (that's X1-c). Which?

**A7. Agents that need a real computer.** Cloud agents get a durable filesystem + sandboxed JS + HTTP tools + MCP, but no local machine.
⭐ **Mac Bridge (v1.x):** when your Mac is online, a cloud agent can call tools exposed by the local engine (files, iMessage, Calendar/Reminders via EventKit, shell with approval). When the Mac is offline those tools are unavailable and the agent knows it. Plus optional Cloudflare Sandbox/Containers for heavier jobs. Interested?

**A8. Local vs cloud lifecycle.**
⭐ Agents are **authored and tested locally** (same pi-durable code on the local engine, with a "simulate channel" chat), then **Deploy** pushes the definition to the cloud. The cloud is the source of truth while deployed. The app shows live conversations, logs, runs and costs from the cloud.

**A9. Proactivity & safety.** Agents can message you first (reminders, digests, alerts). Guardrails?
⭐ Per-agent quiet hours, a rate limit on outbound messages, a budget cap, and "require approval" for sensitive actions (send email, pay, post publicly). That approval arrives as a push notification or a channel message with buttons.

**A10. Agent-to-agent.** Can agents delegate to each other or share memory?
⭐ v1.x: agents can call each other as tools. Memory stays isolated unless shared explicitly.

---

### D — Data, privacy, ops

**D1. Local storage.**
⭐ App metadata in SQLite (`~/Library/Application Support/Piopio`). Build sessions in pi's native JSONL. Chat Spaces in pi-durable's SQLite storage. Everything inspectable and exportable.

**D2. Telemetry.**
⭐ None by default. Optional, anonymous crash reports.

**D3. Search.**
⭐ Global full-text search across all sessions, threads and agents (SQLite FTS). Semantic search later.

**D4. Updates & distribution.**
⭐ Notarized DMG + Sparkle auto-update + Homebrew cask.

**D5. License** (if open source): MIT / Apache-2.0 / AGPL / source-available?

---

## 4. Proposed phasing (strawman, refined after your answers)

| Phase | Scope |
|---|---|
| **0. Spikes** (1–2 wks) | Node sidecar + pi SDK in a Swift shell; pi-durable on local SQLite; PiHarness on Cloudflare with OpenRouter; Engine Protocol draft |
| **1. Build MVP** | Projects/sessions, streaming chat, tool-call rendering, diffs, terminal, approvals, checkpoints, OpenRouter picker, git basics |
| **2. Chat MVP** | Threads, folder projects, Spaces with organizer (front-door), web search/fetch, attachments, quick chat |
| **3. Agents MVP** | Agent definition + builder, local test loop, Cloudflare deploy, Telegram + WhatsApp, schedules, memory, cost caps |
| **4. Polish / 1.0** | GitHub PR/CI loop, worktrees, MCP everywhere, Mac Bridge, global search |

Should the order be different? E.g. Agents first if that's the mode you're most excited about.

---

## 5. Sources consulted
- Pi Durable on Cloudflare (Earendil): https://earendil.com/posts/pi-durable-on-cloudflare/
- Cloudflare Agents, Pi harness docs: https://developers.cloudflare.com/agents/harnesses/pi/
- Cloudflare example: https://github.com/cloudflare/agents/tree/main/examples/next/harnesses/pi
- Pi overview: https://agentic-ai.readthedocs.io/en/latest/AgentHarness/pi-dev/
