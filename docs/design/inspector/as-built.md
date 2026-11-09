# Inspector, Files and toolbar: as built (2026-11-09)

The handoff is in [README.md](README.md); the canvas is `Harness Panel Proposals.dc.html` (approved: 5a, 2a, 4a, 3a).

## Where it lives

- **Toolbar** (`BuildViews.swift`, `SessionPanel`):
  - The icons are Inspector (`sidebar.right`, ⌘I) and Files (`folder`, ⌘P), then Terminal, a divider, and `…`.
  - A blue dot sits on Inspector while the session waits on you.
  - "Open in <editor>" moved into `…` in an earlier change.
- **Inspector** (`Inspector.swift`):
  - `InspectorPanel` holds the tabs. The tab is remembered per session (`inspectorTabs` in defaults).
  - **Session tab:** Setup (Project · branch with the git menu, Runs on, and Tools, which unfolds into the old Uses
    and Skills switches), Read, and the plan's three states.
  - **Shared footer:** `InspectorFooter`.
- **Changes tab** (`InspectorChanges.swift`):
  - On top, the header: files, commits, +/−, and how many are new.
  - Then the timeline: Not saved yet, then the commits since the session started, newest first and open. Three are
    shown before "N earlier commits".
  - A file opens the diff review.
  - Right-click a file in Not saved yet to revert it.
- **Files** (`FilesPanel.swift`):
  - At the top: the filter (the same file search as @), and All or Touched.
  - The tree marks files N (new), M (changed) or R (read), and folders with a dot when something inside was touched.
  - **Touched** is what this agent did with its own tools: the files it read and the ones it wrote or edited. It isn't
    everything that changed in the folder since the session started, which in a long session also counts your
    commits, other agents' work and what commands changed. The Changes tab shows all of that.
  - At the bottom, the legend.
  - Clicking a file shows its preview in the panel: Diff or File, Open in editor, Mention in chat.
- **Engine:**
  - `git.log` returns each commit's files with +/− (`--numstat`).
  - `git.status` gives each uncommitted file's +/−; for an untracked file, its number of lines.

## Different from the handoff

- **Terminal stays the drawer under the conversation,** not a right-hand panel. It doesn't close the Inspector or
  Files, so the three buttons aren't mutually exclusive.
- **The old Summary rows the handoff drops are gone:** Now, Made (now the Changes tab), You gave, Follows, and the
  Context group. The old Changes view's list of turns is gone too; Rewind to here stays on each message.
- **The wide file preview beside the conversation is gone.** Path chips, file cards and Read open the Files panel's
  preview instead, as 3a shows.
- **The Read row of a session that has read nothing says "Nothing yet".**
- **No plan:** "Ask for one" appears only after the first answer, while the session is idle. Before that the row says
  "It makes one for longer tasks."
- **The done plan shows a duration only past a minute,** measured from the first checklist update to the last.
- **Chats keep their own summary column,** but now use the same footer, so context and cost aren't shown twice.
- **Colours use the app's tokens,** so light mode works too. Two were added: `dsWarn` (DS.amber) and `dsRead`.

## Checked

- **App screenshots:** Debug app, scratch data, faux model. They covered:
  - the Session tab with a plan in progress, and with a finished plan;
  - the needs-you dot while a command waited for approval;
  - the Changes tab with Not saved yet and two commits;
  - Files with Touched;
  - a modified file's preview, which opens on Diff.
- **Seen later the same day:** the no-plan state; All with the project's tree; Touched with only N, M and R files.
- **Not seen yet:**
  - "6 earlier commits";
  - a session without git;
  - light mode.
