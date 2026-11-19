# Handoff: Agents and Automations (spec 27, phase A2)

## Overview
Splits Piopio's **agents** (who: an assistant you talk to) from **automations** (when: work that runs when nobody started it). Scope of this handoff:

1. **Sidebar + Agents navigation, "keep sidebar" model:** clicking Agents leaves the main sidebar in place and opens the agent list as a second column. The agent's page fills the rest of the window.
2. **Automations:** the list, an automation's page (the editable sentence), and the empty state.
3. **Creation card in chat:** the moment an automation is born, with Undo. Also the "From <automation> · 08:00" label on unrequested messages.
4. **Agent Setup:** who the agent is, with no schedules.

Dropped from earlier explorations: drill-in and icon-rail navigation, the gallery and portrait layouts (1a–1c), the config side panel with a Schedule tab (2a), Home and Project settings mocks. Home and Project rules from the brief still apply, but they aren't mocked here.

## About the design files
`Agents and Automations.dc.html` is a **design reference built in HTML**: a clickable prototype showing intended look and behavior. It is not production code. Rebuild it in Piopio's SwiftUI codebase using its existing patterns and the `docs/design/grey` tokens. Open the file in a browser. `support.js` must sit next to it. The pills above the window jump to each screen.

## Fidelity
**High-fidelity.** Colors, type sizes, spacing, radii and copy are final for light mode. Dark mode isn't mocked; use the grey Dark column below. Fonts are system (SF Pro). Avatars are initials on tinted squares, placeholders for real agent avatars.

## Window layout
- Window: 1360×880 reference size, background `#FCFCFB`, radius 12 (native window).
- **Main sidebar:** 250px, `#F4F4F2`, right hairline `rgba(0,0,0,.09)`. It never changes when you navigate.
  - Rows: 13px, padding 6px 10px, radius 7. Selected row bg `#EAEAE6`.
  - Order: Search (⌘K hint, `#9B9B96`) · Home · **Automations** (count of *on* automations, right-aligned 11px `#6B6B67`, tabular) · **Agents** (count) · section "Agents" (12px `#9B9B96`, "+" on the right) with one row per agent (22px avatar r7, name, channel in 11px `#9B9B96`) · section "Projects" · section "Conversations" · footer (26px avatar circle, "Antonio", "This Mac · $0.04 today" 11px `#9B9B96`), top hairline.
- **Content area:** flex 1.

## Screens

### 1. Agents (keep sidebar)
**Entry:** the sidebar's **Agents** row (opens the last selected agent) or an agent row under "Agents" (opens that agent's Chat). The **Agents** row is highlighted. Agent rows in the sidebar are shortcuts and are never highlighted.

**Agent list column:** 264px, bg `#F8F8F6`, right hairline.
- Header: "Agents" 20px/700, letter-spacing −0.02em, padding 22 16 12. "+" button 28×28, r8, `#1F1F1E` bg, white glyph (New agent).
- Search field: margin 0 12 10, padding 7 10, r8, bg `#EFEFEC`, placeholder "Search agents" `#9B9B96`.
- Row: padding 9 10, r11, gap 11. Avatar 40×40 r13 (tinted bg, initial 16px/650). Name 13px/600. Time 11px `#9B9B96`, right. Preview 12px `#6B6B67`, single line with ellipsis. Selected row bg `#EAEAE6`.
- **No schedule column, no "schedules" in any subtitle.**

**Agent page, header:** padding 24 40 0, bottom hairline.
- Avatar 64×64 r20, initial 26px/650. Name 24px/700, −0.02em. Line "{what it's for} · {model}" 13px `#6B6B67`.
- Right: link "2 automations ›" (accent `#2F6FEB`, bg `rgba(47,111,235,.08)`, padding 6 10, r8). It opens Automations filtered to this agent. Singular: "1 automation ›".
- Tabs **Chat · Setup**: 13px, gap 22, padding-bottom 10. Active: 600, `#1F1F1E`, 2px bottom border `#1F1F1E`. Inactive: `#6B6B67`.

### 2. Chat + creation card
Column max-width 720, centered, padding 0 32, gap 18.
- **Unrequested message:** above the text, a pill label "From **Daily price check** · 08:00" (11.5px, `#6B6B67`, bg `#F0F0ED`, padding 3 9, r99; hover text goes accent). Click opens that automation. Agent text has no bubble, 13px, line-height 1.55.
- **Your message:** right-aligned bubble, max 70%, bg `#F0F0ED`, padding 10 14, r16.
- **Creation card:** width 440, bg `#FFFFFF`, border `rgba(0,0,0,.1)`, r14, shadow `0 2px 8px rgba(0,0,0,.04)`.
  - Head (padding 14 16 12, bottom hairline): "New automation" 11.5px/600 accent; name "Weekly competitor brief" 16px/650. The model proposes the name, and it can be renamed.
  - Body: 2-col grid (84px label, gap 8 12). Labels `#9B9B96`: **When · Runs as · Does · Tells you**.
  - Footer strip: bg `#F7F7F5`, 12px `#6B6B67`, a 6px green dot `oklch(0.72 0.14 150)` and the text "Runs on this Mac, only while it's awake · first run Mon 23 Nov".
  - Actions (padding 10 12, top hairline): **Open in Automations** (primary: `#1F1F1E` bg, white, r8, padding 7 12) · **Undo** (secondary: 1px `rgba(0,0,0,.14)` border).
  - **Undo** replaces the card with an inline note: "Undone. Weekly competitor brief won't run. **Redo**" (bg `#F0F0ED`, r10). The automation is removed from the list and the sidebar count updates. Redo restores it.
  - The same card appears when Piopio makes one, in Home or in a project.
