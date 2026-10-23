# Handoff: Piopio — Chat / session thread v3 (option A)

## Overview
This redesigns the conversation thread used by Build sessions and project chats in the Piopio macOS app (repo `antonioaragues/piopio`, SwiftUI, `apps/mac/App/Piopio`). The relevant code is in `ThreadView.swift`, `Composer.swift`, `BuildViews.swift` and the inspector. The current screen is in `assets/before/chat-today.png`.

**Chosen direction: 13a (option A)**, plus the shared pieces 14a–14f. Option B (13b) is in the file for reference only. **Do not implement B.** Where 14c/14e/14f describe both A and B, use only the A column.

Problems being fixed:
1. Lines are ~1,350 px wide (~190 characters), so reading is tiring.
2. Full mono paths break up every sentence.
3. Everything is in the same grey (Thought, Worked, Checkpoint, Copy).
4. Checkpoint dividers interrupt each turn.
5. Floating suggestion pills overlap the text and can't be closed.
6. The toolbar has 7 buttons and the composer has 5 controls.

## About the design files
`Piopio Chat v3.dc.html` is an **HTML design reference**, not production code. Rebuild it in SwiftUI using the patterns in `Design.swift` and native controls: `Menu`, popover, segmented `Picker`, `.help()` tooltips, hover via `.onHover`. To view the file, open it in a browser with `support.js` and `Piopio Sidebar.dc.html` in the same folder. Screens carry id badges (13a, 14a–14f).

Glyphs in the HTML stand in for SF Symbols:

| Glyph | SF Symbol |
|---|---|
| ⧉ | `doc.on.doc` |
| ↻ | `arrow.clockwise` |
| ⑂ | `arrow.triangle.branch` |
| ✎ | `pencil` |
| ↶ | `arrow.uturn.backward` |
| ◫ | `sidebar.right` |
| ⌄ | `chevron.down` |
| › | `chevron.right` |
| ✕ | `xmark` |
| ↳ | `arrow.turn.down.right` |
| + | `plus` |
| ↑ | `arrow.up` |

**Fidelity:** high fidelity for layout, type, spacing, copy and behavior. Sample data is illustrative.

## Layout (13a)
- Window reference: 1280×800. The unified sidebar (268) is on the left. Content sits in the middle. The inspector (280, floating glass, inset 8) is on the right.
- **Reading column: `max-width: 680`, centered**, with 40 px horizontal padding. This is the most important change. All thread content and the composer share this column.

### Toolbar (60 tall) — 7 controls → 2
- Left:
  - Title: 15 semibold.
  - Subtitle (11.5 `fg3`, joined with " · "): project · git state ("no git", or the branch name in mono) · status (6pt dot + "Done"/"Running"/"Needs you") · session cost.
- Right:
  1. **Open ⌄** pill (28 tall). It's a `Menu`: VS Code ⌘O · Terminal ⌘⇧T · Finder · divider · Copy path · Default app…. The button shows the last-used app's icon, so one click repeats it.
  2. **Inspector toggle** `sidebar.right`. Active state: `accentSoft` background with an accent glyph.
- Where the removed controls went:
  - Graph/fork icon → message actions (Fork).
  - Auto-edit → composer.
  - "no git" pill → subtitle text.
  - Terminal and Finder → the Open menu.

### Thread
**Type**
- Answers: SF Pro 15 / line-height 1.6, `fg`.
- Paragraph gap: 12. Gap between turns: 28.

**User message**
- Right-aligned bubble: `bubble` fill, radius 18/18/4/18, padding 10×15, 15 / 1.5, max-width 480.

**Activity line (14a)**
- One line, 13 `fg3`, **no leading icon** (the ✦ sparkle and ✓ check are removed).
- Done: "Thought for 3s, edited `RESUMEN.md` +13 ›".
  - File chip: 20 tall, `chip` fill, radius 5, SF Mono 11.5 `fg2`.
  - The +N count is green mono.
  - Several files: "edited 3 files".
- Running: "Thinking…", "Running pnpm test…" or "Editing parser.py…", with a 10pt spinner before it.
- Clicking the line expands the existing thought and tool cards inline.

