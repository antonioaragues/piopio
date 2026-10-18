# 01 — Product

## 1. Vision

One native Mac home for working with AI agents, built on the pi harnesses and their design rules: a small core, explicit behavior, and extensible by default.

- **Build**: let agents write code in your repos, and review what they did.
- **Chat**: think out loud with an assistant that keeps your topics organized.
- **Agents**: create personal agents that live in your messaging apps, act proactively, run on a schedule, work together, and keep running when your Mac is off.

## 2. Users

- **Primary:** the author. A power user who already uses pi/Claude Code-style tools, has an OpenRouter key and a Cloudflare account.
- **Secondary:** open-source users with the same profile. They're expected to bring their own keys and their own Cloudflare account. There's no account system, no hosted service and no onboarding for non-technical users.

## 3. Principles

1. **Native first.** SwiftUI, standard macOS behaviors (keyboard, menus, windows, Services, Spotlight-style quick entry). No web views for core surfaces unless a spike proves native can't do it.
2. **Thin client, smart engine.** All agent logic runs in TypeScript engines (local or cloud). The app only renders and controls, which keeps a future iOS app cheap to build.
3. **Pi-native, not pi-forked.** Use the upstream packages as-is. Anything we need goes into **pi extensions** that also work in the pi CLI where possible. Never patch pi internals.
4. **Transparent.** Every tool call, routing decision, memory write, scheduled run and dollar spent is visible and inspectable. No hidden prompt injection.
5. **Your data, your accounts.** Local files in open formats. Cloud resources live in the user's own Cloudflare account. No telemetry.
6. **Portable sessions.** A session's location (local or cloud) is an attribute, not a separate product.
7. **Solo-maintainable.** Prefer boring, few dependencies. Every phase ends with something usable every day.

## 4. Glossary

| Term | Meaning |
|---|---|
| **Engine** | A TypeScript process that hosts pi runtimes and speaks the Engine Protocol. **Local Engine** = Node sidecar on the Mac. **Cloud Engine** = Cloudflare Worker + Durable Objects. |
| **Project** | A folder on disk (usually a git repo). Shared by Build and Chat (folder lens). |
| **Session** | A unit of agent work with its own history. Its kind decides the runtime (see below). |
| **Build session** | A `pi-coding-agent` session inside a Project. Stored as a pi JSONL session file. |
| **Thread** | A free-standing chat. One `pi-durable` session (root conversation + forks). |
| **Space** | A Chat container backed by **one** `pi-durable` session. Has a **Main** conversation (front door) where the **Organizer** routes messages to **Topics** (other conversations in the same session). |
| **Topic** | A conversation inside a Space about one subject. |
| **Agent** | A persistent persona defined by an **Agent Definition**, running on pi-durable, reachable through **Channels**, with memory, schedules and triggers. |
| **Channel** | A transport through which people talk to an Agent: In-app, Telegram, WhatsApp, and more later. |
| **Contact** | A person allowed to talk to an Agent. The **Owner** is the user. |
| **Run** | One autonomous execution (scheduled task, trigger, heartbeat, agent-to-agent request). |
| **Lens** | A UI presentation of a Project: Build lens (code, diffs, terminal) or Chat lens (docs, chat-first). |
| **Approval** | A pending yes/no from the user before a tool runs. |
| **Checkpoint** | A snapshot of a Project's working tree taken before an agent turn modifies it. |

## 5. Mode summary and runtime mapping

| Container | Runtime | Storage | Can run in cloud |
|---|---|---|---|
| Build session (Project) | `@earendil-works/pi-coding-agent` SDK | pi JSONL in `~/.pi/agent/sessions/` (CLI-compatible) | Later (cloud sandboxes) |
| Chat-lens session (Project) | `pi-coding-agent` SDK with the "chat" tool profile | same | No (bound to a local folder) |
| Thread | `@earendil-works/pi-durable` | one SQLite file per thread | Later ("move to cloud") |
| Space | `pi-durable` | one SQLite file per space | Later |
| Agent | `pi-durable` | Local: SQLite file. Cloud: Durable Object SQLite | **Yes (primary)** |

Rule of thumb: **work on a local folder → pi-coding-agent. Folder-less, long-lived or cloud-portable → pi-durable.**

## 6. Scope

### In scope (across all phases)
- The three modes described in docs 04–06.
- OpenRouter as the model gateway, with a provider abstraction ready for more.
- Local engine bundled in the app. Cloud engine deployable to the user's Cloudflare account.
- Open-source repo, MIT license, notarized DMG releases.

### Explicit non-goals
- A full code editor (use Xcode/VS Code/Zed via "Open in…").
- Multi-user accounts, teams, billing, a hosted Piopio cloud.
- Unofficial WhatsApp/iMessage automation.
- Windows/Linux builds.
- Re-implementing pi features the harness already provides (compaction, retries, session trees).

## 7. Success criteria (for the author)

- Phase 1: Piopio replaces the author's daily web chat app.
- Phase 2: Piopio replaces the terminal for most pi/Claude Code sessions.
- Phase 5: at least two agents run 24/7 in the cloud, reachable on Telegram/WhatsApp, with the Mac closed, and talk to each other.
