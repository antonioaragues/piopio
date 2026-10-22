# Piopio Specification

Piopio is a native macOS app on top of the **pi** agent harnesses (`pi-coding-agent` and `pi-durable`). It has three modes: **Build**, **Chat** and **Agents**. It's open source, built by one person for their own use, and anyone else can use it.

| Doc | Contents |
|---|---|
| [00-discovery.md](00-discovery.md) | Discovery round: original questions and proposals (historical) |
| [01-product.md](01-product.md) | Vision, principles, glossary, scope, non-goals |
| [02-architecture.md](02-architecture.md) | Components, runtimes, storage, packaging, security |
| [03-engine-protocol.md](03-engine-protocol.md) | The protocol between the Mac app and local/cloud engines |
| [04-chat.md](04-chat.md) | Chat mode: Threads, Folder lens, Spaces + organizer |
| [05-build.md](05-build.md) | Build mode: projects, sessions, diffs, approvals, git/GitHub |
| [06-agents.md](06-agents.md) | Agents mode: definitions, channels, scheduling, agent-to-agent, cloud deploy |
| [07-shared-resources.md](07-shared-resources.md) | Models, keys, skills, MCP, memory, extensions, settings |
| [08-app-shell.md](08-app-shell.md) | Window, navigation, transcript, composer, notifications, shortcuts |
| [09-roadmap.md](09-roadmap.md) | Phases, spikes, milestones and acceptance criteria |
| [10-model-providers.md](10-model-providers.md) | Multi-provider model support: requirements, inspection and what's built |
| [11-computer-use.md](11-computer-use.md) | Computer use spike: models, open-source projects, recommendation |

Normative words: **MUST** / **SHOULD** / **MAY**. "v1" means the first release of a mode. "Later" means after it.

---

## Decisions log

| ID | Decision | Source |
|---|---|---|
| X1 | Personal tool, **open source**. No Piopio-hosted backend. BYOK models, BYO Cloudflare account. | User |
| X2 | **Native SwiftUI**, latest OS: minimum **macOS 27**. Mac-only. | User |
| X3 | **Piopio** is the product name. | User |
| X4 | One app with three modes over a shared data model, global search and a command palette. | Default |
| X5 | **iOS companion is in scope later.** The architecture must allow it (engine protocol, cloud engine). | User |
| X6 | Global library of skills/MCP/prompts/memory, opted in per project/space/agent. | User |
| X7–X8 | No multi-Mac sync, no sharing in v1. Export only. | Default |
| X9 | Solo developer, no deadline. **Start with the easiest mode** → Chat Threads (see roadmap). | User |
| M1 | OpenRouter only in v1. Direct providers, local models and subscription logins come later. | Default |
| M2–M4 | Searchable model picker with per-mode defaults. Live cost meter. Keys in Keychain. | Default |
| B1 | **Agent-first** Build mode (no full editor). | User |
| B2 | Projects → sessions, optional git worktree per session. | Default |
| B3 | GitHub via `gh` or OAuth device flow. PRs, CI status, review comments. | Default |
| B4 | **Approval modes:** Ask / Auto-edit / Full auto, implemented as a pi extension. | User |
| B5–B10 | Checkpoints per turn. Pi CLI session interop. Pi packages supported (no TUI widgets). Curated default extensions. Cloud build later. Web preview later. | Default |
| C2 | **A Chat folder project and a Build project are the same entity** with different lenses. | User |
| C3 | **Spaces use a front door:** you always write in one main conversation and the organizer routes to topics. *(Answered as "x3" in chat.)* | User |
| C4–C7 | Space knowledge + memory doc. v1 tools: web search/fetch, attachments, MCP, opt-in memory. Local by default with "move to cloud" later. Quick chat hotkey. | Default |
| A1 | Agent priorities: **proactive**, **living inside other apps**, **scheduling**, **agent-to-agent communication**. | User |
| A3 | Channels v1: **In-app, Telegram, WhatsApp (official Cloud API)**. | User |
| A4–A9 | Official WhatsApp API only. Owner + allowlisted contacts. User's own Cloudflare account. Mac Bridge later. Author locally → deploy. Guardrails for proactivity. | Default |
| A10 | **Agent-to-agent is promoted to Agents v1** (because of A1). | Derived |
| D1–D4 | Local SQLite + pi-native formats. No telemetry. FTS search. DMG + Sparkle + Homebrew. | Default |
| D5 | License: **MIT**. | User |
| OQ1 | **Apple silicon only** (arm64 Node bundle). | User |
| BQ1–BQ2 | Default approval mode **Auto-edit**. Worktrees in the **app support folder**. | User |
| BQ3 | Default-on Build extensions: **todos, notify, subagents**. Plan mode off. | User |
| CQ1 | Spaces: routed replies show as a **link card only** in Main. | User |
| CQ2 | **Thread → Space suggestion** ships with Spaces. | User |
| CQ3 | Web search: **OpenRouter web plugin** + optional dedicated key. | User |
| AQ1–AQ3 | Telegram **bot per agent**. WhatsApp **one number → front agent**. **One conversation per person** across channels. | User |
| AQ4 | **Spaces and Agents stay separate** (shared runtime code only). | User |
| AQ5 | **Apple apps as agent tools**, served by the Mac app through reverse requests (Reminders, Calendar, Contacts, Notes, Music, Shortcuts); cloud agents through the Mac Bridge. | User |
| AQ6 | **Result cards with Undo** for every change an agent makes. | User |
| AQ7 | **On-device utility model** (Apple Foundation Models) first, OpenRouter fallback. | User |
| AQ8 | Agent conversations show **compact progress lines** ("Worked 18s · 2 steps"); Build keeps detailed tool cards. | User |
| AQ9 | The pending-items view is called **Inbox** (not "Waiting for You"). | User |
| AQ10 | Later: side-by-side agents, link previews, voice, quick entry to an agent, agent boards. | User |
| AQ11 | Long-term memory goes through a **memory provider** interface (07-shared §5.1). The built-in provider is the default. **Hindsight** comes as an opt-in provider, local (supervised daemon) or remote, first for Agents, then About me. Spike S6 decides whether it can become the default. **S6 (2026-10-21):** not yet. Built-in stays the default; Hindsight is opt-in for Agents, remote first. | User |
| AQ13 | **Spaces are called Notebooks in the app** (2026-10-21). The UI, the models' prompts and tool descriptions say Notebook; the spec, the protocol (`kind: "space"`, `spaces.*`) and the code keep "space". | User |
| AQ12 | **No Piopio plugin format.** Extensions are MCP servers (tools, every mode), pi packages (Build extensions; skills and prompt templates everywhere) and memory providers (built-in, Hindsight, any MCP memory server). See 07-shared §6. | User |

Open questions found later are tracked in [09-roadmap.md § Open questions](09-roadmap.md#open-questions).
