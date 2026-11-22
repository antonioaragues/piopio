# Chat Summary, made of Build's blocks

Proposal and build (2026-11-22). `chat-summary.html` is the mockup. It shows the panel as it was, then A (every block
folded) and B (Read open). A switch puts Skills inside Tools or in a block of its own, and another switches between
the screenshot's chat and a busier one.

The chat column still used the older summary card (docs/design/summary): grey verbs in a 68 pt column, Setup › Uses
with a second column of switches inside it, a footnote broken over four lines, and page addresses cut in the middle.
Build's panel had moved to blocks (docs/design/tools-panel A): a bold title, the answer in grey on the right, and a ›
that opens the block at full width.

## Decided

- **B**: the chat panel is **Tools · Skills · Read**, and Read starts open, since it's all a chat has to show. Closing
  it is remembered for every chat (`chatReadOpen`).
- **Skills is a block of its own, in Build too.** Skills aren't switches (a conversation can't turn one off), so they
  don't share a count with Tools. Build is now Setup · Tools · Skills · Read · Changes · Plan.
- The panel has no "Summary" title (the first block sits level with the toolbar, like Setup in Build) and no "Now"
  group (the transcript shows what it's doing, as in Build).

## Built

- `ToolsBlock` (Inspector.swift) takes `web:`. In chats, Web search is the first switch and counts toward "N on".
  Open, it shows Web, Apps and MCP servers, then "For this chat only. Settings…". With MCP off for chats in Settings,
  one grey line says so, with Turn on…. With nothing to switch: "None · Connect…".
- `SkillsBlock`: "None · Add…" on one line, or "N skills ›", which opens each skill with what it's for, then "Loaded
  when a task needs one, or with /. Manage…".
- `ChatReadBlock` (ChatSummary.swift): "3 pages · 1 file". Open, it shows You gave (the file and its kind) and Pages.
  Each page shows its title, or its site when it has none, with the site or the rest of the address in grey below. On
  hover, a page shows ↗ and opens in the browser. Five pages show, then "and N more".
- SummaryCard.swift keeps only `SummaryLink`. The old card parts (GroupHeader, CardRow, UsesRow, SkillsRow,
  NowGroup…) are gone.

Checked with captures (`app/`): a chat that read three pages with a file attached (Read open, then Tools open too),
and a Build session showing the new Skills block. Not checked: the panel with apps, MCP servers or skills present
(the capture home had none), clicking rows, and dark mode. In a window that isn't key, the web switch draws grey.
