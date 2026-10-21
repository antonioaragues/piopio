# Handoff: Piopio v2 — one sidebar, calmer screens, more personality

## Overview
A redesign of the Piopio macOS app (repo `antonioaragues/piopio`, SwiftUI in `apps/mac/App/Piopio`). Main changes:
1. **The Build · Chat · Agents mode switcher goes away.** It's replaced by **one sidebar** with Home, Needs you, Pinned, Projects, Notebooks, Agents and Chats. The type of the selected item decides which view the content area shows.
2. **"Needs you"** is a single triage feed for everything that needs the user: approvals, agent messages, topic questions and budget pauses. The Agents › Inbox goes away and is replaced by this feed.
3. **Home** is the default landing screen.
4. Changes to individual screens: folded tool activity in Build, chat dead ends become actions, Notebook routing collapsed into one note plus a progress inspector, memory as a list of facts, agent page opens on the conversation, grouped agent settings, a split Settings › Models page, a model picker with recent models and a detail pane, a shared empty-state pattern, and a conversational first run.
5. **Personality:** the app icon chick plus a "yolk" yellow, used only at brand moments (Home, empty states, onboarding, suggestion cards). The system accent color still drives all actions and selection.

## About the design files
The files in this bundle are **design references built in HTML**. They show the intended look and behavior; they are not production code. Recreate them in the existing SwiftUI app using its patterns: `Design.swift` (`GlassPanel`, `PillStyle`, `SectionLabel`, `StatusDot`, `EmptyState`, `CardTile`), native materials, `NavigationSplitView`, SF Symbols and the system accent. To view the files, open `Piopio v2.dc.html` in a browser with `support.js` and `Piopio Sidebar.dc.html` in the same folder. The page is a pan/zoom canvas, and each screen has an id badge (0a, 1b, 2a…).

Glyphs in the HTML (⌕ ⌂ ◉ ◫ ⑂ ⌄ › ↑ ⋯ ⚙︎ ✦ ⌁) stand in for **SF Symbols**: `magnifyingglass`, `house`, `tray.full` / `bell.badge`, `sidebar.right`, `arrow.triangle.branch`, `chevron.down`, `chevron.right`, `arrow.up`, `ellipsis`, `gearshape`, `sparkles`, `puzzlepiece`. Emoji avatars (☀️ 🌱) are user data; they match today's agent avatars.

## Fidelity
**High-fidelity** for layout, hierarchy, copy, spacing and tokens. Where macOS has a native control (segmented controls, toggles, sheets, menus, popovers, materials), use it and match the spirit instead of copying the HTML pixel for pixel. All sample data is illustrative.

## Window & shell (every main-window screen)
- Reference window: 1280×800, corner radius 18, background `win`.
- **Sidebar:** 268 wide, floating glass panel inset 8, radius 14, 0.5pt edge, panel shadow. Top to bottom:
  - Traffic-light row, 38 tall. A **"+ New ⌄"** capsule sits on the right: a menu with New session… ⌘N (asks which project), New chat, New notebook ⌘⇧N and New agent.
  - Search field: 28 tall, radius 8, `chip` fill, "Search" with "⌘K" hint. Typing filters the sidebar in place.
  - **Home** (⌂) and **Needs you** (◉ with an amber count badge: 18 tall, capsule, white 11 bold).
  - Sections, each with an 11 semibold `fg3` header, an optional count ("Projects · 6") and a "+" on the right: **Pinned · Projects · Notebooks · Agents · Chats**.
  - Footer, 40 tall: green dot · "This Mac" · "$0.05 today" · gear (opens Settings).
- **Row types** (radius 8; selected = `accentSoft` + semibold):
  - Project or notebook: 18pt colored tile with an initial (radius 5), name, optional mono trailing branch.
  - Session or topic: indented 26, 7pt status dot.
  - Agent: 26pt round avatar with a status dot bottom-right and a 2-line row (name + "Next run tomorrow 7:00").
  - Chat: plain row.
  - "N earlier sessions" / "N more ›": muted rows that expand the list or open the index.
