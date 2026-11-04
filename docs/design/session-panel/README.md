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