**Paths in prose**
- Anything inside the project root renders **relative**, as an inline chip (SF Mono 12.5, `chip` fill, radius 5, padding 1×7).
- The full absolute path appears in a tooltip. Click reveals the file in the inspector's Files tab.

**Message actions (14a)**
- Below each answer: icon buttons, 28×26, radius 6, 13pt, `fg3`; hover fills with `chip`.
  - **Copy** `doc.on.doc` → after clicking, it shows `checkmark` for 1.5 s.
  - **Retry** `arrow.clockwise`.
  - **Fork from here** `arrow.triangle.branch`.
- Tooltips carry the names ("Copy", "Retry", "Fork from here").
- Right-aligned: "Haiku 5.5 · $0.0002" (11.5 `fg3`). The full model id and token counts show in a tooltip.
- Visibility: always visible on the **last** answer; on hover for older ones.

**User message actions (14b)**
- On hover, under the bubble, right-aligned: **Copy**, **Edit** (`pencil`), **↶ Rewind to here** (24 tall, `chip` fill, 12 `fg2`).

### Checkpoints → Rewind (14b)
- A checkpoint is still saved **silently** before every user message. **Remove every checkpoint divider from the thread.**
- Rewind is reachable from:
  1. The user message hover action "Rewind to here".
  2. The inspector's Turns list (↶ on hover).
- **Rewind popover** (radius 14):
  - Title: "Rewind to before this message?"
  - Radio options:
    - **Chat and files** (default) · "removes RESUMEN.md, drops 1 turn". Lists the actual files affected.
    - **Chat only** · "keep the files as they are".
  - Note: "Your message goes back into the composer so you can edit it."
  - Buttons: Cancel / **Rewind** (accent).
- **Edit** on a user message = rewind *chat only* to that point, then put the text in the composer.
- Chats with no folder (plain Chat): only **Edit** is shown; there is no Rewind or inspector.

### Suggestions — "Ask next" (14e, A)
- Rendered **inside the thread**, right after the last answer's actions, so they scroll with the content. **Never floating above the composer.**
- Header row: "Ask next" (11.5 `fg3`) and a right-aligned **✕**. ✕ hides suggestions for this chat (persisted per chat).
- 2–3 rows in a list:
  - `arrow.turn.down.right` glyph in `fg3`, text 14 `fg`, row padding 8×10, radius 8.
  - Hairline dividers between rows, inset 34.
  - Hover/selected row: `chip` fill, with a "Tab" hint on the right.
- Behavior:
  - Click sends the suggestion.
  - **Tab** inserts the highlighted suggestion into the composer.
  - ↑/↓ move the highlight while the composer is empty.
- Show only after the **last** answer, and hide as soon as the user starts typing.
- Settings › Chat › "Suggest follow-up messages" turns them off globally.

### Composer — 5 controls → 3
- Floating card: width matches the reading column, 20 from the bottom.
  - Fill `card`, radius 20, 0.5 line, shadow 0 8 30 rgba(0,0,0,.08).
  - Padding 13 / 12 / 10 / 16.
- **Fade:** a 150 px gradient from transparent to `win` sits behind the composer, so thread text dissolves before reaching it and never runs under it. The thread keeps bottom padding equal to the composer height + 40.
- Placeholder: "Reply…" (15 `fg3`). Empty session: "Ask, @mention files, or /command…".
- Bottom row, left to right:
  1. **Attach** `+`: 26 circle, `chip` fill.
  2. **Mode chip** "● Auto-edit ⌄": 26 tall, `chip` fill, 12. The dot shows the mode:
     - grey = Plan only
     - amber = Ask first
     - green = Auto-edit
     The menu offers those three options.
  3. **Model chip** "Haiku 5.5 · medium ⌄" (thinking level in `fg3`). Its popover holds the model picker (existing 10a picker) and a Thinking segmented control: Off / Low / Medium / High.
  - Spacer.
  - **Context ring** (14c): a 22pt conic ring, shown **only when context > 60%**. Amber above 60%, red above 85%. Click → "Compact conversation". The context number lives in the inspector otherwise.
  - **Send:** 30 circle. Disabled: `chip` fill with a `fg3` arrow. Enabled: `inv` fill.
