# Handoff: Inspector + Files panels and toolbar (Piopio)

## Overview
This handoff reorganises the right-hand side of Piopio's main window. Today it has a crowded **Summary** panel and a separate **Changes** panel, opened from 4 toolbar icons. It becomes:
- A **toolbar** with 3 icons: Inspector, Files and Terminal, then `…` (option **5a**).
- An **Inspector** panel with two tabs, **Session** and **Changes** (option **2a**, with the Session order and plan states from **4a**).
- A **Files** panel showing a project tree plus an inline file preview (option **3a**).
- **One shared footer** with context and cost, used by every panel.

The changes fix these problems in the old panels:
- Data was shown twice: the context appeared with two different formats, and the "Changed" list repeated the Changes panel.
- "Wrote" and "Changed" were separate lists.
- Setup took up the middle of the panel.
- File paths were truncated from the left.

## About the design files
`Harness Panel Proposals.dc.html` is an **HTML design reference**, not production code. Recreate it in Piopio's existing SwiftUI code (`App/Piopio`, `Packages/PiopioTranscript`) using its current views and patterns. The file is a canvas showing every option explored. **Only these are approved: 5a, 2a, 3a and 4a** (search the file for `id="5a"` and the others). Ignore 1a–1c, 1b's three tabs, 5b and 5c.

## Fidelity
**High-fidelity** for layout, hierarchy, copy and state. Colours and type match the current app's dark theme. Use the app's existing tokens where they already exist; the hex values below are the reference.

---