- Content toolbar: 60 tall. Title 15 semibold plus an 11.5 `fg3` metadata line ("financial_ia · main · ● Done · $0.0011"). Capsule pills on the right, 28 tall.
- Inspector (when present): 288–300 wide, floating glass, inset 8 (0 on the left), radius 14.
- Composer: floating glass, radius 20, max-width 600–720, 20 from the bottom. Placeholder 13.5 `fg3`, a row of 24-tall chips and a 28pt circular send button (`inv`).

## Screens (ids match the badges in the HTML)

### 0a · Busy sidebar rules (long lists)
- **Only what's live:** under each project, show sessions that are running, waiting on you, or updated in the last 3 days. The rest fold into "N earlier sessions".
- **Waiting/running first:** these sort to the top of their project and are also counted in Needs you.
- **Per-section cap:** show the most recent few, sized to the window. The header count and "N more ›" open the full index (0b).
- **Pin and collapse:** Pinned keeps any item at the top. Clicking a section header collapses it, and the state persists.
- **Search filters in place**, including folded items. ⌘K is the global palette.
- **Auto-archive:** done sessions and chats idle for 30 days move to Archived. Nothing is deleted.

### 0b · Projects index
- Page title 26 bold, −0.02em. Subtitle "6 projects · 23 sessions · 2 need you". Primary "Open Folder… ⌘O" (`inv`).
- Filter field plus a segmented control **Active / All / Archived** and a "Recent ⌄" sort.
- Table card (radius 12) with columns Name / Branch (mono 12) / Changes (+/−) / Updated. Project rows expand to sessions (indent 58) with status dots; "Needs you" is shown in amber. Each expanded project ends with a "Show N earlier sessions" link.

### 1b · Home
- Centered column, max 820, top padding 56.
- Greeting row: 52pt round chick with a 3pt `yolkSoft` ring, "Good evening, Antonio" 26 bold, and a 13.5 `fg2` line: "Tuesday 21 October · 3 things need you · $0.05 spent today".
- **Ask box:** card, radius 16, soft shadow. Placeholder "Ask anything, start a build session, or message an agent…". Chips: target "New chat ⌄" and model. Hint: "@financial_ia starts a session · @Daily briefing messages the agent". Send button.
- 2-column grid (1.3fr / 1fr):
  - **Needs you** list card. Rows have a status dot, a 13 semibold title, a 12 `fg3` source and inline actions (Deny / **Allow** in accent; Read; Answer).
  - **Running now** card (spinner ring, name, "Editing import_preview.tsx · +84 −12") and **Coming up** (☀️ Daily briefing · Tomorrow at 7:00 · Run now).
- **Jump back in:** 3 `chip` cards (kind label 11 semibold `fg3`, title 13 semibold, meta 12 `fg3`).

### 6b · Needs you (triage feed)
- Column max 680. Title "Needs you" 26 bold. Subtitle "3 items · oldest first". Filter capsules "All 3" (`inv`) / "Approvals 1" / "Messages 2".
- **Top card** uses the decision halo (1px `accentLine` border + 4px `accentSoft` ring, radius 14):
  - Avatar, "Daily briefing wants to know where you are", "Automatic run · 7:02", "Read briefing ›".
  - The quoted question.
  - An **inline reply field** (36 tall, `chip`) with a "Send ↩" accent button.
- **Other cards** (0.5 line, radius 14) have an amber dot, a title and subtitle, and two actions:
  - "Habit coach paused itself": Keep paused / **Raise to $2** (`inv`).
  - "Run `pnpm test`?": Deny / **Allow once** (accent).
- **End state:** 44pt chick at 90% opacity plus "That's everything. Piopio will chirp when something new comes in."

### 2a · Build session (now uses the one sidebar)
- Toolbar: title, meta line, "Open in VS Code ⌄", terminal "›_", inspector toggle ◫ (active = `accentSoft` with accent glyph).
- Transcript column max 640:
  - User bubble (`bubble`, radius 16/16/4/16).
  - **Folded activity line**, 12 `fg3`: "✓ Worked for 4s · read README.md, package.json, REQUIREMENTS.md · 1 command ›". It expands to the existing tool cards. It replaces the separate Thought and Ran cards.
  - Prose 13.5/1.6 with 13.5 semibold subheads.
  - Structure shown as a small card grid (mono path 150 wide + description).
  - Message footer "Copy · Retry · Fork … Haiku 5.5 · $0.0006".
  - **Suggested follow-ups:** 28-tall outlined capsules.
