# The project page

`proposals.html` holds three mockups and the linked-folders design (2026-11-15). The user picked **A**, a project home
in two columns, because what the project is stays in view. Decisions in
[spec 18 §18](../../spec/18-conversation-first.md) (CF17–CF19). `app/` holds captures with the scripted model: a
project with two linked folders (`project.png`), and the same with a team (`project-team.png`, with the board line).
The long `/private/var/…` path is the capture's temporary folder; real projects show `~/…`.

Different from the mockup:
- The right column's last block is "Project": Who (with Change), Starts in (the permissions menu) and Routines, in the
  Summary panel's label-value grid. Changing who works here or the routines opens Settings.
- The column has a toolbar button to hide it.
- "Add folder…" for a single conversation (the box's +) isn't built.

> **2026-11-16:** the page is gone; its column became the settings sheet ([project-settings](../project-settings/README.md), spec 18 §19).
