# Grey ink in the app

What of this handoff ([README](README.md), `Piopio grey.dc.html`, renders of every screen in `screenshots/`) the SwiftUI
app implements, and where. The rule followed: build what the design shows for features Piopio has; leave out what it
shows for features Piopio doesn't have yet.

| Screen | Status | Where |
|---|---|---|
| Tokens, buttons, status (principles 1–7) | Done | `PiopioTranscript/DesignTokens.swift`, `Design.swift` (`PillStyle`, `SelectorStyle`, `IconButtonStyle`, `RunningRing`, `sidePanel`) |
| 9a Window: flush sidebar, traffic lights in a 52pt bar, toggle + compose, Search/Home/Needs you, sections with +, footer | Done | `Shell.swift`, `RootView.swift`, `MainSidebar.swift` |
| 9a Toolbar and inspector (no cost in the header; context and cost in the inspector footer) | Done | `Shell.swift` (`PageHeader`), `BuildViews.swift`, `BuildReview.swift` |
| 10a New ⌘N menu with subtitles | Done | `MainSidebar.swift` (`NewMenu`) |
| 10b Search ⌘K: results first, actions after, no icons | Done | `CommandPalette.swift` |
| 10d Collapsed sidebar (lights and toggle in the toolbar) | Done | `RootView.swift`, `Shell.swift` |
| 10d Diff review: file list, Unified/Split, line comments | Restyled | `BuildReview.swift` (`DiffReview`) |
| 10e Settings: plain list, grey tiles | Restyled | `SettingsView.swift`, `SettingsParts.swift`, `ModelsSettings.swift`, `ProvidersSettings.swift` |
| 10f Quick Chat | Restyled (tokens) | `QuickChat.swift` |
| 11a Turn: bubble radius 12, grey process line, code blocks on the bubble fill, message footer | Done | `PiopioTranscript/Cards.swift`, `ItemRenderer.swift` |
| 11b While working: queued messages above the box, stop button, "esc to stop" | Done | `Composer.swift` |
| 11c Approvals: one card, question title, text secondaries, black Allow; decided → grey line | Done | `BuildViews.swift` (`PromptCard`, `askCard`), `ItemRenderer.swift` (agent approvals) |
| 11d Questions: numbered options, "Something else…" | Done | `BuildViews.swift` |
| 11e–11g Composer, model menu (thinking as a segmented control), mode menu | Done | `Composer.swift` |
| 11h Interruptions: grey lines with links, no red boxes | Done | `ItemRenderer.swift` |
| 12 Debate | Restyled (no speaker colors, no colored severities) | `DebateViews.swift`, `DesignTokens.swift` |
| 13a Agent: one conversation + info panel | Done | `AgentViews.swift` (`AgentPage`, `AgentInfoPanel`), `AgentAvailability.swift` |
| 13e/13f Notebook | Restyled, structure kept (see below) | `SpaceViews.swift` |
| 14a Home | Done | `HomeView.swift` |
| 14b Needs you | Done | `NeedsYou.swift` |

## Differences from the mock-up, on purpose

- **Not shown, not built yet:** Telegram in "Reaches you in", "Keep it always on" (cloud), "Commit N files" in the diff
  toolbar (commit stays in the inspector), ⇧⇥ to cycle modes, number keys to pick an answer, "1 of 2" question steps,
  Skip, "Open in Zed" as a fixed label (the Open menu remembers the last app), queued message Edit, the code block's
  filename + Copy header, "Read only" mode.
- **Notebooks keep topic tabs** (13e/13f are one conversation with headings and Decided/Open states; the engine keeps one
  conversation per topic and has no topic states). The tabs use an ink underline; the right column is Topics with a
  grey status line, then Remembers.
- **Agent creation (13b)** stays the form sheet; drafting an agent from one sentence needs engine work.
- **Kept features the mock-up doesn't draw:** Pinned, Debate in the New menu, the search scope menu in ⌘K, Full auto
  below a divider in the mode menu, web search on/off in chat, the person picker on agents with contacts, Activity and
  full Setup (opened from the info panel, with a breadcrumb back), the git menu in Build, chat cost under ⋯ › Cost….
- **Answer text** stays at the 15 / 1.45 set on 2026-10-29 ("like Claude's") rather than the mock-up's 14.5 / 1.6.
- **The sidebar's inline filter** became the Search row, which opens ⌘K (it already searches every item).
- **Onboarding** still shows the chick; the rest of the app has no mascot or yolk.

## Captures

`app/` holds captures of the app with the faux model: Home, a chat, a Build approval, an agent, and a Build session
with the sidebar collapsed in dark mode.
