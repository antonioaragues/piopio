# 11 — Computer use (spike, 2026-10-22)

Roadmap backlog D10: let agents and chats see the Mac's screen and act on it (click, type, scroll), with approvals. This spike checks which models can do it, what pi gives us, which open-source projects are worth reusing, and recommends a path. Nothing is built yet.

## 1. Models

| Provider | How it works | Through Piopio today |
|---|---|---|
| Anthropic | `computer_toolset_20260801`, a client toolset (GA, no beta header): one entry in `tools` gives the model 17 member tools (`screenshot`, `zoom`, `left_click`, `type`, `key`, `scroll`, …). The app runs every action and returns screenshots. Supported by Claude Sonnet 5.5, Opus 5.5, Haiku 5.5, Fable 5.x and others. Recommended screen 1280×720 to 1366×768; coordinates in screenshot pixels (Retina needs scaling). | Not as the native toolset (see §2). |
| OpenAI | The `computer` tool in the Responses API (`computer_call` → action → `computer_call_output` screenshot), or code execution driving the UI. Examples use GPT-6 Astra. The docs only describe API-key access; nothing about ChatGPT sign-in. | Not as the native tool (see §2). |
| Google | Gemini computer use (browser, Android, desktop; 0–999 normalized coordinates). Model names in secondary sources disagree; check Google's docs before relying on it. | Not as the native tool. |

## 2. What pi gives us

- **pi-ai 1.3.0 has no support for provider computer-use tool types** (nothing for Anthropic's toolset or OpenAI's `computer` tool in its code). Through pi, the model only sees ordinary function tools.
- That's still workable: every vision model can drive a computer through ordinary tools (`see`, `click`, `type`…). It's how the open-source MCP servers below work, and it works with any provider Piopio has (OpenRouter, ChatGPT, OpenAI API, custom). Models trained for computer use (Claude 5.5, GPT-6 Astra) are expected to do best even this way.
- **MCP already reaches Build sessions, and chats and notebooks when Settings › MCP servers › "Also in Chat" is on** (`tools/mcp-chat.ts`). Agents don't get MCP tools yet.
- **The app already runs tools for agents with its own permissions:** Apple apps go through the engine's `app.tool` reverse request (`AppleTools.swift`, 06-agents §4.1). Screen Recording and Accessibility are macOS permissions the app would hold the same way.

## 3. Open-source projects

What Piopio needs is a **tool layer** (see the screen, act on it); pi is already the agent loop. Full agent frameworks would bring a second loop and their own model choices.

