# Handoff: Piopio for macOS

> **The current visual direction is [`grey/`](grey/README.md)** (grey ink, hairlines, one black action per view). What the app implements is in [`grey/IMPLEMENTATION.md`](grey/IMPLEMENTATION.md). v2 below still describes product behavior.
>
> **v2 supersedes the shell described here.** The current design is in [`v2/`](v2/README.md): one sidebar instead of the Build · Chat · Agents switcher, Home and Needs you, Notebooks, the agent page, Settings › Models and the empty states. What is implemented is listed in [`v2/IMPLEMENTATION.md`](v2/IMPLEMENTATION.md). The screens below still describe the parts v2 doesn't redraw (Build review, terminal, PRs, cloud targets, channels).

## Overview
Piopio is a native Mac app for working with agents on the pi harness. It has three modes inside one window:
- **Build**: coding sessions in folder Projects (pi-coding-agent), git/GitHub, approvals, checkpoints, diff review, terminal, PRs.
- **Chat**: Threads (single conversation) and Spaces (long-running subject split into Topics, with an Organizer that routes messages and a Space-level Memory).
- **Agents**: durable agents with channels (in-app, Telegram, WhatsApp Business, Slack, Email, Webhook), contacts, schedules, budgets, approvals, running Local or in a Cloud target.

Providers and cloud targets are **lists**, not fixed integrations. v1 ships **OpenRouter** (model provider) and **Cloudflare** (cloud target: Worker + one Durable Object per agent). Later: ChatGPT subscription, other targets. Never hard-code either one into layout or naming (e.g. use "Provider key", "Cloud · Cloudflare").

## About the design files
`Piopio.dc.html` is a **design reference built in HTML**, not production code. Recreate it in **SwiftUI** (macOS 15+), using native controls and materials wherever they exist. Open the file in a browser (keep `support.js` next to it). It's a pan/zoom canvas; each screen has an id badge (2a, 3b, …). Newest turns are at the top; **Turn 2 (2a–2c) is the base shell** and the best starting point.

App copy is in **English** (v1). Sample data (names, amounts, file names) is illustrative.

## Fidelity
**High-fidelity.** Colors, type, spacing, radii and copy are final intent. Where macOS provides an equivalent (materials, segmented controls, toggles, sheets, menus, notifications), use the native one and match the spirit rather than pixel-copying the HTML.

## Window & shell (applies to every main-window screen)
- Window: 1280×820 reference size, corner radius 18. Background `win`.
- Layout: `NavigationSplitView`-like three columns: **Sidebar | Content | Inspector**.
  - Sidebar: 268 wide, **floating glass panel**, inset 8pt from window edges, radius 14, hairline edge, panel shadow. Contains traffic lights (top), the **mode switcher** (Build · Chat · Agents capsule segmented control, ⌘1/2/3), search field (⌘⇧F), mode-specific list, and a footer status row (engine status, MCP count / spend).
  - Content: toolbar row 60pt tall (title 15 semibold + 11pt subtitle in `fg3` on the left; capsule "toolbar pills" on the right). Transcript column centered, max-width 680–700, horizontal padding 32.
  - Inspector: 288–300 wide floating glass panel, inset 8, radius 14. Toggled by the ◫ pill. Content is contextual per mode.
- Composer: floating glass, radius 20, max-width ~636, centered at the bottom with 20pt bottom padding. Row of capsule chips (model, thinking level, tools/MCP count) and a 28pt circular send button (`inv` fill). Hints: "⌥↩ steer · esc abort".

## Screens
Ids match badges in the HTML file.

### Base modes (Turn 2)
- **2a Build session**: sidebar lists Projects (folders) with nested Sessions. Session status dot: amber = waiting on you, accent ring (spinner) = running, grey 50% = idle, green = done/PR open. Transcript: user bubble (right, `bubble`, radius 16/16/4/16), assistant prose 13.5/1.6, **tool cards** (collapsible, card + hairline, radius 12, header 12pt: chevron, verb, monospace path, duration or +/− counts), inline diff preview (`addbg` rows), **checkpoint divider** (hairline + 11pt `fg3` label), **approval card** (1px `accentLine` border + 4pt `accentSoft` halo; amber dot; monospace command; actions Deny / Always for X / **Allow once ↩** primary). A queued message line sits above the composer. Inspector: Changes (file list with A/M/D in green/amber/red, +/− totals), Review diff / Commit… buttons, Checkpoints list, footer with Context bar (41k/200k) and session spend.
- **2b Chat Space**: sidebar sections Pinned, Spaces (with Topics nested), Projects, then dated Threads. Topic capsule row above the transcript (Main selected = `inv`). **Organizer routing note** inline chip ("Organizer routed to Kitchen budget · matched … · Change"). Memory write note with Undo. Inspector: Topics (name, when, one-line summary) + Recent memory.
- **2c Agent activity**: sidebar has Inbox (count badge) + Agents (avatar 28 with status dot, subtitle, LOCAL/CLOUD badge). Header with avatar, "● Running in Cloudflare · v14", Talk to / **Deploy changes**. Tabs: Activity · Conversations · Memory · Definition (selected = 2pt accent underline). Activity rows: 30pt icon tile, title + kind, body, time + cost; items needing you are tinted `accentSoft`. Inspector: Channels, Contacts, Schedules, Budget bar, Worker name.

