# v2 in the app

What of the v2 handoff ([README](README.md), `Piopio v2.dc.html`) the SwiftUI app implements, and where.

| Screen | Status | Where |
|---|---|---|
| Sidebar (one list: Home, Needs you, Pinned, Projects, Notebooks, Agents, Chats; collapsible, capped, muted hints) | Done | `MainSidebar.swift`, `Navigation.swift` |
| 0a Home (greeting, ask box with @mentions, Needs you, Running now, Coming up, Jump back in) | Done | `HomeView.swift` |
| 0b Projects index (Active/All/Archived, sort, filter) | Done | `IndexViews.swift` |
| 1a–1c Needs you feed (inline approve, reply, raise budget) | Done | `NeedsYou.swift` |
| 2a Build session (folded activity line, follow-ups, Changes/Files inspector, timeline, context) | Done | `BuildViews.swift`, `BuildReview.swift`, `PiopioTranscript` |
| 2b Chat (folded activity, follow-up capsules, Move to Notebook) | Done | `ThreadView.swift`, `ChatExtras.swift` |
| 4a Notebook (underline tabs, compact routing rows, memory line, Progress + memory inspector) | Done | `SpaceViews.swift`, `ItemRenderer.swift` |
| 5a Memory sheet (facts, provenance, suggested facts, Markdown, history) | Done | `SpaceViews.swift` |
| 6b–7c Agent page (Chat · Activity · Setup, side card with "Teach it 3 things") | Done | `AgentViews.swift` |
| 8a Agent Setup (grouped cards, jump list, save bar, View as JSON) | Done | `AgentDefinitionView.swift` |
| 9a Settings › Models (grouped sidebar, providers card with spend, default model per mode) | Done | `SettingsView.swift`, engine `usage.summary` |
| 10a Model picker (detail pane, $–$$$ tiers, folded variants, ⌘↩ set as default) | Done | `ModelPicker.swift` |
| 11a–c Empty states (drop zone, repos found, pi CLI import, templates) | Done | `EmptyStates.swift` |
| 12b Conversational first run | Done | `WelcomeView.swift` |

## Differences from the mock-up

- Routing in a notebook's Main is one compact row per message (topic, status, Open ›, Change) rather than one card grouping every topic a message started; the engine records one routing item per message.
- The model picker's "You've spent" fact is left out: spend isn't tracked per model yet. The description line is derived from the model's capabilities.
- Default models per mode are stored by the app (`buildModel`, `defaultChatModel`, `quickChatModel`, `agentModel`); Build and agents fall back to the chat default.
- The Composer's "Auto-route" chip in notebooks isn't drawn; routing is automatic and `@topic` picks one.

## Captures

`screenshots/` holds captures of the app with the faux model (12b, 11a, 11c, 9a, 10a, 4a, 3a).