- Composer chips: "● Ask before edits" (amber dot = approval mode), model, "Think · medium".
- Inspector:
  - Segmented **Changes | Files**.
  - Empty Changes card: "No changes yet" / "Edits land here as the agent makes them. Each turn saves a checkpoint first, so you can roll back."
  - **Timeline:** a vertical line with per-turn dots (green = answered, hollow = checkpoint, "Restore…").
  - Footer: Context bar "7k of 1M" (4pt) and "This session $0.0011".

### 3a · Chat (light)
- Toolbar actions: "Move to Notebook…" and ⋯. No inspector by default; it opens only when there's content.
- The attached folder appears as a chip above the user bubble.
- Folded activity line.
- **Dead-end card:** folder tile, "~/Proyectos/smart-paste", "Empty folder · not a git repo", Reveal in Finder / **Choose another folder…**.
- "You could also" suggestion capsules.
- The composer shows the folder chip.

### 4a · Notebook
- Underline tabs: Main · Distribución (amber dot) · Muebles (accent dot) · Colores · + Topic. They replace the filled capsule row.
- **Routing note** (one `chip` card): "Organizer created 3 topics and shared the measurements · Change", then one row per topic (status dot, name, one-line summary, Open ›).
- Memory write line: "✎ Saved 2 facts to notebook memory · Undo".
- Recommended order as numbered rows (20pt circles).
- Inspector:
  - **Progress** "0 of 3 decided" with a 3-segment bar.
  - Topic cards ("1 · Distribución — Needs you — Which wall has the window?").
  - **Memory** key/value preview (Size, Budget, To decide) with an "Open" link.

### 5a · Memory sheet
- Sheet 880×620, radius 18. Header "Memory" 20 bold, subtitle "Kitchen renovation · every topic reads these facts", segmented **Facts | Markdown**, Done.
- **Fact rows** in a card:
  - 11 semibold label column (64 wide), fact 13.5/1.5, provenance 11.5 `fg3` ("From Main · Organizer · 20 h ago").
  - The selected row is tinted and shows Edit / Forget (red).
  - "+ Add a fact every topic should know…" row below.
- **Suggested by topics:** `yolkSoft` card with Dismiss / **Save fact**.
- Right panel, 250 wide: History with Restore links.