- Composer: max 720, bg white, border `rgba(0,0,0,.12)`, r14, placeholder "Message {Agent}", 26px round send button.

### 3. Agent Setup
Column max-width 720, centered, padding 28 40 40, gap 22. Four groups, each with a 13px/600 title and a white card (r12, hairline border) holding rows: padding 12 14, label `#6B6B67` on the left, value on the right, hairline between rows.
- **Who it is:** Instructions (stacked: 12px `#9B9B96` label, then text, line-height 1.5) · Model · Memory ("14 things learned · **View**").
- **What it can use:** Tools · Data.
- **Where you reach it:** Piopio "Always" · Telegram "Connected · @handle" (green `oklch(0.5 0.12 150)`) or **Connect…** · "Slack, WhatsApp" "Later" (`#9B9B96`).
- **Limits:** Without asking · Quiet hours · Budget.
- **Closing block** (bg `#F4F4F2`, r14, padding 16 18): "Rita runs 2 automations. When they run is set in Automations, not here. You can also just ask Rita." Below it, one white row per automation (name 550, when on the right, dimmed to 0.5 if paused; click opens it). Then the link **Open Automations ›**. With none: "Coach doesn't run any automations." (same block, no rows).

### 4. Automations list
Padding 44 56, gap 22.
- Header: "Automations" 28px/700. Subline 14px `#6B6B67`: "Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make one here." Button **New automation** (white, 1px `rgba(0,0,0,.14)`, r8, padding 8 14). It is secondary, so it isn't the primary color.
- Filters: chips (r99, padding 4 11). Selected `#1F1F1E`/white, unselected `#EFEFEC`. Order: All · Piopio · each agent (18px avatar inside the chip). A project filter chip "In shop ×" appears when it's set. Right side: green dot + "Runs on this Mac, only while it's awake" 12px `#6B6B67`.
- **Groups**, in this order and shown only when non-empty: **Needs you** (title `oklch(0.5 0.12 65)`, amber) · **On** · **Paused** (title `#9B9B96`). The group header row doubles as the column header: 11.5px `#9B9B96`, bottom hairline.
- Grid columns: `1.7fr 1fr 1fr 1.25fr 40px`, gap 16, row padding 12 14, row hairline, hover bg `#F4F4F2`, r8.
  - Name 14px/600, with a **New** badge (10.5px/600, accent bg, white, r5) until opened. Below it, the when in 13px `#6B6B67`, ellipsis.
  - Runs as: 22px avatar + name ("Piopio in shop" for Piopio with a project).
  - Tells you: "Rita's chat" · "Telegram" · "A conversation in shop" · "Only if it needs you".
  - Last or next run. Amber when it is waiting for approval.
  - Switch 34×20: on = accent, off = `#D6D6D2`, 16px white knob. Paused rows dim to opacity 0.45 (the switch stays full opacity). Toggling doesn't open the row.
- **Empty state** (centered, max 520): "Nothing runs on its own yet" 18px/650. "Ask Piopio or any of your agents in plain words. They set it up and it shows here." Two example prompts in `#F0F0ED` r12 boxes. "Or use **New automation** above."

### 5. An automation's page
Main column (padding 22 52 40, gap 26) + a **Runs** column of 300px (bg `#F7F7F5`, left hairline).
- Top: "‹ Automations" (`#6B6B67`) · **Run now** (primary).
- Name 28px/700, plus "On"/"Paused" label 12px and a 40×24 switch. The name dims to 0.5 when paused.
- **The sentence** (card: white, r16, padding 22 24): 23px, line-height 1.6, −0.01em.
  > **Every Monday at 09:00**, ask <u>Rita</u> to **summarise what competitors shipped last week**, <u>without a project</u> and <u>tell me on Telegram</u>.
  - When and What are bold (650) and not clickable. To change them, edit the prompt or ask the runner. No time picker in v1.
  - Who, Where and Result are **choosable words**: accent color, 1.5px dotted underline `rgba(47,111,235,.5)`, padding 0 2, r3. While open: bg `rgba(47,111,235,.1)`.
  - Clicking one opens a popover anchored under the word: width 300–310, white, r12, shadow `0 0 0 1px rgba(0,0,0,.09), 0 12px 32px rgba(0,0,0,.14)`, padding 6. Caption 11.5px `#9B9B96`. Rows padding 8 10, r8, hover `#F4F4F2`, accent ✓ on the current choice. Click a row to pick and close. Clicking the same word again closes. Only one open at a time.
  - **Who:** Piopio / each agent (26px avatar, name, line).
  - **Where:** if an agent runs it, the word is grey (`#9B9B96`, grey underline) and the popover shows only the reason: "Only Piopio works in a project. Rita always works without one. To use a project, have Piopio run this." If Piopio runs it: Without a project · In {project}…
  - **Result:** for an agent: Post in Rita's chat (default) · Tell me on Telegram (one of its own channels) · Stay quiet unless it needs me. For Piopio: Start a conversation [in project] (default) · Stay quiet unless it needs me, plus the footnote "Piopio has no channels. To get results on Telegram, have one of your agents run this."
  - Switching the runner resets incompatible fields: agent → project cleared, conversation → agent chat. Piopio → chat/channel → conversation.
  - Helper line under the sentence, 12px `#9B9B96`: "Blue words are choices. To change when or what, edit the prompt below or ask Rita."