## 1. Toolbar (5a)
- Position: right end of the title bar, after the title and `piopio · main`.
- Order: `[Inspector] [Files] [Terminal]`, then a 1×18 divider (#333, 6px horizontal margin), then `[…]`.
- Each button is 30×28, radius 7, 16px icon, 2px gap between buttons.
  - Idle: no background, icon #9A9A9A.
  - Active (its panel is open): background #3A3A3A, icon #E6E6E6.
- Icons:
  - Inspector: a rounded rect with a right-hand column (sidebar.right).
  - Files: a folder.
  - Terminal: terminal.
  - More: ellipsis.
  - SF Symbols are fine.
- **Needs-you badge** on Inspector: a 7px blue dot (#3B8CFF) with a 1.5px border in the title-bar colour (#1F1F1F), placed at top 3 / right 4. Show it only when something is waiting on the user (an approval, an open question, a command blocked by the sandbox).
- The buttons are mutually exclusive: one panel open at a time. Clicking the active button closes the panel.
- Tooltips and shortcuts: Inspector ⌘I, Files ⌘P, Terminal ⌃`.
- This replaces the old Summary and Changes buttons with the single Inspector button.

## 2. Inspector panel (2a + 4a)
- Width 300, full height, background #1F1F1F, separator #2E2E2E. Base text is 13px system font (SF Pro Text).
- Layout, top to bottom: tab bar, then tab body (flex: 1, scrolls), then shared footer (§4).

### Tab bar
- Two tabs in this order: **Session**, **Changes**.
- Spacing: 18px gap, padding 14 18 0, bottom border #2E2E2E.
- Active tab: weight 600, text #E6E6E6, 2px bottom underline #E6E6E6, 10px bottom padding.
- Inactive tab: text #8A8A8A.
- The Changes tab shows a count (`Changes 38`). In the active tab the count is #8A8A8A at weight 400.
- Default tab: Session. Remember the last tab used in each session.

### Session tab
- Body padding 18, 22px vertical gap between blocks. Blocks are separated by 1px #2E2E2E lines.

**1. Setup**
- Title "Setup", weight 600.
- A 2-column grid (72px label column, 1fr value column), 8px gap:
  - `Project`: `piopio` followed by `· main ⌄` in #8A8A8A. The branch part is a picker.
  - `Runs on`: `This Mac`
  - `Tools`: `No apps or skills · Add…` in #8A8A8A, with `Add…` as a link in #3B8CFF. This single row replaces the old separate Uses and Skills rows. When apps or skills exist, list their names here.
- Labels are #8A8A8A.

**2. Read**
- One row, baseline-aligned:
  - Left: "Read", weight 600.
  - Right: `2 files · 144 commands ›` in #8A8A8A.
- Clicking it opens the Files panel with the "Touched" filter on.

**3. Plan.** It has three states:
- **In progress**
  - Header: "Plan" on the left, `2 of 4` on the right in #8A8A8A.
  - A segmented progress bar: one segment per step, 3px high, 3px gap, radius 2. Colours: done #5FBF7A, current #3B8CFF, pending #333.
  - Step list, 7px gap. Each step has a 14px icon column:
    - Done: a ✓ in #5FBF7A. The text is #8A8A8A with a line-through in #555.
    - Current: an 8px ring (2px #3B8CFF). The text is weight 600, with `now` on the right in 12px #3B8CFF.
    - Pending: an 8px ring (1.5px #555). The text is #A8A8A8.
- **Done**
  - Header: "Plan" and `4 of 4`.
  - Collapsed row: background #22302A, radius 8, padding 8 10. It contains ✓ (#5FBF7A), `All 4 steps done`, and the duration on the right (`34 min`, 12px #8A8A8A).
  - Under it, a `Show steps` link (12px, #3B8CFF) that expands the step list.
- **No plan**
  - Header: "Plan", with `None` on the right in #8A8A8A.
  - Under it, a 12px #8A8A8A line: `Short task — no plan needed.` followed by an `Ask for one` link, which sends a "make a plan" request to the agent.
  - Never leave an empty gap here.

### Changes tab (timeline by commit)
**Header block**
- Padding 14 18, bottom border.
- Row 1: `38 files · 9 commits` (weight 600) on the left; `Review all` link on the right.
- Row 2: `+1.396` (#5FBF7A) and `−434` (#E5675E) on the left; `● 4 new` (dot #5FBF7A, text #8A8A8A) on the right.

**Timeline**
- Padding 14 18. Each node is a 9px dot in a left column with a 1px #333 connecting line, a 12px gap, and 16px bottom padding.
- **Not saved yet** (only when there are uncommitted changes):
  - Dot: a 1.5px #E6B450 ring.
  - Title: "Not saved yet", weight 600, with `N files` on the right.
  - File rows in monospace 12px: name on the left, then +adds and −dels.
  - A `Commit…` link (12px).
- **Commit nodes** (newest first):
  - Dot: filled #6A6A6A.
  - Row 1: commit title, single line with ellipsis, and the relative time on the right (`1m`, `11m`, 12px #8A8A8A).
  - Row 2 (12px #8A8A8A): `N files +A −D ›`.
  - Clicking a node expands its file list (monospace 12px) in place.
  - The newest commit is expanded by default.
- After 3 commits, show a `6 earlier commits` link indented 21px.
- Clicking a file row opens its diff (the same diff view as today's Review).

**Diff numbers:** tabular figures. Adds are #5FBF7A as `+N`; deletions are #E5675E as `−N` (a real minus sign). Hide a number when it is 0.

## 3. Files panel (3a)
- Same panel shell and shared footer as the Inspector.

### Tree view
- **Search field:** background #262626, 1px #333 border, radius 7, padding 6 10. Placeholder `Filter files` with `⌘P` on the right (11.5px).
- **Segmented control:** background #262626, radius 7, padding 2. Segments are `All` and `Touched 40`. The active segment is #3A3A3A with radius 5. "Touched" shows only files that are new, modified or read.
- **Root row:** `piopio` on the left, `~/Proyectos` on the right, 11.5px #8A8A8A.
- **Tree rows:**
  - Padding 4 8, radius 6. Indent is 8 + depth×14 px. Hover background #2A2A2A; selected row background #2F3A4A.
  - A caret column (10px wide): ▾ open, ▸ closed. Then the name with ellipsis.
  - Status letter on the right, 11px monospace, weight 600:
    - `N` new: #5FBF7A
    - `M` modified: #E6B450
    - `R` read by the agent: #7AA7E6
  - Folders show `•` (#E6B450) when anything inside them is touched.
  - Untouched files use #A8A8A8 text.
- **Legend row** above the footer: `N new · M changed · R read`, 11.5px.

### Preview view
Clicking a file replaces the tree inside the same panel.
- **Header:**
  - Row 1: `‹` (back to the tree), then the breadcrumb `docs /` in #8A8A8A and `ci.md` in weight 600.
  - Row 2: a status badge (`new`: 10.5px, #5FBF7A text, 1px #2F5A3B border, radius 4), `+61`, `· Markdown`.
  - On the right, a mini segmented control `Diff | File` (12px). It defaults to Diff for changed files and File for read or untouched files.
- **Body:** monospace 12px, line-height 1.7. A line-number gutter 18px wide, right-aligned, in #555.
- **Action row:** `Open in editor` and `Mention in chat` links. "Mention in chat" inserts an @file reference into the composer.

## 4. Shared footer (every panel)
- Border-top #2E2E2E, padding 12 18, space-between, text #8A8A8A.
- Left side:
  - A 40×3 track (#333, radius 2) filled to the context percentage in #9A9A9A.
  - `163k of 1M`
  - A `Compact` link
- Right side: the session cost `$0.12` in #E6E6E6.
- This is the **only** place context and cost appear. Remove the old Context block and "This session" row from everywhere else.

## Interactions & behaviour
- Panel switching is instant (no animation required). If you animate it, use a 150ms ease-out crossfade.
- Expanding a timeline node or the plan steps: a 150ms height transition.
- Live updates while the agent works:
  - The plan's current step and progress bar.
  - The "Not saved yet" node appears or disappears as files change or get committed.
  - The tab count and the footer update.
- When the needs-you state clears, the badge disappears.

## State
- `activePanel`: `none | inspector | files | terminal`
- `inspectorTab`: `session | changes`
- `planState`: `none | inProgress(current, total) | done(duration)`
- `expandedCommits`: set of commit IDs
- `filesFilter`: `all | touched`
- `previewFile`: file or nil
- `previewMode`: `diff | file`
- `needsUser`: Bool
- Data comes from the existing build/summary models (`BuildSummary`, `SummaryCard`, checkpoints and git in `packages/engine/src`).

## Design tokens
| Token | Value |
|---|---|
| Panel bg | #1F1F1F |
| Control bg | #262626 |
| Hover row | #2A2A2A |
| Active control / button | #3A3A3A |
| Selected row | #2F3A4A |
| Divider | #2E2E2E |
| Track / timeline line | #333 |
| Text primary | #E6E6E6 |
| Text secondary | #A8A8A8 |
| Text muted | #8A8A8A |
| Gutter | #555 |
| Link / accent | #3B8CFF |
| Add / done | #5FBF7A |
| Delete | #E5675E |
| Modified / uncommitted | #E6B450 |
| Read | #7AA7E6 |
| Done tint bg | #22302A |

- Type: system font at 13px (body), 12px (meta), 11.5px (section labels), and 600 weight for titles. Monospace is ui-monospace / SF Mono at 12–12.5px.
- Radii: 4 (badges), 6–7 (rows and controls), 8 (callouts), 12 (panel corners in the mock only).
- Spacing: panel padding 18, gap between blocks 22, gap inside a block 8–10.

## Assets
There are no image assets. Use the SF Symbols the app already uses for the icons.

## Files
- `Harness Panel Proposals.dc.html` is the design canvas. The approved options are `#5a` (toolbar), `#2a` (Inspector), `#4a` (Session states) and `#3a` (Files).