### Around the window (Turn 3)
- **3a Quick Chat (⌥Space)**: floating panel 620 wide, radius 22, strong glass. Question 17pt in the header, streaming answer below, footer actions: Open in Piopio ⌘O, Move to Space…, Copy. Uses a fast model by default; every quick chat is saved as a Thread.
- **3b Command palette (⌘K)**: 560 wide, radius 16. Groups: Actions first, then Go to. Selected row = accent fill, white text. Right side shows mode/source. Footer key hints (⇥ filter by mode, ⌘↩ run in background).
- **3c Menu bar extra**: icon + pending count. Popover 360 wide: "Needs you" cards with inline actions (approve/deny, send/edit), Running list, footer (Quick Chat, Open Piopio, today's spend/runs).
- **3d New agent sheet**: sheet 820×640 with a step rail (Identity, Model, Tools & MCP, Channels, Contacts, Where it runs). The last step: This Mac vs **Cloud** (target picker, Cloudflare default), account, worker name, secrets chips (Provider key ✓, TELEGRAM_TOKEN ✓), monthly budget, inline **deploy log** with progress bar and step states (✓ / spinner / pending).

### Settings, review, memory (Turn 4)
- **4a Settings · MCP servers**: Settings sidebar: General, Providers, Engines, MCP servers, Channels, Approvals, Budgets, Privacy. Table of servers (initial tile, name, status dot, transport + URL/command in mono, tool count, scope capsule e.g. "All modes" / "Build only" / "Atlas only", toggle). Per-tool permission grid: **Allow (green) / Ask (amber) / Never (red)** capsules.
- **4b Settings · Engines & keys**: two equal cards, **Local engine** and **Cloud · Cloudflare** (+ Add target). Model providers list: OpenRouter (masked key, ✓ Verified, monthly spend, Replace), Default model + Quick Chat model pickers, ChatGPT "Soon", Fallback provider. Note: keys in macOS Keychain; cloud agents get them as secrets on their target.
- **4c Diff review**: sidebar becomes the session file list ("Whole session / Last turn" segmented), checkboxes for partial commit. Unified/Split toggle, Restore checkpoint…, **Commit N files…**. Inline line comment → "Ask agent ↩" sends the comment + line as a follow-up turn.
- **4d Agents Inbox**: 3-pane: sidebar | list (380) | detail. Filter "Needs you / All". Item kinds: Approval (amber), Run failed (red), Message for you (accent), Deployed (green). Detail: original conversation, what the agent checked (system note), **Proposed actions card** listing each action (editable) with Reject / Edit / Approve both, plus "Always allow …".
- **4e Space Memory**: Memory is an entry under the Space in the sidebar. Filter capsules (All, Pinned, per topic, Added by you). Facts grouped; selected fact tinted. Inspector: fact text, Edit / Pin / Forget (red), provenance (quote + jump to message), written by / model / when / used in.

### First run (Turn 5)
- **5a Welcome**: app icon slot (84, radius 22), title 28 bold. **Connect a model provider** radio list: OpenRouter (key field, live verify) / ChatGPT subscription (Soon). Option to import pi CLI sessions found under `~/.pi/agent/sessions`. Page dots + Continue.
- **5b Cloud target (optional)**: target capsules (Cloudflare, "More targets soon"), table of what will be created (Worker, Durable Objects, plan requirement), Sign in with Cloudflare / Paste API token. **Skip for now** next to Connect.
- **5c Empty states**: per mode, the same structure: 11pt label, 18 bold title, one sentence, one or two actions (Open Folder… ⌘O / drop zone; New thread ⌘N, New Space ⌘⇧N; agent templates + Start from scratch).

### Editing and following along (Turn 6)
- **6a Agent Definition tab**: header shows draft state ("● 2 unsaved changes · live is v14"), Test in sandbox / **Deploy v15**. Instructions (Markdown, token count, new lines highlighted with `addbg`), Model, Tools, Approval rules table. Inspector = **Sandbox** chat against the draft, as "New contact" or "As Luis", with a note when it would ask for approval.
- **6b Terminal drawer (⌃`)**: dark panel (#141416, text #e5e5ea) 300 tall under the transcript, radius 14. Tabs labelled by owner (agent processes vs "zsh · you"). Actions: Send output to agent, Stop ⌃C. Colors: pass #30d158, fail #ff453a, warning #ff9f0a, muted #8e8e93.
- **6c Notifications**: only for decision needed, long job finished, failure. Approvals have inline actions.

### Build start to merge (Turn 7)
- **7a New session sheet**: prompt field first (focused, accent halo). Work on: New branch / Worktree / Current branch. Branch name suggested from the prompt. Permissions: Read only / **Ask before edits** / Auto. Model (from any connected provider) + thinking. Context chips (AGENTS.md, MCPs, linked issue). **Start ⌘↩**. Defaults saved per project.
- **7b Pull request**: inspector tab "Pull request": state badge, title, branch → base, Checks list (done green, running accent ring, queued hollow), Review status, "Address remaining comment", Merge disabled with reason ("waiting on checks"). GitHub review comments appear as transcript turns; agent replies and pushes are logged as system notes.

### Gaps filled (Turn 8)
- **8a Chat Thread**: attachments as chips (in transcript and composer). Structured outputs become **artifacts**: a card in the transcript (accent border, version list) that opens in a right panel (radius 14, `card`) with versions, Copy / Export, and Sources (file + page).
- **8b Agent ↔ contact conversation**: contact list (name, channel, last message). The thread shows what the contact sees. Outgoing bubbles labelled "Atlas · auto", "Atlas · approved by you", or "You · sent via Atlas" (`inv` bubble). Toolbar toggle **Atlas replies** (off = you take over). Composer segmented: Reply as you / Instruct Atlas. Inspector: contact role, trust level, channels, contact memory.
- **8c WhatsApp Business setup**: 4 steps (Meta account, phone number, templates, test). Explains the 24-hour rule. Template list with Approved / In review status, "Draft a template with Atlas", cost note (billed by Meta).
- **8d Error states**: transcript provider error card (Retry now / use another model / Details), window banner for local engine stopped (red tint, Restart), deploy failed inside the sheet (step log, Upgrade plan / Retry / Run on this Mac instead), budget reached in Activity (amber tint, Raise / Resume once / Keep paused). Pattern: what happened → what's safe → one primary action + alternatives. Red = failure, amber = limit you set.
- **8e Components & tokens**: canonical reference for everything below.

Turn 1 (`pi Mac - Opciones UI.dc.html` in the original project) was early exploration and is superseded.

## Interactions & behavior
- ⌘1/2/3 switch mode; ⌘K palette; ⌥Space Quick Chat (global); ⌘N new thread/session; ⌘⇧N new Space; ⌘O open folder; ⌃` terminal; ⌥↩ steer the running agent; esc abort; ↩ on approval card = Allow once.
- Session status dots update live in the sidebar, menu bar extra and Dock badge (pending count).
- Tool cards collapse by default except edits with a diff preview; only decision cards get the accent halo.
- Organizer routing and memory writes are always visible inline with Change / Undo. No hidden prompt injection.
- Agent definition edits are drafts until Deploy; the sandbox runs the draft.
- Deploys stream step-by-step in place; failures keep the completed steps visible.
- Transitions: use system defaults (sheet slide, popover, sidebar collapse). No custom animation required beyond the running spinner ring.

## State (high level)
- `mode: build | chat | agents`; selection per mode (project/session, space/topic/thread, agent/tab).
- Session: status (idle/running/waitingApproval/done/failed), queued messages, checkpoints, changed files, context tokens, cost, branch, PR (checks, review).
- Space: topics, memory facts (text, source message, author, pinned), routing events.
- Agent: definition (draft vs live version), channels (status), contacts (trust), schedules, budget, location (`local | cloud(targetId)`), activity events, inbox items.
- Providers: list of `{kind: openrouter | chatgpt | …, credential, verified, defaultModel}`; Targets: list of `{kind: cloudflare | …, account, status}`.

## Design tokens
Light / Dark (dark = `body[data-theme="dark"]` in the HTML).

| Token | Light | Dark | Use |
|---|---|---|---|
| accent | system accent (#0a84ff ref) | system accent | primary actions, selection, running |
| accentSoft | accent 16% | accent 26% | selected rows, halos, tints |
| accentLine | accent 45% | accent 60% | decision/artifact borders |
| win | #fdfdfc | #1a1a1c | window background |
| glass | rgba(242,242,246,.72) + blur 30 sat 1.6 | rgba(40,40,44,.80) | sidebar, inspector, composer, popovers → `.regularMaterial` / `.thickMaterial` |
| glassEdge | rgba(255,255,255,.85) | rgba(255,255,255,.13) | 0.5pt panel edge |
| card | #ffffff | #242426 | cards, tables |
| chip | rgba(0,0,0,.045) | rgba(255,255,255,.08) | secondary buttons, chips, fields |
| bubble | #f1f1f3 | #2e2e31 | user / incoming bubbles |
| pill | rgba(255,255,255,.78) | rgba(74,74,78,.88) | toolbar pills, selected segment |
| fg | #1d1d1f | #f5f5f7 | primary text |
| fg2 | #5b5b61 | #b8b8bd | secondary text |
| fg3 | #8e8e93 | #8e8e93 | tertiary text, labels |
| line | rgba(0,0,0,.08) | rgba(255,255,255,.12) | hairlines (0.5pt) |
| inv / invfg | #1d1d1f / #fff | #f5f5f7 / #1d1d1f | strong button, send button |
| green | oklch(0.64 0.15 150) ≈ #2fa760 | same | live/done/allow → `.green` |
| amber | oklch(0.74 0.15 70) ≈ #e0a02a | same | waiting/ask/limits → `.orange` |
| red | oklch(0.62 0.18 25) ≈ #d9493f | same | failure/never → `.red` |
| addbg / delbg | oklch(.96 .035 150) / (.96 .03 25) | oklch(.32 .06 150) / (.32 .06 25) | diff rows |

Accent options shown in Tweaks: Blue #0a84ff, Purple #9b5de5, Orange #f2711c, Graphite #6e6e73. In the app, just follow the system accent.

**Type (SF Pro / SF Mono):** 28 bold (onboarding title, −0.02em) · 20 bold (sheet title) · 18 bold (empty-state title) · 15 semibold (toolbar title) · 13.5 / 1.6 (transcript body) · 13 regular (UI body) · 12 (secondary UI, chips) · 11 semibold `fg3` (section labels, sentence case) · SF Mono 12 (code, paths, branches) / 11.5 (diff).

**Radii:** window/sheet 18 · composer 20 · Quick Chat 22 · glass panel 14 · card/tool card 12 · rows 8 · chips/buttons capsule · small badges 5.

**Spacing:** 4pt grid: 4 · 8 · 12 · 16 · 22 · 28. Panel inset 8. Row padding 6–8 vertical.

**Shadows:** window `0 0 0 .5px rgba(0,0,0,.18), 0 30px 80px rgba(20,20,40,.22), 0 8px 24px rgba(20,20,40,.1)` (use the system window shadow). Panel `0 0 0 .5px rgba(0,0,0,.08), 0 8px 30px rgba(0,0,0,.08)`. Decision halo `0 0 0 4px accentSoft` + 1px `accentLine` border.

**Status vocabulary (use everywhere):** amber dot = waiting on you · accent ring = running · green = live/done · grey 50% = idle · red = failed.

## SwiftUI mapping hints
- Glass panels → `.background(.regularMaterial, in: .rect(cornerRadius: 14))` with 0.5pt stroke; on macOS 26 consider Liquid Glass (`.glassEffect`).
- Mode switcher → `Picker(.segmented)` styled as a capsule, or custom.
- Pills → `Capsule()` buttons; primary = `.borderedProminent` with `.tint(.accentColor)`.
- Sheets (3d, 7a, 8c) → `.sheet`; palette and Quick Chat → `NSPanel` (non-activating for Quick Chat).
- Menu bar extra → `MenuBarExtra(style: .window)`.
- Notifications → `UNUserNotificationCenter` with action categories for approvals.
- Terminal drawer → a dedicated terminal view (e.g. SwiftTerm), fixed dark palette regardless of appearance.

## Assets
None. Placeholders only: app icon (5a), notification icon tiles (6c), avatars are colored circles with initials. Glyphs (›, ⌄, ↑, ◫, ⑂) stand in for **SF Symbols**. Replace them with symbols, e.g. `chevron.right`, `chevron.down`, `arrow.up`, `sidebar.right`, `arrow.triangle.branch`.

## Files
- `screenshots/`: one PNG per screen, named by id (e.g. `2a-build-session.png`), light appearance. Use them as visual targets; this README and the HTML are the source of truth for values. Known capture artifact: toolbar pills (e.g. branch name, "Ask before edits", "Open in Zed") sometimes wrap onto two lines in the PNGs. They are single-line capsules and must never wrap.
- `Piopio.dc.html`: all screens (Turns 2–8), light/dark via the `appearance` prop.
- `support.js`: runtime needed to open the HTML file locally. Not part of the app.
