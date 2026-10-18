# 08 — App shell & UX

## 1. Window structure
- A single main window type (multiple windows allowed), built on `NavigationSplitView`: **sidebar | content | inspector**.
- **Mode switcher** in the sidebar header: `Build · Chat · Agents` (⌘1 / ⌘2 / ⌘3). Each mode remembers its own selection.
- Toolbar (content): container title, model chip, mode-specific controls (branch, approval mode, space memory…), share/export, inspector toggle (⌘⌥I).
- Native look: Liquid Glass materials on macOS 27, system accent color, SF Symbols, full Dark Mode support, and Dynamic Type where SwiftUI supports it on macOS.

## 2. Sidebar (per mode)
- Build: Projects → sessions (status icons).
- Chat: Pinned · Spaces (→ topics) · Projects (chat lens) · Threads (grouped by Today / Yesterday / Last 7 days / Older).
- Agents: Inbox · Agents (status, local/cloud badge).
- Common: search field (filters the sidebar; ⌘⇧F opens global search), drag to reorder pins, context menus (rename, pin, archive, export, delete, reveal in Finder).

## 3. Transcript
- **TR1** One TextKit 2 document per session (viewport-based layout; Spike S2 measured 0 ms/s hitches at 2,000 items / 2.2 M chars). Card chrome comes from custom layout fragments, and interactive cards are attachment views. It must stay < 5 ms/s hitch time while scrolling and streaming. The scroll position is kept when streaming above the fold.
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
| New (contextual) | ⌘N | New session / thread / agent depending on mode |
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
