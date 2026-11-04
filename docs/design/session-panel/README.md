# Session panel

Proposal (2026-11-04): `session-panel.html`, a clickable mockup. Three ideas from Claude's app, adapted:

1. **The composer's + as a menu**: files or photos (⌘U), a folder, commands and skills, connectors and MCP servers
   for this conversation, web search, and Add extensions.
2. **Views as icons in the toolbar**: Summary, Changes, Files, Terminal; then Open in and ···.
3. **A Summary column**: where it runs, context, connectors and MCP, the agent's checklist, results, and the cost.

Order: (1) toolbar and Summary in Build sessions, app only; (2) the + menu; (3) connectors and MCP per conversation
(engine); (4) results beyond files, then Chat, Notebooks and Debates.

## Step 1, built 2026-11-04

- **Toolbar** in Build sessions (and folder chats): Summary, Changes and Files icons open the right column on that
  view, and clicking the lit one closes it; Terminal (⌃`) toggles the drawer (not in folder chats); then a divider,
  Open in (icon only, the app's name in the tooltip) and ··· (Session Tree, Review All Changes, Reveal in Finder, Copy
  Path). ⌘⇧I still shows or hides the column. The segmented Changes | Files control is gone.
- **Summary** (`SessionSummaryPanel` in `BuildReview.swift`): Where it runs (This Mac; the folder, which reveals it in
  Finder; the branch with what waits to push or pull and the git menu as a chevron; a worktree's base; the
  permissions menu), Context (percentage, meter, tokens, Compact), the Checklist, Results (each changed file with its
  +/−, opening its diff; Review), and the session's cost.
- **Changes** is the former inspector without the checklist (which Summary shows): changes, Review diff, Commit…,
  turns with Rewind, context and cost.
- The column opens by itself on Summary the first time a session changes files; after that your choice is kept per
  session, as before. The git menu left the toolbar for Summary's branch row.

Checked with captures (light and dark) of a scripted session that keeps a checklist and writes and edits files. Not
clicked: the toolbar icons and menus, because the user's own Piopio was open.

## Step 2, built 2026-11-04

- **The + is a menu** in every conversation composer (chats, Build sessions, notebooks, agents, debates): Add files or
  photos (⌘U), Add a folder, Commands and skills (puts `/` in an empty box and shows the list; greyed out while
  you're typing), Web search as a switch (chats and debates; notebooks and agents always have it), and Add
  extensions…, which opens Settings › Extensions. In Build the first two read "Mention files" and "Mention a folder",
  because Build sessions read files themselves (they become @paths).
- **Web search** left the composer's row: a globe shows while it's on, and clicking it turns it off.
- **Start pages**: the chat page's + offers files or photos and a folder (its readable files are attached); the new
  session page's + offers files and a folder, which goes into the task as an @path.
- Folder attaching is shared (`AttachmentLoader.folder`): at most 20 files, skipping hidden files, dependencies and
  build output, with a note on what was left out.

Checked with a capture of a chat's composer (+ and the globe). Not checked: the open menu (a window capture can't
show it, and the user's own Piopio was open, so no clicking), ⌘U, and the start pages' menus.

## Step 3, built 2026-11-04

- **Settings decides what's on; a conversation can only turn things off for itself.** Chat MCP is opt-in because
  chats don't ask before a tool runs, so the + menu doesn't turn on what Settings keeps off: those are listed greyed
  out, with why ("Off for chats in Settings", "Off in Settings") and links to Settings › Connectors and › MCP servers.
- **Engine:** a conversation's `toolsOff` list ("connector:<id>", "mcp:<server>"), set with `sessions.configure` and
  shown on its summary. Chats leave out a turned-off app's calendar and mail tools and a turned-off server's tools
  (reinstalled at once, keeping the connections). Notebooks do the same for MCP servers. Build sessions keep pi's MCP
  connections (pi reads `mcp.json` for every session) and refuse a turned-off server's tools through pi's tool
  pipeline, codemode included, and the model is told which servers are off. Debates and agents don't have the switch.
- **App:** "Connectors and MCP · N on" in the + menu, a switch per app and server for this conversation; and in Build's
  Summary a "Connectors and MCP" row (on, off here, to sign in again) that unfolds into the same switches.
- Tests: an MCP server turned off and back on in a Build session (refused, then answered) and in a chat (not offered,
  then answered); a calendar turned off and back on in a chat.

Checked with a capture of the Summary row ("1 on", with a server off in Settings). Not clicked: the submenu and the
row's switches, because the user's own Piopio was open.

## Step 4, built 2026-11-05

- **Build results gain commits**: the branch's commits since the session started (by the agent or by you), from a new
  `git.log` call (newest first, `since`, `limit`). A commit row copies its hash.
- **Chats get the Summary column**, toggled from a toolbar icon (remembered for every chat): the model and context,
  web search as a switch, Connectors and MCP (the same section as Build's), and Results: the files you shared and the
  pages it opened or found while searching (each opens in the browser), then what the chat cost. Debates keep their
  own draft pane.
- **Notebooks** get the Connectors and MCP section at the bottom of their right column (MCP servers, for the notebook).
- The Connectors and MCP section is one shared view (`ToolChoicesSection`) used by all three.

Checked with captures: a chat's column (model, web search, "Connectors and MCP · 0 on" with MCP off for chats in
Settings, two shared files) and Build's Summary with the section back ("1 on"). `git.log` has an engine test. Not
seen in a capture: a commit row (the scripted commit waited for approval), sources from a real web search, and the
notebook section; nothing was clicked, because the user's own Piopio was open.

## The same toolbar everywhere (2026-11-05)

Views first as icons (lit while showing; `ToolbarIcon`), then a divider and ··· (`ToolbarDivider`):

| Where | Views | After the divider |
|---|---|---|
| Build session | Summary · Changes · Files · Terminal | Open in · ··· |
| Chat | Summary · Move to a notebook (a menu) | ··· (copy, export, cost) |
| Debate | Stop or Keep going (text) · Draft | ··· |
| Notebook | Topics (the right column) · Go to a topic (when the column is hidden) · Memory · Files | ··· |
| Agent | Info · Activity · Setup · Run now | ··· (pause, Finder) |

The "All topics" and "Back to the conversation" pills are gone: the title's breadcrumb, or the lit icon, goes back.
The composer no longer shows a globe for web search (it's a switch in the + menu and in a chat's Summary), and the +
menu's items show their icons.
