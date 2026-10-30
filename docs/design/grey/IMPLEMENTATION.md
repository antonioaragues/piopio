# Grey ink in the app

Screen-by-screen audit of this handoff ([README](README.md), `Piopio grey.dc.html`, a render of every screen in
`screenshots/`) against the SwiftUI app, done on 2026-10-30 after a first pass had marked too much as done.
**Checked** means compared with a capture of the app running the scripted model. **Code only** means built but not
seen running. Nothing here has been used with real models.

| Screen | State | Checked | Differences |
|---|---|---|---|
| Tokens and principles 1–7 | Built | Yes | The chick remains in onboarding |
| 9a Sidebar, window, toolbar | Built | Yes | Also has Home and Pinned; the git menu stays as an icon |
| 9a Inspector | Built | Code only | A checklist shows above Changes when the agent keeps one |
| 10a New menu | Built | Code only | A native menu; also offers Debate; no ⌘N/⌘⇧N labels |
| 10b Search ⌘K | Built | Code only | Keeps the scope selector |
| 10c | Replaced by 14b | n/a | The README says so |
| 10d Diff review, collapsed sidebar | Built | Yes | No per-file checkboxes (Commit opens the commit sheet); keeps Whole session / Last turn |
| 10e Settings | Built for the list and Models' first page | Partly | Other panes only got hairline groups and grey tiles; they keep their own structure |
| 10f Quick Chat | Built | Yes | Also has New chat |
| 11a Turn | Built | Yes | Answer text stays 15 / 1.45, set by the user on 2026-10-29; Copy sits beside the language, not at the right edge |
| 11b While working | Built | Code only | No live output under the running step; Edit on a queued message moves it back to the box |
| 11c Approvals | Built | Command: yes. Diff: code only | Allow is ⌘↩, because ↩ sends from the composer; MCP arguments show as text, not labeled rows; decided approvals in Build show in the activity line |
| 11d Questions | Built | Yes | Options have no description (the engine sends names only); no "change" after answering; steps are one card at a time |
| 11e Composer | Built | Partly | @mentions are plain text, not grey tokens; files show their extension, not page counts |
| 11f Model picker | Built | Yes, with one model | The line per model is derived from price and abilities, not curated; ⌘↩ sets the default |
| 11g Mode picker | Built | Code only | A native menu; Plan, Ask before edits, Auto-edit, Full auto (no Read only); no ⇧⇥ |
| 11h Interruptions | Built | Code only | The 85% context line replaces the ring; Compact now only in Build |
| 12a–12d Debate | Built | Yes (running, agreed, Changes) | One document, so one tab; objections explain a version as a list above the document, not beside each change, because the engine records them per version |
| 13a Agent | Built | Yes | Automatic runs are labeled "Automatic run · 8:00"; no day separators; failed runs show in Needs you, not in the conversation; no Telegram or "Keep it always on" |
| 13b New agent | **Not built** | n/a | Still the form sheet: drafting from a sentence needs engine work |
| 13e–13f Notebook | Right column built | Yes | Topics stay separate conversations with Main; no merged timeline with headings, no Where it stands, no Decided/Open states |
| 14a Home | Built | Yes, without Coming up data | Also lists sessions under Recent by project |
| 14b Needs you | Built | Message: yes. Approval and failed run: code only | "Set up a provider" appears when no model is connected, not per provider |

## Captures

`app/` holds captures with the scripted model.