### 7c · Agent page (recommended)
- Header: 36pt avatar, name 17 bold, "● This Mac · every day 7:00", a "with Antonio (you) ⌄" contact picker (other contacts' conversations), and Run now.
- Tabs **Chat · Activity · Setup** (5 tabs become 3; "Conversations" moves into the contact picker; "Runs" becomes Activity; "Memory" moves into the side card and Setup).
- Transcript:
  - Run divider "Automatic run · today 7:00".
  - Agent message with avatar and footer "Searched the web · 6s · $0.0009".
  - Suggested reply capsules.
- Side card (300):
  - **Next run** 22 bold, plus "Last: today 7:00 · 6s · ✓".
  - **"Teach it 3 things" checklist** (`yolkSoft`, chick 24, "0 / 3").
  - Key/values: Can / Reaches you via / Model / This month.
  - "Edit in Setup ›".

### 8a · Agent Setup
- Header: avatar 36, name 18 bold, amber "● 1 unsaved change", Revert, **Save ⌘S** (accent).
- Left jump list (170): Instructions · Model · Abilities · Mac apps · Schedule · People, plus "View as JSON" at the bottom (replaces the JSON toolbar button).
- Sections are native grouped cards (radius 12, inset dividers):
  - **Instructions:** Markdown, token count; unsaved lines highlighted with `addbg`.
  - **Model:** Model picker row, Thinking row.
  - **Abilities:** human names with the tool ids as subtitles, a permission label (Allowed / **Asks first** in amber) and a switch.
- Tools that aren't available yet are **hidden**, with one note: "HTTP requests, code and workspace files are coming later and stay hidden until then."

### 9a · Settings › Models
- Settings sidebar groups: General, **Models**, Chat, Approvals | *Extend:* MCP servers, Extensions | *Where it runs:* This Mac & cloud.
- Title "Models" 24 bold, subtitle "Billed to your own accounts. Keys stay in the macOS Keychain."
- **Providers** card:
  - OpenRouter row: 32pt "OR" tile, name, "● Connected", masked key in mono, "$0.47 this month", ⋯ menu (Replace key, Remove).
  - ChatGPT subscription row at 60% opacity with a "Coming soon" badge.
- **Default model** card, one row per mode: Build sessions / Chats and notebooks / Quick Chat ("Pick something fast") / New agents, each with a model capsule menu.

### 10a · Model picker (popover 760×520)
- Search plus capsules All / Reasoning / Vision / Free.
- Left list:
  - **Recent** first; the selected row is filled with accent and white text.
  - Then provider groups, with price tier shown as $–$$$.
  - Batch and alias variants are folded: "Show batch and alias variants (4)".
- Right detail pane (300): provider tile, name 15 bold, id in mono, a one-line description, Input/Output price tiles, Context / Reasoning / Images / You've spent.
- Footer: "↑↓ move · ↩ choose · ⌘↩ set as default".

### 11a–c · Empty states (one pattern)
Centered layout: 72pt round chick with a 6pt `yolkSoft` ring, title 22 bold, one sentence 14 `fg2` (max ~420), then real starting points.
- **Build:** "Point Piopio at some code". A dashed drop zone (96 tall, radius 14) with **Open Folder… ⌘O**. "Found in ~/Proyectos" lists detected repos with Add. "Using the pi CLI? Import 12 sessions from ~/.pi".
- **Chat:** "What's on your mind?". An inline composer card, plus New chat ⌘N / New notebook ⌘⇧N tiles and the Quick Chat tip.
- **Agents:** "Hatch your first agent". 3 template cards (Daily briefing, Habit coach, Reading list) and "Start from scratch…".
- The sidebar shows muted hint rows per section ("Folders you add show up here").

### 12b · First run (conversational)
- Full window, column max 620, top 90. A 48pt chick with a `yolkSoft` ring "speaks":
  - Title "Pío pío! I'm Piopio." 22 bold, then an intro at 15/1.55 `fg2`.
  - An inline **OpenRouter key card** with live verification ("✓ Verified").
  - Next message: "That works. What should we do first?".
  - 3 choice rows: Look at a project → Build, Just ask something → Chat, Get a morning briefing tomorrow → creates the Daily briefing agent.
- Footer: "Skip setup · you can change all of this in Settings".

## Interactions & behavior
- ⌘K palette · ⌘N new (contextual to the selection) · ⌘⇧N notebook · ⌘O open folder · ⌥Space Quick Chat · ⌘S save the agent draft · ↩ on the focused approval = Allow once.
- Needs you items can be resolved inline. Resolving one removes it from the feed and decrements the sidebar badge and the Dock badge.
- Folded activity lines expand on click into the existing collapsible tool cards.
- Suggestion capsules send their text as the next message, or run the action (Choose another folder…).
- Sidebar section collapse, pins and the Active/All/Archived filter persist (`@AppStorage`).
- Transitions: system defaults only.

## State (additions)
- `selection: SidebarItem` (home | needsYou | project(id) | session(id) | notebook(id, topic?) | agent(id) | chat(id)). It replaces `mode` plus per-mode selection.
- `pinned: [ItemID]`, `collapsedSections: Set<Section>`.
- `NeedsYouItem { kind: approval | agentMessage | topicQuestion | budgetPaused, source, title, body, actions, createdAt }`, aggregated across engines.
- Agent: `nextRunAt`, `lastRun {at, duration, ok, cost}`, `onboardingChecklist`.
- Memory fact: `{label, text, source {container, messageId}, author, createdAt, pinned}` plus `suggested` facts from topics.

## Design tokens
Same as `docs/design/README.md` (`Design.swift` / `DS`), plus the brand tokens:

| Token | Light | Dark | Use |
|---|---|---|---|
| win | #fdfdfc | #1a1a1c | window |
| glass | rgba(242,242,246,.78) | rgba(40,40,44,.85) | sidebar, inspector, composer |
| card | #ffffff | #242426 | cards |
| chip | rgba(0,0,0,.045) | rgba(255,255,255,.08) | chips, fields, secondary buttons |
| bubble | #f1f1f3 | #2e2e31 | user bubble |
| pill | rgba(255,255,255,.9) | rgba(74,74,78,.95) | toolbar pills, selected segment |
| fg / fg2 / fg3 | #1d1d1f / #5b5b61 / #8e8e93 | #f5f5f7 / #b8b8bd / #8e8e93 | text |
| line | rgba(0,0,0,.08) | rgba(255,255,255,.12) | hairlines 0.5pt |
| inv / invfg | #1d1d1f / #fff | #f5f5f7 / #1d1d1f | strong buttons, send |
| accent | system accent (#0a84ff) | same | actions, selection, running |
| accentSoft | accent 14% | accent 26% | selection, halo |
| accentLine | accent 45% | accent 60% | decision borders |
| green / amber / red | oklch(.64 .15 150) / (.74 .15 70) / (.62 .18 25) | same | done / waiting / failed |
| addbg | oklch(.96 .035 150) | oklch(.32 .06 150) | unsaved/added lines |
| **yolk** (new) | oklch(.88 .16 92) ≈ #F7CE3E | same | brand only |
| **yolkSoft** (new) | oklch(.97 .04 92) ≈ #FDF7E1 | oklch(.30 .05 92) | brand cards: suggestions, checklist, chick rings |

Type (SF Pro / SF Mono):
- 32/28 bold (onboarding/welcome) · **26 bold −0.02em (page titles: Home, Needs you, Projects)** · 24 bold (Settings page, agent name) · 22 bold (empty-state and section titles) · 17–18 bold (header names)
- 15 semibold (toolbar title) · 13.5/1.6 (transcript) · 13 (UI) · 12 (chips, secondary) · 11 semibold `fg3` (section labels) · SF Mono 12 (paths, branches, keys)

Radii: window/sheet 18 · composer 20 · glass panel 14 · large cards 14 · cards 12 · rows/fields 8–10 · capsules. Spacing: 4pt grid (4·8·12·16·20·28·40). Decision halo: `0 0 0 4px accentSoft` + 1px `accentLine`.

**Status vocabulary (unchanged):** amber = waiting on you · accent ring = running · green = done/live · grey 50% = idle · red = failed.

## Assets
- `assets/chick.png`: the app icon art (`apps/mac/App/Piopio/AppIcon.icon/Assets/chick-light.png`). Use the existing icon asset, with a dark variant from `chick-dark.png`. Crop it into a circle for the avatar uses.
- Everything else: SF Symbols (see the mapping above).

## Files
- `Piopio v2.dc.html`: all chosen screens (0a, 0b, 7c, 1b, 6b, 2a, 3a, 4a, 5a, 8a, 9a, 10a, 11a–c, 12b). Tweaks: appearance light/dark and an accent preview.
- `Piopio Sidebar.dc.html`: the sidebar as a data-driven component (the `busy` and `empty` props show the long-list and empty variants).
- `support.js`: runtime needed only to open the HTML locally.

## Suggested implementation order
1. Replace `ModeSwitcher` and the per-mode `Sidebar` lists with the unified sidebar plus a `SidebarItem` selection in `RootView.swift`.
2. Needs you aggregation and feed, replacing `InboxView`.
3. Home.
4. Agent page tabs (Chat · Activity · Setup) and the Setup grouping (`AgentViews.swift`, `AgentDefinitionView.swift`).
5. Build/Chat transcript folding and suggestions, Notebook routing note and inspector, memory facts.
6. Settings › Models split and model picker detail pane.
7. Empty states and first run (`Design.swift` `EmptyState`, `WelcomeView.swift`).