- **What it's told:** the editable prompt (white, r10, padding 12 14).
- **While you're away:** a 160px label column with these rows:
  - *If it needs your OK:* two selectable cards (1.5px border, accent when selected): **Wait for me** ("Shows in Home, under Waiting on you", the default) · **Skip this run** ("Tries again next time").
  - *Budget per run:* chips $0.10 · $0.25 · $0.50 · $1.00, plus "It stops and tells you before going over."
  - *It may use:* the runner's tools, plus a link to "Rita's Setup ›" (or "Project settings ›" for Piopio in a project), plus "Never more than Rita already has."
  - *Runs on:* "This Mac, only while it's awake." + "If your Mac is asleep at run time, it runs as soon as it wakes." Always shown, in neutral color, never as a warning.
- **Delete automation:** `oklch(0.55 0.18 25)` (red), text button, at the bottom.
- **Runs column:** cards (white, r12, hairline). Each has its when (550; amber if waiting, accent if running), its cost (right, tabular), what happened, and "Open conversation ›". **Run now** prepends a "Just now · Running…" card. A new automation shows a dashed card: "No runs yet." + "First run: Mon 23 Nov, 09:00".

## State
- `screen`: `automations | automation | agent`. `autoId`, `agentId`, `agentTab: chat|setup`.
- `filter`: `all | <agentKey> | proj:<name>`.
- `pop`: `who | where | result | null` (the popover that's open).
- Automation: `{ id, name, when, runner, project?, result: chat|channel|conversation|quiet, what, prompt, on, isNew, last, next, status: ok|waiting, approval: wait|skip, budget, runs[] }`.
- Rules to enforce in the model: runner = agent ⇒ `project = nil` and result ∈ {chat, channel, quiet}. Runner = Piopio ⇒ result ∈ {conversation, quiet}. An agent may only create automations that run as itself.

## Design tokens (docs/design/grey)
| Token | Light | Dark |
|---|---|---|
| Window | #FCFCFB | #1E1E1D |
| Sidebar | #F4F4F2 | #191918 |
| Agent list column | #F8F8F6 | (derive: #1B1B1A) |
| Card | #FFFFFF | #252524 |
| Bubble / soft fill | #F0F0ED | #2B2B29 |
| Chip / field fill | #EFEFEC | #2B2B29 |
| Runs column / card footer | #F7F7F5 | (derive: #222221) |
| Selected row | #EAEAE6 | #333331 |
| Text · secondary · tertiary | #1F1F1E · #6B6B67 · #9B9B96 | #ECECEA · #A6A6A1 · #77776F |
| Hairline | rgba(0,0,0,.09) | rgba(255,255,255,.10) |
| Accent | #2F6FEB | #5B8DF0 |
| Switch off | #D6D6D2 | — |
| Needs you (amber) | oklch(0.5 0.12 65) | — |
| Live dot (green) | oklch(0.72 0.14 150) | — |
| Destructive | oklch(0.55 0.18 25) | — |

- Type (SF Pro): page title 28/700 (−0.02em) · agent name 24/700 · sentence 23 · list title 20/700 · card title 16/650 · row name 14/600 · body 13 · meta 12 · small 11–11.5.
- Radii: 5 (badge) · 7 (sidebar row) · 8 (buttons, fields) · 10–12 (cards, popovers, rows) · 13–20 (avatars) · 14–16 (big cards) · 99 (chips, switches).
- Spacing: 2 · 6 · 8 · 10 · 12 · 14 · 16 · 22 · 26 · 40 · 52/56.

## Assets
None. Avatars are initials on `oklch(0.91 0.06 h)` with text `oklch(0.45 0.13 h)` (Rita h=25, Coach h=150). Piopio's avatar is `#1F1F1E` with a white "P". Swap in real avatars when they exist.

## Files
- `Agents and Automations.dc.html`: the prototype (open in a browser).
- `support.js`: the runtime it needs. Keep it next to the HTML.
- Source brief: `docs/spec/27-automations.md`, `docs/design/grey`.
