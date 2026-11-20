# 31 · Coding agents: Claude Code, Codex and Antigravity run a conversation

Status: decided 2026-11-20 from a question by the user; phase A1 (Claude Code) built the same day (§10). Mockup:
[docs/design/agent-runtimes/mockup.html](../design/agent-runtimes/mockup.html).

**The question (the user, 2026-11-20):** can Piopio use my Gemini subscription? Then: if we add the coding agents as
providers and pick one in the model picker, the composer should make clear that it's that agent running. Isn't that what
T3 Code does? And: "needing a model to then run Gemini in a task, I don't see it."

**The idea in one line:** a conversation runs on Piopio's agent (pi, with any model from your providers) or on one of
your coding agents (Claude Code, Codex, Antigravity CLI), signed in with your own plan. It's one choice, made in the
model picker. When you pick an agent, it receives your messages directly; there is no pi model in front of it.

## 1. What exists today

- **Subscriptions through pi.** pi signs in to ChatGPT and Claude Pro/Max itself (spec 10), so those plans already work
  as model providers. pi has no Google sign-in: Gemini is an API key (`google`) or Vertex.
- **Claude Code and Codex as `task` helpers** (`external-agents.ts`, 05-build AP7): Piopio's agent can hand a
  self-contained task to your `claude` or `codex` CLI, which runs unattended and returns its final answer. This needs a
  pi model to run the conversation, which is the part the user rejected.
- **The engine's `Runtime` interface** (`runtimes/runtime.ts`) is already "whatever harness backs it": Build sessions and
  chats run pi-coding-agent, agents run pi-durable.

## 2. How T3 Code does it (researched 2026-11-20)

T3 Code is "a local control plane for those agents, not a new model or a hosted coding agent". Each provider is the CLI
run as a subprocess with an adapter: Codex through `codex app-server`, Claude Code through the Claude Agent SDK,
Antigravity, Grok and others through ACP (Agent Client Protocol). The CLI's own loop and tools do the work; T3 draws the
thread, approvals and diffs. Sign-in is each CLI's own. Settings › Providers shows version, sign-in state, plan and an
on/off switch per provider, with a binary path. The picker groups models by provider; you can switch provider mid-thread
(context carries over, the old provider's tool calls stay behind). Permission modes (Supervised, Auto-accept edits,
Auto, Full access) fall back to Supervised where a provider lacks one. Sources: the T3 Code README and AGENTS.md
(github.com/pingdotgg/t3code), Flavio Copes' deep dive (Nov 2026, v0.1.9).

Where Piopio differs: T3 has no agent of its own. Piopio does (memory, connectors, browser, computer use, side
conversations, agents and automations), so the agents join it rather than replace it.

## 3. Gemini: through Antigravity CLI, not Gemini CLI

Checked on this Mac on 2026-11-20: Gemini CLI 0.27.3 signed in with Google answers every request with "This client is
no longer supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate to the Antigravity
suite of products". Google stopped serving the free, Google AI Pro and Google AI Ultra tiers in Gemini CLI on
2026-06-18. The replacement is the **Antigravity CLI** (`agy`, installed with Google's script into `~/.local/bin`),
which ships an official ACP server: `agy acp` ("Any ACP client can launch Antigravity CLI"; Zed, JetBrains and Xcode use
it). It supports loading and resuming sessions, a model and thinking level picker, permission requests, elicitation
questions and steering. Sign-in is `agy` once in a terminal (or `agy acp --login`); Google Workspace accounts aren't
covered by Antigravity plans. So the Google agent is Antigravity CLI, phase A3.

## 4. Decisions

- **CA1 One choice per conversation, made in the picker.** The picker lists coding agents next to model providers. A
  row is a model inside an agent ("Opus 5.5 · Claude Code"). Picking it makes that agent run the conversation.
- **CA2 The agent is the harness.** Its own loop, tools, system prompt, settings (CLAUDE.md, its MCP servers, its
  skills) and context management. Piopio draws the transcript, asks you for approvals, keeps checkpoints and the files
  pane, and stores the transcript as its own. Piopio never reads or reuses the agent's tokens; it starts the CLI you
  installed and signed in to.
- **CA3 What runs is always visible**, without badges: the composer's model selector names the agent first
  ("Claude Code · Opus 5.5"), the placeholder says "Message Claude Code…", the toolbar subtitle reads "runs in Claude
  Code", and each answer's footer says the model and the agent.
- **CA4 Approvals go to the tray.** The agent's permission requests become Piopio's pending prompts (the composer tray,
  Needs you, notifications). Piopio's approval modes map onto the agent's own: Read only → plan, Ask before edits →
  default, Auto-edit → acceptEdits, Full auto → bypass permissions. A conversation without a project (a chat) runs in
  its own folder in Auto-edit.
- **CA5 No other provider needed.** Titles, follow-up suggestions and commit messages for a conversation on an agent are
  asked from that agent as a one-off question on its smallest model, so a Mac with only Claude Code works.
- **CA6 Plan, not spending.** Usage is shown, but an agent's reported cost isn't counted as spending (as AP7 already does
  for Claude Code tasks). Its billing line is the plan ("Claude Pro plan").
- **CA7 Switching between Piopio's agent and a coding agent** is allowed only before the first message in phase A1. From
  A2 on, switching mid-conversation starts the new agent from a summary of the conversation, shown as a line in the
  transcript ("Now running in Claude Code · it starts from a summary of the 14 messages above"). Switching models inside
  the same agent works from A1.
- **CA8 Piopio's own tools reach the agent through MCP** (phase A2): memory, connectors, the browser, computer use and
  earlier conversations, passed when the agent's session starts (an in-process MCP server for the Claude Agent SDK, the
  `mcpServers` of ACP's `session/new` for the others).
- **CA9 Agents and automations stay on Piopio's agent** for now. Unattended scheduled runs on a personal plan need their
  own decision (plan limits, terms, who approves at 03:00).
- **CA10 The `task` helper stays.** A conversation on Piopio's agent can still hand a task to Claude Code or Codex.

## 5. What you see

- **Model picker:** a section per agent, below the model providers, titled with the agent and its plan
  ("Claude Code · Claude Pro plan"). Rows are the models the agent reports. In a conversation with messages on the other
  kind of runtime, the agent's rows (or the providers' rows, in a conversation on an agent) say "Start a new
  conversation to switch" until A2.