| Project | What it is | License | Fit |
|---|---|---|---|
| [Peekaboo](https://github.com/steipete/Peekaboo) | macOS screen capture, accessibility inspection and input. `see` returns a UI map with element IDs; `click`, `type`, `press`, `scroll`, `drag`, menus, windows, Dock, dialogs. CLI, MCP server (24 tools), menu-bar app, its own agent. Swift 6.2, macOS 15+; ~5.4k stars, active (4.9.x). **Its core ships as Swift library products** (`PeekabooAutomationKit`, `PeekabooFoundation`, `PeekabooProtocols`, `PeekabooBridge`; macOS 14+). | MIT | **Best fit.** Same language and platform as the app; we can embed the automation kit instead of shipping another process. |
| [Cua](https://github.com/trycua/cua) | Largest open-source computer-use project (~30k stars). Cua Driver: desktop tools on macOS, Windows, Linux through CLI, MCP or SDKs (Python, TypeScript, Rust; Swift not released), can work in the background without taking focus. Lume: macOS/Linux VMs on Apple silicon. Cua Spaces, Cua Bench, small CUA-S1 models. | Mostly MIT; Spaces and Driver Bench FSL-1.1-MIT; `cua-som`/`cua-perception` AGPL | Good as an MCP server today; **Lume is the interesting part later** (a sandbox VM for unattended agents). No Swift SDK yet. |
| [UI-TARS Desktop / Agent TARS](https://github.com/bytedance/UI-TARS-desktop) | ByteDance's multimodal agent stack (~39k stars): a desktop GUI agent tied to UI-TARS/Seed models, and Agent TARS (CLI and Web UI, MCP-based). TypeScript, Node 22. | Apache-2.0 | Poor: a whole agent and app, built around its own models. |
| [Agent S](https://github.com/simular-ai/Agent-S) | Simular's research agent framework (S3 in the `gui-agents` package, S4 released 2026-10-20). Strong OSWorld results; Python; macOS, Windows, Linux. | Apache-2.0 | Poor as a dependency (its own loop, Python); worth reading for ideas (grounding, reflection). |
| Small MCP servers: open-computer-use, [Macbeth](https://mcpservers.org/servers/wende/macbeth), [Chatuse](https://glama.ai/mcp/servers/fazakis/chatuse) | Accessibility-first MCP servers for macOS (screenshots and OCR as fallback). | MIT and others | Fine to try through MCP; less mature than Peekaboo. |

Star counts and benchmark claims come from the projects' pages and secondary roundups ([pinggy.io](https://pinggy.io/amp/blog/best_computer_use_mcp_servers/), [Turing Post](https://www.turingpost.com/p/computer-use-ai-agents)), read on 2026-10-22.

## 4. Recommendation

**Accessibility first, screenshots second.** Reading the UI tree gives element IDs and labels, which are sturdier than pixel coordinates, cheaper in tokens, and let us refuse dangerous targets (password fields). Screenshots stay available for what accessibility doesn't describe.

1. **Now, at no cost:** document Peekaboo (or Cua Driver) as an MCP server in Settings › MCP servers. Build sessions get it immediately; chats when "Also in Chat" is on. This lets us try real tasks before building anything.
2. **Then, built in:** a "Computer use" ability implemented in the app on top of `PeekabooAutomationKit`, reached through `app.tool` like the Apple apps:
   - Tools: `see` (UI map plus optional screenshot), `click`, `type`, `press`, `scroll`, `open_app`; small, stable names that any model can use.
   - Permissions live with Piopio.app (Screen Recording, Accessibility), requested the first time with an explanation.
   - Available to agents (where MCP doesn't reach) as a Setup › Abilities switch, "Asks first" by default, and to chats and Build as an opt-in.
3. **Later:** native provider toolsets (Anthropic's toolset, OpenAI's `computer`) if pi adds them; a Lume VM for agents that run unattended.

**Safety rules** (from Anthropic's and OpenAI's guidance, adapted):
- An overlay while it acts: "Piopio is using your Mac" with Stop (and a shortcut).
- Per-app permission: the first time it acts in an app, it asks ("Allow in Mail?"). Never in Keychain Access, Passwords, System Settings' privacy panes, or Terminal.
- Never types into secure text fields (`AXSecureTextField`); never reads them.
- Asks before consequential actions: send, submit, buy, delete, accept terms.
- Screen content is untrusted (prompt injection): text on screen never counts as an instruction from you.
- A step budget per turn, and the whole trail visible in the transcript (each action as a folded step with its screenshot).

## 5. Questions for you
- Should agents use it only while you're at the Mac (and can see the overlay), or also unattended? Unattended points to a VM (Lume) rather than your real desktop.
- Agents first, or chats and Build too?

## 6. Not verified
- Nothing was installed or run on this Mac (it needs a third-party download and Screen Recording/Accessibility permissions). Next step: install Peekaboo, add it as an MCP server, and try a few tasks in a Build session.
- Whether OpenRouter passes provider computer-use tool types through, and whether ChatGPT sign-in can use OpenAI's `computer` tool.
- `PeekabooAutomationKit` needs Swift tools 6.2 (we have Swift 6.4; the app target is in Swift 6.0 language mode, which only matters for our own code).
