# Chat / session thread v3 (option A): what's built

The handoff in this folder (13a and the pieces 14a–14f) is built across:
- the transcript package `apps/mac/Sources/PiopioTranscript`;
- the app: `Composer.swift`, `BuildViews.swift`, `BuildReview.swift`, `BuildFiles.swift`, `ThreadView.swift`, `ThreadModel.swift`;
- the engine: `timeline/steps.ts`, `runtimes/build.ts`, `sessions.ts`.

A capture of a Build session with the faux model is in `screenshots/13a-build.png`. The pointer was over the second message, so its hover row shows too.

## Built

| Piece | Built |
|---|---|
| Reading column | 680 max, at least 40 on each side, for the thread and the composer. Answers 15 / 1.6, paragraph gap 12. Headings 19/17/15. Quick Chat keeps its compact 13.5. |
| User message | Right-aligned bubble, 18/18/4/18, padding 10×15, 15 / 1.5, at most 480 wide. |
| Activity line (14a) | One line per turn, 13 fg3, no icon: "Thought for 3s, edited `RESUMEN.md` +13 ›", "edited 3 files", "ran 2 commands", and the rest in words. While working there's a spinner and what runs now ("Running pnpm test…", "Editing parser.py…", "Thinking…"). Clicking opens the thought and each step's card. |
| Paths | Code spans are chips (SF Mono 12.5, chip fill, radius 5). Paths inside the project, in code spans or bare, show relative, with the full path in the tooltip. Clicking one shows the file in the inspector's Files tab, opening the folders above it. Tool cards also show relative paths. |
| Message actions (14a) | Icon buttons under each answer: Copy (✓ for 1.5 s), Retry, Fork from here, with tooltips; "Haiku 5.5 · $0.0002" on the right, with the model id and tokens in its tooltip. Always visible on the last answer, on hover for the others. |
| User actions (14b) | On hover under your message: Copy, Edit and, in Build, "↶ Rewind to here". Plain chats keep Edit (a new version) and the ‹ 1/2 › versions. |
| Checkpoints → Rewind (14b) | No dividers in the thread; a checkpoint is still saved before each message. The Rewind popover offers Chat and files (it lists the files: "removes RESUMEN.md, drops 1 turn") or Chat only, and your message goes back into the composer. It's reached from your message and from the inspector's Turns. Build Edit is Rewind (chat only) plus the text in the composer. |
| Ask next (14e, A) | Inside the thread after the last answer, so it scrolls with it. Rows have ↳, the highlighted one says Tab. Click sends; Tab puts the highlighted one in the composer; ↑/↓ move it while the composer is empty. It hides while you type, while a turn runs or waits for you, and for good with ✕ (per chat). Settings › Chat still turns suggestions off. |
| Toolbar (14d) | Two controls: **Open ⌄** and the inspector toggle (accent when open, ⌘⇧I). The Open menu has the editors, Terminal, Finder, Copy Path and Default App; one click repeats the last choice and the button shows its icon. The subtitle reads "project · no git / `branch` · ● Done · $cost". |
| Composer (14c, A) | A card the width of the column, radius 20, with a soft shadow and a 150 pt fade behind it. Placeholder "Reply…" once there's a conversation. Controls: + (attach; in Build it mentions files), the mode chip "● Auto-edit ⌄" (Plan only grey, Ask first amber, Auto-edit green), and the model chip "Haiku 5.5 · medium ⌄" whose popover has the model picker plus Thinking Off/Low/Medium/High. The context ring shows past 60% (amber, red past 85%); click compacts. Send is a 30 circle, chip fill when disabled and inv when enabled. ⌘. stops. |
| Inspector (A) | Closed by default. It opens the first time a turn changes files, then remembers your toggle per session. Changes: a card with mono paths, NEW/M/D, +N/−N, "Review diff" and Commit…. Turns: number tile (the current one dark), first words, files or age; ↶ on hover opens Rewind. Footer: context bar and session cost. |

## Engine
- **One line per turn** (`groupSteps`): answers that only thought or only called tools fold into the steps line, with their thinking text and time. Checkpoints no longer split a turn. Agents get the same folding.
- **Thinking time**: `thinkingMs` on answers, measured live. History reloaded from disk shows "Thought".
- **`sessions.rewind`** (Build): finds your message in pi's session tree (counting from the end, which compaction leaves alone). With `files`, it restores the first checkpoint after the message, checkpointing the current state first. It then moves the tree to before the message and returns the message's text. `dryRun` lists the files and turns.
- **Retry in Build**: Rewind (chat only), then the same message again; the files stay as they are.
- **Fork in Build**: a new pi session file from the root to the end of that turn (pi's `createBranchedSession`), picked up like any CLI session.

## Adapted, on purpose
- **Full auto** stays in the mode menu, below a divider: the engine has it and Settings › Approvals uses it.
- **The git menu stays** as a pill when the folder is a repository, for commit, push and branches; "no git" is subtitle text only. The terminal drawer keeps ⌃`; the Open menu's Terminal opens Terminal.app.
- **The session tree** (`/tree`) still works and opens from the title; Fork and Rewind cover what its toolbar button did.
- **Not done**:
  - ⌘Z right after a turn ("Rewind last turn"); use Rewind on the message.
  - ⌘C on a focused answer; use the Copy button.
  - The keyboard shortcuts shown in the Open menu (⌘O is Open Folder).
- **Retry doesn't undo files**: it asks again without restoring them. Rewind with "Chat and files" is there for that.
