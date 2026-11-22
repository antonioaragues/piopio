# Apps and the Library mockup (2026-11-22)

`Apps.html` is a review mockup for a proposed next step of [spec 25](../../spec/25-visuals.md): a saved visual
that reads live data, and a Library that lists everything Piopio and your agents make. It's drawn in the grey style
(docs/design/grey tokens, light and dark, card layout). It is a reference, not a handoff: nothing here is built,
and there's no spec yet. The numbers are made up but add up.

- **A** · clickable: a visual of expenses.csv in a project conversation → **Keep** (what it reads, how it
  refreshes, pin it in the Library) → the app as a page with a conversation beside it → changed by asking (by
  month, a budget line) → the file changes and the app redraws with no model → **the Library**, where rows show
  where each item came from and Pin puts it on the shelf and under Library in the sidebar.
- **B** · the Library with a mockup selected: a shelf of pinned items, then everything by day, filtered by kind
  and place. It's an index of files where they already live, not a store; code stays out.
- **C** · "This week": Google Calendar through a read-only connector tool, bills from Gmail through a small script,
  the Sources popover, the timer as a model-free automation.
- **D** · a change that adds a source waits for Allow; a source that fails keeps the last data and says why.
- **E** · an app made from Overview › Spend, reading Piopio's own `stats.spend` (spec 34 stays native).
- **F** · the file (a JSON manifest at the top, `piopio.onData`) and the flow: sources → engine → offline page,
  with your click as the only way back.
