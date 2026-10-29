# Handoff: Piopio v2 (current direction)

**This supersedes `README.md` / `Piopio.dc.html` for visual style.** Use the old README only for product behavior (screen inventory, flows, state model, providers and targets as lists). Where the two disagree, v2 wins.

## Files
- `Piopio v2.dc.html`: design reference (open in a browser, `support.js` alongside). Badges: **9a** main window (interactive: click *Wire engine protocol*, *Kitchen renovation*, *Atlas*), **10a–10f** surrounding surfaces, **11a–11h** conversation experience, **12a–12d** debate mode, **13a–13b** agents, **13e–13f** notebooks, **14a–14b** Home and Needs you. Light/dark via the `appearance` prop.
- **Where they conflict, newer turns win.** 13a replaces the agent views in 9a and the old README (no Activity/Setup tabs). 13e/13f replace the notebook topic tabs and inspector in 9a. 14b replaces 10c.
- This is a reference in HTML. Rebuild it in **SwiftUI** with native controls.

## Principles
1. **Grey ink.** The answer text is the only thing at full contrast. Process (thinking, tool calls, results, system notes) is `fg3`, one line, expandable.
2. **One black action per view** (`inv` fill, radius 8). Secondary actions are plain text in `fg2`, never outlined buttons.
3. **Blue (`accent`) for links, the caret and the "needs you" dot (6pt) only.** No other status colors in chrome. Diff +/− green/red are allowed only on code.
4. **Hairlines, not boxes.** 0.5pt `line` separators. Cards only for things that need you (approval, question) and for code blocks.
5. **No decoration.** No colored tiles, chips with backgrounds, pills or badges. Icons are 16pt outline glyphs (use SF Symbols) in `fg2`.
6. **Selectors have no chevrons.** Composer and toolbar selectors (mode, model, Unified…) are plain text. On hover they get a `sel` background, radius 6, 3×6 padding, like a borderless button; a click opens the menu.
7. **No cost in the header.** Cost and context live only in the inspector footer.

## Window (9a)
- Window radius 12, `win` bg, system shadow.
- **Sidebar** 260, `side` bg, full height, flush to the window edge (no floating panel), 0.5pt right hairline. Top bar 52: traffic lights, then on the right **sidebar toggle** + **compose (⌘N)**.
- Rows (radius 7, 6×8 padding, 10 gap, 16pt icon): Search ⌘K, Needs you (count in `fg2`, no badge).
- Sections: Projects, Notebooks, Agents, Chats. Header 12pt `fg3` with a **+ on the right** (creates that kind). Sessions are nested under a project at 34pt indent, with status shown only as the blue dot (waiting) or a 10pt grey ring (running).
- Footer 52: avatar 24 grey, name, "This Mac · $x today", gear.
- **Toolbar** 52: title 13.5 semibold + 12 `fg3` subtitle (no cost). Right side: icon-only ghost buttons (28pt, radius 6). "Open in Zed" appears only in Build.
- **Inspector** 280, same bg as the window, 0.5pt left hairline. Neutral segmented control (track `track`, selected segment `seg` + hairline). Plain rows. The footer holds the context bar (3pt, fill `fg2`) and the session cost.
- When the sidebar is collapsed (10d), the traffic lights and toggle move to the content toolbar and a breadcrumb appears.

