# Activity log

Proposal and build (2026-11-05): `activity.html` is the clickable mockup (now vs proposed; done, opened, working, a
failed command).

What a turn did before answering (thinking, reads, commands, edits) is one quiet line that opens into a short log.

- **The line** is one run of text in the order things happened: "Thought for 4s, ran a command, read README.md".
  File names are a shade darker, with no box (the box broke the sentence and left a gap before the comma). Edits keep
  their green +N. A failed command reads "ran 2 commands (1 failed)".
- **Opened**, a log on a thin rail: a glyph per step (thought, read, ran, wrote, searched…), the verb and its object in
  mono, and on the right how it ended (+N, exit code in red, duration; steps under 0.1 s show none). A failed step's
  glyph is a red ✕. Open (files) and Copy (commands) show while pointing at the row, in grey.
- **Thinking** is the first step: "Thought for 4s", then two lines of it in small grey, with Show all / Show less (it
  scrolls past 360 pt). No second disclosure, no thick rule.
- **Commands and scripts** show a short activity label instead of executable code. Bash accepts an optional
  `description`; codemode uses a leading `// Task:` comment, after any `// @options:` line. Labels use the user's
  language; old calls without one show "Running a command/script" or "Ran a command/script". Opened: the exact
  command or script, then its output. Commands retain Copy; a `cd` outside the project shows "in <folder>" on the
  right. Approval rows still identify the actual command.
- **External tools** show readable operation and server names. The original tool name, arguments and output are
  available when opened.

Code: `ItemRenderer.activityParts` (order), `displayCommand`, `toolCard` (glyph, Copy, full command),
`DisclosureCardView.line` and `LogStepView` in `Cards.swift`.

Checked with captures of a scripted Build session (the faux model gained `think:` lines): closed, opened, and with a
failing command. Not checked by hand: hovering a row to see Open/Copy, and Show all on a long thought.