- **Composer:** the selector reads "Claude Code · Opus 5.5"; the placeholder "Message Claude Code…"; approvals in the
  tray as today. A signed-out or missing agent is a composer notice ("Claude Code is signed out · nothing was sent",
  with **Open Terminal**).
- **Settings › Models:** a section "Agents on this Mac" with each agent found: version, sign-in state and plan, where it
  is. An agent that isn't installed says how to install it. Agents can be set as the default for Build and for chats.

## 6. Under the hood

- **Claude Code: the Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`, pinned to the version that matches the CLI)
  with `pathToClaudeCodeExecutable` set to the user's own `claude`, so their version and sign-in are used. One
  long-lived `query()` per open conversation in streaming-input mode: `canUseTool` → Piopio prompts, `permissionMode`,
  `setModel`, `setPermissionMode`, `interrupt`, `resume` (Claude Code keeps its own session, so reopening a conversation
  continues it), `supportedModels()` for the picker. Detection: `claude auth status` (signed in, plan) and
  `claude --version`.
- **Antigravity CLI and Codex: ACP.** One ACP client (`AcpRuntime`) for any ACP agent: `agy acp` natively, Codex
  through `codex-acp` (or `codex app-server`). Phase A3.
- **Model refs keep their shape:** `{ provider: "claude-code", id: "opus" }`. `sessions.ts` opens the agent's runtime
  when the provider is an agent; the rest of the engine sees a `Runtime`.
- **Transcript:** the runtime stores Piopio's view of the conversation (pi-shaped messages, as `TimelineBuilder` reads
  them) in its own file next to the chat sessions, with the agent's session id. Search, export and Home read it like
  any other.
- **Tool calls** keep the agent's names; Read, Write, Edit and Bash get Piopio's file, diff and terminal details.

## 7. Phases

| Phase | What | Done when |
|---|---|---|
| **A1** | Claude Code runs Build sessions and chats: picker section, composer, approvals in the tray, modes, model switch inside the agent, resume after restart, titles from the agent, Settings › Models section | A Build session on Claude Code edits a file after you allow it, and reopens after a restart with its history |
| **A2** | Piopio's tools through MCP (CA8); switching to and from an agent mid-conversation with a summary (CA7); thinking level as the agent's effort | A Claude Code conversation remembers something in Piopio's memory and switches back to Piopio's agent |
| **A3** | `AcpRuntime`: Antigravity CLI (`agy acp`) and Codex | A Build session on Antigravity CLI with your Google plan edits a file |
| **A4** | Agents and automations on a coding agent (CA9), after a decision on unattended runs | — |

## 8. Open questions

- Terms: each provider's terms for driving its CLI from another app. Piopio runs the CLI the user installed and signed
  in to, as Zed and T3 Code do, and never touches its credentials. Read each provider's current terms before A3 ships.
- Plan limits: when the agent hits its plan's limit, a notice with "Use another model". Never move to credits without
  asking (spec 29).
- Notebooks' heading organizer is Piopio's own: does it keep running on a model while the conversation runs on an
  agent?

## 9. Not verified

- Antigravity CLI's ACP details (initialize capabilities, mode ids, model switching) are from Google's docs only; `agy`
  isn't installed on this Mac.
- Codex isn't installed on this Mac.
