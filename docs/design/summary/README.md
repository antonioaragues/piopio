# Summary column, with its own voice

Proposal (2026-11-06): `summary.html`, a mockup page. The Summary column (docs/design/session-panel) looks too much
like Claude's, so this page explores directions of its own, all within grey ink:

- **A · Card**: verbs on the left (Works in, On, May, Uses, Knows, Plan, Made), like the agent card (13a), so Build,
  Chat, Notebook and Agent read as one family. Recommended, with B's "now" line while the agent works.
- **B · Log**: the session as a story on the activity log's rail; the setup folds into one line.
- **C · Glance**: three numbers first (changed, room left, cost), then what it made, then the setup as a grid.

It also weighs moving the + menu's configuration into the column: (1) everything there, (2) state in the column
(apps, MCP, web search, skills) and actions on `/`, with + opening the file picker directly (recommended), (3) both.
Skills can't be turned off per conversation yet (`toolsOff` knows `connector:` and `mcp:` only).

And it suggests Piopio's own names for the permission modes (Only looks, Plans first, Asks first, Edits on its own).

The user chose style A and asked for an information-architecture pass.

## Round 2: `ia.html` (2026-11-06)

- **Inventory** of everything a conversation can tell you, with its kind, how often it changes and where it is today.
  Problems found: Results mixed input (files you shared, pages read) with output; Context was a meter with nothing
  under it; what you gave a Build session showed nowhere; the same switches lived in the + menu and the column.
- **Five groups**, one question each: Now (is it busy?), Made (Wrote · Changed · Saved), Plan (the checklist),
  Context (You gave · Follows · Remembers · Read, with the meter as its header), Setup (Works in · On · Runs on · Uses ·
  Knows; Does · When · Reaches for agents). Spend is the footer.
- **Placement by reach**: composer = this message (plus model and mode, changed every few turns), `/` = do something
  now, column = this conversation, transcript = the story, toolbar views = the detail, Settings = every conversation.
- **Order**: by attention (Now, Made, Plan, Context, Setup; recommended) or by flow (Setup → Made). Empty groups hide.
- Drawn in style A for a Build session, a chat and an agent (working and done); a matrix for all kinds. Notebooks keep
  Topics on top (it's their Plan and Made); debates keep their draft pane.

Decided (2026-11-06): **order by attention**: Now, Made, Plan, Context, Setup.

Also decided: **model and mode live only in the composer** (Setup doesn't repeat them), and **Wrote is only for
things you open and read** (documents, PDFs, images, data); any code or text file in the project, new or edited, is
under Changed.

## Step 1, built 2026-11-06: Build sessions

`SessionSummaryPanel` moved to `BuildSummary.swift`; the sorting lives in `PiopioKit/SessionDigest.swift` (tested).

- **Now** (only while running or waiting): the step in progress and "Step n of m", or "Waiting for you · It's asking
  in the conversation" with the blue dot.
- **Made** (Review all): **Wrote** = new documents (PDF, Markdown, Office, images, CSV…) with their kind, opening in
  the preview beside the conversation; **Changed** = every other change with +/− (deleted files say so), opening its
  diff, six then "and N more"; **Saved** = commits since the session started (click copies the hash) and "N to push ·
  Push".
- **Plan**: the checklist, "n of m".
- **Context**: the meter is the header ("4% full", tokens in the tooltip, Compact). **You gave** = files sent with a
  message and paths you @mentioned (a file opens in the preview, a folder in Finder); **Follows** = AGENTS.md or
  CLAUDE.md; **Read** = "N files" unfolding into the list, "and N commands".
- **Setup**: Works in (reveals the folder), On (branch, "N to pull", the git menu, a worktree's base), Runs on, Uses
  (the apps and servers on; unfolds into the same per-session switches as before, or "No apps · Connect…"), Knows
  (pi's skills; unfolds into names and descriptions, "Type / … to use one"). The permissions menu left the column
  (the composer's mode chip stays).
- The composer now writes picked or dropped files as @mentions (`@path`, folders with a trailing /), like those typed
  after @, so "You gave" sees them. A file named in prose isn't counted.
- `ToolChoiceRow` is shared by the old Connectors and MCP section (chats, notebooks) and Uses.

Checked with captures of a scripted session (an @mention, a read, a checklist, two new documents and an edit): while
waiting for approval and when done. Not seen: Saved (no commit in the script), Uses with apps, the unfolded lists;
nothing was clicked, because the user's own Piopio was open. Next: Chat, then Notebook and Agent.

## Step 2, built 2026-11-06: chats

- The card parts moved to `SummaryCard.swift`, shared by both columns: `GroupHeader`, `CardRow`, `ItemButton`,
  `FoldButton`, `SummaryLink`, `.summaryGroup()`, `SummaryFooter`, `NowGroup`, `ContextMeter`, `UsesRow`, `KnowsRow`.
- **A chat's column** (`ChatSummaryPanel`): **Now** while it answers ("Searching the web", "Reading a page", "Using
  <tool>", "Answering") or waits on you; **Context** with the meter as header (no Compact: the engine compacts Build
  sessions only), **You gave** (files sent, opening in the viewer) and **Read** (pages, title and host, five then
  "and N more"; an untitled page shows its address); **Setup** with **Uses** ("the web" plus apps and servers, unfolding
  into Web search and a switch each) and **Knows** (skills). No Plan or Made: chats keep no checklist and write no
  files. The model card left (it's in the composer), as did the separate Web search row.
Checked with captures: a chat with an attached file and a fetched page, and Build's column again after the move to
shared parts. Not seen: Now in a chat, Uses unfolded, a chat with apps connected.

## Step 3, built 2026-11-06: notebooks and agents

- **Notebook** (`SpaceInspector`): Topics stay on top as they were (they're the notebook's plan, what it decided, and
  how you move around). Below: **Context** with **Remembers** (the first three facts, See all) and **Has** (its files,
  opening in the viewer; Add files…), then **Setup** with **Uses** (MCP servers, a switch each) and **Knows**.
- **Agent** (`AgentInfoPanel`): the name and its line, then **Now** (working, or waiting for your approval), **Made**
  (Last run, when and what it sent; Next, "Today 8:00" / "Tomorrow 8:00"; See all opens Activity), **Context** with
  **Remembers**, and **Setup** (Edit): **Does**, **When**, **Can** (the switches), **Reaches** (you in Piopio),
  **Runs on**. The footer keeps the model, the month's cost and when it runs. Agents have no Uses or Knows yet: they
  don't take connectors or MCP servers, and skills aren't offered to them.
- `ToolChoicesSection` (the old "Connectors and MCP · N on" block) is gone; `UsesRow` replaced it everywhere.
- Card labels stay on one line (68pt column) and links don't wrap, for the notebook's narrower column.

Checked with captures: a new notebook (no topics, memory or files yet) and an agent after a run. Not seen: a notebook
with topics, facts and files; an agent with a schedule (Next), facts, or working (Now).