## Conversation (11a–11h)
- Transcript column max 700, padding 36–40, body 14.5/1.6.
- **User message:** `bubble` bg, **radius 12**, 9×14 padding, right-aligned, max 80%.
- **Thought:** "Thought for 6s ›" 13pt `fg3`. Expanded: 1.5pt `line` left rule, 14 indent, 13.5 `fg2`.
- **Tool calls:** a single summary line ("Read 2 files, ran 1 command ›"). Expanded: rows with the verb (`fg3`, 40 wide) + monospace target + right-aligned result. Running: 10pt ring + live output tail in mono 12 `fg3`.
- **Code block:** `bubble` bg, radius 10, header row with filename + Copy.
- **Message footer:** copy / retry / branch icons (15pt `fg3`) + "Model · time" 12pt.
- **Approval card:** `field` bg, 0.5pt `line`, radius 12, 14×16 padding. Title row: blue dot + question in semibold + context on the right in `fg3`. Body: the command, diff or arguments. Actions: Deny · [type-specific: Always allow X / Allow edits for this session / Edit] as text, then **Allow ↩** in black on the right. Resolved: collapses to a `fg3` line ("Allowed `cmd` · passed in 6.2s", "Denied `cmd` · the agent was told why").
- **Question card:** same shell. Options are rows with a 18pt key badge (1–4), name + one-line implication, a "Something else…" free-text option, a step count ("1 of 2"), and Skip / **Next ↩**. Answered: "You chose X · change".
- **Interruptions** (no red): Stopped · continue; provider error (what happened, "Nothing was changed", links Retry / Use other model / Details); context near full (Compact now).

## Composer
- `field` bg, 0.5pt `line`, **radius 16**, shadow `0 2 10 rgba(0,0,0,.04)`, 12×14 padding, max 628.
- Placeholder 14pt `fg3`. Bottom row 12.5pt `fg2`: **+** (attach files, images, folders; also drop or paste) · mode (Build only) · model + thinking level on the right · send button 28 circle.
- Send: `sel`/`fg3` when empty, `inv` when there's content, **stop** (square) while running. ↩ sends or queues, ⌥↩ steers, esc stops. Queued messages show as a line above the box with Edit · Remove.
- Attachments: hairline tiles (radius 10). Mentions with @ are a grey token (`sel`, radius 4). / opens the command menu.

## Menus and floating surfaces
One style for all of them: `field` bg, 0.5pt `line`, radius 12, shadow `0 10 30 rgba(0,0,0,.12)`, 6pt inner padding, rows radius 7 with name + 12pt `fg3` description, ✓ for the current choice.
- **Model picker:** search field, groups per provider (OpenRouter first; more later), Thinking segmented control (Off / Low / Medium / High, ⌘T cycles), "Manage providers" link.
- **Mode picker:** Read only, Plan, Ask before edits, Auto-edit (⇧⇥ cycles).
- **New (⌘N):** Chat (⌘N again), Session in a project… (⌘⇧N), Notebook, Agent.
- **Search (⌘K):** results first, then actions; a right column says where each lives.
- **Quick Chat (⌥Space):** question, answer, Open in Piopio ⌘O · Copy · model.

## Debate mode (12a–12d)
- Split: story on the left (600), artifact pane on the right (`field` bg). The output of a debate is one or more artifacts, always shown rendered (never raw markdown).
- Story: user message, one line `Writer writes · Reviewer reviews · up to N rounds`, then **one grey line per round** (`n · text · → vN / agreed · ›`), then the closing reply and one **artifact card** per document (hairline, radius 12, mini page glyph, title + `type · vN · words`, `Showing` / `Open`).
- Pane header: a tab per artifact (selected = semibold + 1.5pt underline), version list `v1…v4` (hover buttons), then Changes · Copy · Export. Older version → banner `Viewing vN, written in round N. The agreed version is v4. Show v4`.
- Round opened (12b): every objection in plain words + `Accepted/Rejected · what changed or why not`, and a link `See changes from vN to vM`.
- Changes (12c): inline on the rendered document. Removed text is struck through in `fg3`, added text gets a faint `add` tint, and next to each change is the objection that caused it.
- While debating (12d): searches collapse into one grey line. The composer placeholder is `Add a note for the next round…`, queued notes sit above it, the meta reads `Round 2 of up to 12`, and esc stops after the current round. Actions the engine can't do are not offered.
- Composer addresses the artifact on screen (`Ask for changes to the proposal…`).

