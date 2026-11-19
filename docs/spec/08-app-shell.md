# 08 — App shell & UX

## 1. Window structure
- A single main window type (multiple windows allowed), built on `NavigationSplitView`: **sidebar | content | inspector**.
- **Mode switcher** in the sidebar header: `Build · Chat · Agents` (⌘1 / ⌘2 / ⌘3). Each mode remembers its own selection.
- Toolbar (content): container title, model chip, mode-specific controls (branch, approval mode, space memory…), share/export, inspector toggle (⌘⌥I).
- Native look: Liquid Glass materials on macOS 27, system accent color, SF Symbols, full Dark Mode support, and Dynamic Type where SwiftUI supports it on macOS. Settings › General › Appearance: System (follows macOS, the default), Light or Dark, for the whole app (2026-11-04).

## 2. Sidebar (per mode)
- Build: Projects → sessions (status icons).
- Chat: Pinned · Spaces (→ topics) · Projects (chat lens) · Threads (grouped by Today / Yesterday / Last 7 days / Older).
- Agents: Inbox · Agents (status, local/cloud badge).
- Common: search field (filters the sidebar; ⌘⇧F opens global search), drag to reorder pins, context menus (rename, pin, archive, export, delete, reveal in Finder).

## 3. Transcript
- **TR1** One **windowed** TextKit 2 document per session (Spikes S2/S2b). It holds the newest ~300 items, and older history is prepended in small pages (≈10 items, built off the main thread) as the user nears the top, keeping the visible text anchored. Jumping to an old item re-windows around it. Card chrome comes from custom layout fragments, and interactive cards (tool, routing, approval) are attachment views that may host SwiftUI. Budget: < 5 ms/s hitch time while scrolling and streaming; the tail is on screen in < 200 ms when opening a session. The scroll position is kept when streaming above the fold.
- **TR2** Auto-scroll follows the stream unless the user scrolls up. A "Jump to latest" pill appears when not following.
- **TR3** Item renderers are listed in 03-engine-protocol §4. Each tool card is collapsible, with a global "Collapse tool calls" toggle.
- **TR4** Message actions on hover: copy, edit (user), regenerate (assistant), fork from here, copy as markdown, show raw.
- **TR5** Text selection across messages, and ⌘F find in transcript.
- **TR6** Every item has a timestamp on hover and a "details" popover (model, tokens, cost, latency, ids).

## 4. Composer
- Multiline (⇧Enter newline). Enter sends. While busy: Enter = queue follow-up, ⌥Enter = steer, Esc = abort.
- @-mentions (files, topics, agents depending on context), /commands, attachments (drag/drop/paste), model chip, thinking level, tools toggle menu.
- Draft per container, persisted.
- Shows the queued inputs list above the composer when not empty.

## 5. Global features
| Feature | Shortcut | Notes |
|---|---|---|
| Command palette | ⌘K | Navigate to anything, run actions (new session, switch model, deploy agent…) |
| Global search | ⌘⇧F | FTS across all containers, filter by mode/date/model |
| Quick Chat | ⌥Space (global) | Floating panel (04-chat §4) |
| New (contextual) | ⌘N | In a project, the new session page there; otherwise the chat start page. Each sidebar + opens its own start page (project, chat, agent); ⌘⇧N the project one. Nothing is created until you start (docs/design/start-pages). |
| Model picker | ⌘M | |
| Approvals inbox | ⌘⇧A | All pending approvals |
| Settings | ⌘, | |

## 6. Notifications & attention
- `UserNotifications` for: session finished (when not focused), approval needed, agent message to owner (in-app channel), deploy result, budget alerts. Each type can be configured.
- Dock badge = pending approvals + unread agent messages.
- **Menu bar extra:** running/waiting sessions, pending approvals (approve inline), agent status, Quick Chat, engine status. Present when background mode is on.

## 7. Accessibility & i18n
- VoiceOver labels for all custom views. Full keyboard navigation in sidebar, transcript and diffs.
- UI in English for v1, with strings localized via String Catalogs from day one.

## 8. iOS readiness (X5)
- PiopioKit (client, protocol types, stores) MUST be platform-neutral Swift (no AppKit in the package). AppKit bridges live in the app target.
- The transcript's attributed-string builder and TextKit 2 layout fragments are platform-neutral (TextKit 2 exists in UIKit), and only the text-view wrapper differs per platform.
- The cloud engine's direct WebSocket API (03-engine-protocol §1) is what iOS will use.

## 9. Export (built 2026-11-19)
Every conversation exports the same way: a chat, a Build session, an agent's chat with you, a contact's conversation
with it, a conversation between agents, and a run. Options reviewed in [docs/design/export](../design/export/Export.html);
the user chose 1A · 2A · 3A.
- **EX1 Same rows everywhere.** Copy as Markdown, then an **Export ▸** submenu with Markdown…, HTML… and JSONL…. One
  view (`ExportMenuItems`) draws them in a chat's, a Build session's and an agent's ⋯ menu and in the right-click menu
  of chat, session and agent rows in the sidebar. The command palette offers Export as Markdown, HTML and JSONL, and
  Copy, for the conversation on screen in any area, named Chat, Session or Agent Chat.
- **EX2 Agents export what's on screen.** In an agent's ⋯ menu the submenu says which conversation: Export Chat, Export
  Conversation with <name>, Export This Run. An agent's sidebar row exports your chat with it. There is no export of
  all of an agent's conversations, and none of a whole project. Settings › Backup keeps everything.
- **EX3 The file says what it is.** Under the title is a line with what was exported ("Chat", "Build session in
  piopio", "Agent run", "Between agents"), the models used and the date. An agent's answers are under its name. Items
  that chats don't have come out too: an agent's folded steps (thinking and tool calls), messages between agents and
  their replies, approvals and how you answered, result cards (with "(undone)"), and Build checkpoints. A run's file is
  called "<agent> › Run <date time>". An untitled export is "Conversation".
- **EX4 It works without the conversation open.** `sessions.export` also returns the visuals the export shows
  (`visuals: [{callId, title, html}]`), and the app draws them in their markers' places (docs/spec/25 §16).
- Not part of this: memory export (Settings › Memory), backup (Settings › Backup & costs) and the usage CSV keep their
  own buttons.