- The old "Plan" chip is removed (it's now a mode). The "5k / 1.0M" chip is removed (ring + inspector).

### Inspector (A)
- **Default: closed.** It opens automatically the first time a turn changes files, and the user's toggle state is then remembered per session.
- Segmented **Changes | Files**.
- **Changes card:** one row per file — mono 12 path, NEW / M / D badge (11 bold), +N/−N in mono. Footer link: "Review diff".
- **Turns** (replaces the Timeline with interleaved checkpoints):
  - One row per user turn: a 16pt number tile (current = `inv`), the first words of the message (12.5, ellipsized), and meta (files changed or age).
  - ↶ on hover = Rewind (opens the same popover).
  - Footnote: "Every message saves a checkpoint. Hover a turn or your message to rewind."
- **Footer:**
  - Context "5k of 1M" with a 4pt bar.
  - "This session $0.0015".

## Interactions & keyboard
- ⌘C on a focused answer copies it.
- ⌘Z right after a turn offers "Rewind last turn".
- Tab / ↑↓ for suggestions, as above.
- ⌘. stops the current turn.
- ⌘⇧I toggles the inspector.
- Transitions: system defaults. The copy ✓ crossfades. Suggestions fade out when typing starts.

## State (additions / changes)
```swift
struct Turn {
  id; index
  userMessage
  checkpointID
  filesChanged: [FileChange]
  cost; model; thinkingDuration
}

enum EditMode { case planOnly, askFirst, autoEdit }   // replaces the separate Plan toggle + Auto-edit pill

struct ComposerSettings { mode: EditMode; model: ModelRef; thinking: ThinkingLevel }

var suggestionsDismissed: Bool     // per chat
var inspectorOpen: Bool?           // per session; nil = auto (open on first file change)
var lastOpenApp: OpenTarget        // drives the Open button icon
```
`RewindRequest { toTurn, scope: .chatAndFiles | .chatOnly }`

## Tokens
Same as `docs/design/README.md` / `Design.swift`. Used here:

| Token | Value |
|---|---|
| win | #fdfdfc / #1a1a1c |
| card | #fff / #242426 |
| bubble | #f1f1f3 / #2e2e31 |
| chip | rgba(0,0,0,.045) / rgba(255,255,255,.08) |
| fg / fg2 / fg3 | #1d1d1f / #5b5b61 / #8e8e93 |
| line | rgba(0,0,0,.08) |
| inv | #1d1d1f / #f5f5f7 |
| accent | system accent; accentSoft 14% / 26% |
| green / amber / red | oklch(.60 .15 150) / (.72 .15 70) / (.60 .19 25) |

Type scale for the thread:

| Element | Style |
|---|---|
| Answer | 15 / 1.6 |
| User bubble | 15 / 1.5 |
| Ask next rows | 14 |
| Activity line | 13 `fg3` |
| Chips | 12 |
| Meta | 11.5 `fg3` |
| Code and paths | SF Mono 12.5 (chips 11.5) |

Measure: 680. Radii: bubble 18/18/4/18 · composer 20 · cards 12 · icon buttons 6 · chips are capsules.

## Files
- `Piopio Chat v3.dc.html` — 13a (chosen), 13b (reference only), and pieces 14a–14f.
- `Piopio Sidebar.dc.html` — the unified sidebar, as in the v2 handoff.
- `assets/before/chat-today.png` — the current screen.
- `assets/chick.png`, `support.js` — needed to open the HTML locally.

## Suggested implementation order
1. Reading column max-width 680 and the type scale. This gives the biggest gain for the least work.
2. Activity line: merge Thought and Worked, drop the icons. Relative path chips.
3. Message action icons, plus user message hover actions.
4. Remove checkpoint dividers; add the Rewind popover; Turns list in the inspector.
5. Toolbar: the Open menu; move git state to the subtitle.
6. Composer: EditMode chip, model+thinking chip, context ring, bottom fade.
7. "Ask next" suggestions in the thread.
8. Inspector auto-open behavior.
