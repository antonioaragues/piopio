# Agents and automations: what's built (2026-11-19)

The handoff is in [`handoff/`](handoff/README.md) (open `Agents and Automations.dc.html` with `support.js` beside it).
The app follows it directionally; where our specs had already decided otherwise, the spec wins. Captures are in
[`app/`](app/), made with the scripted model (`PIOPIO_DEMO_AUTOMATIONS=list|page|chat|from|setup|empty|ask|new|draft|draft-on`).

## Built

| Screen | What's in the app |
|---|---|
| 1 · Agents | The sidebar's Agents row opens your agents as a 264pt column (`AgentsColumn.swift`): title and black +, Search agents, a row per agent with its 40pt tile, name, time and the last line of your chat (or Working…, Paused, Learning its job). The agent's page fills the rest. The row opens the agent you had open last. The new agent page sits beside the column too. |
| 1 · Agent header | A 64pt tile, the name at 24 bold, "what it's for · model", the "N automations ›" link on its accent tint, and Chat · Setup as underlined tabs. Run now, pause, other conversations and Finder are in ⋯. The glance row (Next · Can · Reaches you · This month) is gone: it carried a schedule. |
| 2 · Creation card | A card of its own (`AutomationCard.swift`): "New automation" and the name, When · Runs as · Does · Tells you, a strip with the green dot, "Runs on this Mac, only while it's awake · first run Mon 23 Nov", Open in Automations and Undo. Undo leaves "Undone. X won't run. Redo"; Redo brings it back (`automations.restore`). The same card for Piopio's and an agent's. |
| 2 · From label | An automation's run that wrote to you shows "From **Daily price check** · 08:00" above the message, a soft capsule that opens the automation. A run that didn't write says how it went under the label. |
| 3 · Setup | One centered column: Who it is (name and icon, what it's for, instructions, model, thinking, memory "N things learned · View"), What it can use, Where you reach it (Piopio Always, Telegram Connected or Connect…, Slack and WhatsApp Later) and the people it talks to, Limits, and the grey closing block on its automations with a row each and Open Automations ›. Groups are white cards. |
| 4 · Automations | Title and line, New automation as a bordered secondary button, chips (All · Piopio · each agent with its tile, and "In shop ×" when filtered to a project), the green "Runs on this Mac" line. Groups Needs you (amber) · On · Paused, each header naming the columns (1.7fr 1fr 1fr 1.25fr 40). New badge in accent, paused rows at 0.45 with the switch at full strength, amber when a run waits for you. |
| 5 · An automation | ‹ Automations and Run now (black); the name at 28 bold with On/Paused and its switch; the sentence at 23pt in a white card, when and what in bold, who, where and the result in blue opening native popovers with a caption, rows and a ✓. Where is grey for an agent and says why. The result offers Telegram only when the agent has it connected. What it's told; While you're away with two selectable cards, budget chips ($0.10 · $0.25 · $0.50 · $1.00 · Other…), what it may use with a link to the agent's Setup or the project's settings, and Runs on. Delete automation in red. Runs in a 300pt column on #F7F7F5: cards with when, cost, what happened and Open conversation ›; a dashed "No runs yet. First run: …" for a new one. |

## Asking and New automation (2026-11-22)

Built from the HTML prototype in [`prototype/`](prototype/index.html), which replaced the New Automation sheet.

| Screen | What's in the app |
|---|---|
| Nothing yet | The sidebar's Automations glyph in a grey circle (the piopio mascot is Home's alone), "What should happen without you?" (or "Rita doesn't run anything on its own yet"), the line, a box with who sets it up and send, four ideas (Morning brief · File invoices from email · Tidy Downloads · Weekly recap) that fill the box, and "Runs on this Mac · Set one up yourself". Capture: `app/empty.png`, `app/empty-dark.png`. |
| Asking | Sends to a new Piopio conversation or the agent's chat and stays: "Piopio is setting it up…" in the box, then a dark note at the foot, "Piopio set up “Morning brief” · Every weekday at 08:00 · first run tomorrow 8:00" with Open and Undo, and the row with New. If no automation came of it: "answered instead" or "needs your OK", with Open conversation. Capture: `app/ask.png`. |
| New automation | With automations, a 400pt popover: "What should run on its own?", the box, three ideas, "Set it up yourself →". With none, it focuses the box on the page and rings it in accent. Capture: `app/new.png`. |
| Draft | The automation's page with nothing saved: grey "New automation" title, the sentence ("to …" until you write), What it's told focused, While you're away with the usual defaults, a dashed "Not on yet. First run would be …". Discard · Turn on (⌘↩). Turn on opens the saved one's page. Captures: `app/draft.png`, `app/draft-on.png`. |

- The draft's sentence words (when, next run, result) are worded in the app (`AutomationWords`) the way the engine
  words them, for the schedules the trigger editor makes.
- Asking waits up to two minutes for the runner; it reads what's new in the list once the runner has answered.

## Where the app differs, on purpose

- **No agent rows in the sidebar.** Spec 18 CF10 keeps the sidebar to one Agents row (pinned agents stay in Pinned);
  the new column is the list. The handoff's sidebar section with a row per agent isn't built.
- **When can still be changed in place.** The handoff makes the time bold and not clickable (no time picker in v1).
  Piopio already had a trigger editor (time, email, file, URL), so the bold time opens it in a popover, with a faint
  dotted underline. The helper line says so.
- **Switches keep the app's style** (the system switch), not the handoff's accent switch, so they match Settings.
- **Piopio's avatar is the chick**, not a black "P" tile.
- **Setup stays a form.** The handoff shows values; Piopio edits them there, so the groups hold the existing controls
  (tool levels Off · Asks · Allowed, limits fields) with Save ⌘S, History and View as file kept.
- **No "Data" row** in What it can use and no Telegram handle: agents don't have either yet.
- **Redo lasts while the engine runs.** Removed automations are kept in memory for Redo, not on disk.

## Not checked

- The popovers and Undo → Redo were checked in code and the engine test, not in a capture.
- Dark mode was captured for the automation's page and the empty list only.
- Asking with a real model (rather than the scripted `automate` call), and the runner menu, were checked in code only.
