# Project settings

`proposal.html` (the row, the sheet, what changes) and `editing.html` (Instructions and Memory, edited in the sheet or
in your editor), 2026-11-16. Decisions in [spec 18 §19](../../spec/18-conversation-first.md) (CF20–CF23). `app/`
holds captures with the scripted model: the project you're in with its settings and + buttons and a team's Board row
(`row.png`), the sheet (`sheet.png`) and the Memory editor (`memory-editor.png`). The long `/private/var/…` paths are
the captures' temporary folders; real projects show `~/…`.

Different from the designs:
- The editor is a plain text view: no bold headings or grey list marks, and no dashed line where memory stops being
  read (the footer's meter says it, in amber past the limit).
- "Who works here" keeps today's two cards (Piopio alone, A team) instead of a segmented control.
- Routines keep today's list with "Add routine…".
- A project with nothing under it starts a conversation when its row is clicked, since there's nothing to fold.