## Agents (13a–13b)
- **An agent is one conversation.** No Chat / Activity / Setup tabs.
- Toolbar: name + `Next run tomorrow at 8:00`, then `Run now` (hover text) and (i) to toggle the info panel.
- Automatic runs show as the agent's own messages, under a grey label `Morning briefing · 8:00`. A failed run is one grey line with links (`didn't run at 8:00. OpenRouter isn't set up. Set up · Run now`). Memory writes: `Remembered 2 things · undo`.
- **Info panel** (300, like a contact card): name + one line, then **Does** (the instructions as a sentence, Edit), **When** (Change), **Can** (switches, black when on), **Reaches you in** (Piopio on, Telegram Connect), **Remembers** (See all), and a footer with model · where it runs · cost this month, plus `Keep it always on` (move to cloud).
- **Creating an agent (13b):** no form up front. The user describes it in one sentence and Piopio drafts a card (Name, Does, When, Can, Reaches you, Runs on) that they correct by replying. Edit details · **Create agent**. Channels are connected right after creating it.

## Notebooks (13e–13f)
- **One conversation with headings.** No topic tabs, no routing cards. The organizer inserts a heading (13pt semibold + hairline) when the subject changes. Under the user's message, a grey line reads `New heading: X · keep in Y` (undo).
- Right column **Topics** (240): each topic name + status line in `fg3` (`Decided · L con península`, `Open · tiradores o gola`, `Not started`), then Remembers (count) and Files (Add).
- **Clicking a topic (13f)** shows only its part of the conversation. Breadcrumb `Notebook / Topic`, plus `All topics` to go back. Messages written here stay in the single conversation under that heading.
- **Topic state:** a block at the top, **Where it stands** (hairline box, radius 12), with rows Decided / Open / Uses (from other topics). The organizer keeps it current and says so with `Updated where it stands: … · undo`; the user can edit it. There are three states (Not started · Open · Decided), changed from the hover word at the top right of the block and shown under each topic in the list.

## Home and Needs you (14a–14b)
- Both are a single centered column (max 640, 72pt top padding), 28pt bold title. No boxes around sections, no banners, no mascot, no cost in the header.
- **Home:** greeting + date, the composer (`Ask anything, start a session, or message an agent…`, where the `New chat` selector picks the destination), then plain row lists: **Needs you** (blue dot, title, source · age, See all), **Coming up**, **Recent** (name, kind · when). Empty sections are hidden.
- **Needs you:** title + filters as hover text (All · Approvals · Messages · Problems) + `N things, newest first`. Each item is a block between hairlines: dot + **source** + `what happened · age`, then the content in plain words, then the actions. One black button per item (the one that fixes it, e.g. `Set up OpenRouter`); the others are text (`Run again`, `Dismiss`, `Open conversation`). Messages have an inline reply field whose send button appears once you type. Approvals reuse the 11c card. The end reads `That's everything. You'll get a notification when something new comes in.`
- **Sidebar footer** (every window): avatar, name, `This Mac · $x today`, gear.

## Tokens
| Token | Light | Dark |
|---|---|---|
| win | #fcfcfb | #1e1e1d |
| side | #f4f4f2 | #191918 |
| fg / fg2 / fg3 | #1f1f1e / #6b6b67 / #9b9b96 | #ececea / #a6a6a1 / #77776f |
| line | rgba(0,0,0,.08) | rgba(255,255,255,.09) |
| sel (hover/selected) | rgba(0,0,0,.06) | rgba(255,255,255,.07) |
| bubble | #f0f0ed | #2b2b29 |
| field | #ffffff | #252524 |
| track / seg | rgba(0,0,0,.05) / #fff | rgba(255,255,255,.06) / #3a3a38 |
| inv / invfg | #1f1f1e / #fff | #ececea / #1e1e1d |
| accent | #2f6fde | #6ea0ff |
| add / del (code only) | #3a8a55 / #c2493f | #6cc28a / #ef7d72 |

Type: SF Pro. 38 bold (doc only), 20 bold (Settings title), 14.5 transcript, 13.5 toolbar title, 13 UI, 12.5 secondary, 12 section labels / meta, 11 shortcuts. SF Mono 12–12.5 for code, paths and commands.
Radii: window 12 · composer 16 · menus, cards, Quick Chat 12–14 · bubbles 12 · code 10 · black button 8 · rows 7 · hover selector 6.
