# 35 · Apps and the Library: visuals that stay live, and one place for what Piopio makes

Status: draft 2026-11-22, from a conversation with the user. The user asked for the Library as a section of its own,
with pins kept there instead of the sidebar's Pinned (AL1, AL9). The other decisions are proposed and still need
confirming (§12). **L1 (the Library) built 2026-11-22 (§13); L2 (apps on files, §14) and L3 (changing an app, §15) built the same day**. Mockup: [docs/design/apps](../design/apps/Apps.html), which includes a clickable
prototype. This spec continues [25](25-visuals.md): VS3 (saved visuals are files), VS4 (the engine records and the
app draws), VS5 (no network) and VS7 (a visual talks back only on your click) all still hold.

**The idea:** an app is a saved visual plus a list of where its data comes from. Piopio reads those sources and hands
the result to the page, so the page never reaches out. The Library lists everything Piopio and your agents make,
wherever the file lives, and pinned items go at the top of the Library.

## 1. Why

- **A visual is a snapshot.** The data is written into its HTML (25 §4.4: "a visual that needs data gets it in its
  HTML"). "Chart my spending" drawn today is wrong tomorrow. Asking again means a model rewrites the whole page, so it
  costs tokens and comes back looking different each time.
- **What Piopio makes gets lost.** A chat's files are in its own folder under `~/Library/Application Support/Piopio/
  scratch/`. A project's files are in that project. An agent's files are in `~/Piopio/Agents/<name>/files/`. A
  visual you didn't save exists only in the transcript. To find "the gas comparison from Saturday" you have to
  remember which conversation made it.
- **The direction others are taking.** Apps you keep and customize are where agent platforms are heading
  ([the "Agent platform 2027" memo](https://x.com/john_ssuh/status/2124336124172935336), Claude's artifacts you can
  install, Cowork with customization). Piopio already has the hard parts: a sandboxed web view (25), read-only
  connector tools (12), codemode, automations (27) and Piopio's own numbers (34).

## 2. The experience

**An app**
1. In a project you ask "Chart my spending by category from expenses.csv". A visual card appears, as it does today.
2. The card has a new button, **Keep**. Its popover shows the name, what the app will read (`data/expenses.csv`),
   when it refreshes (when you open it and when the file changes, with no model), where it will be saved, and a
   **Pin it in the Library** checkbox, ticked by default. Nothing is written until you click Keep.
3. Piopio takes one short turn to rewrite the visual so it reads its data instead of carrying it. It saves the file
   and says so in the answer.
4. The app opens as a page in the content card. Piopio's toolbar is above it: the name, "Updated 10:42",
   **Refresh**, **Sources**, and ⊘ for offline. Next to it is a conversation about the app.
5. You ask for a change ("Split it by month and add a budget line at 1.100 €"). The model edits the file, the page
   reloads, and the edit is a checkpoint like any other (Undo).
6. When `expenses.csv` changes, the app redraws without running a model.

**The Library**
1. **Library** is a sidebar row under Automations, with your pinned items indented beneath it.
2. Its page has a **Pinned** shelf of tiles, then everything else by day. You can filter by kind and by place, and
   search.
3. Clicking a row shows a preview: the file, the conversation that made it, who made it, when, and how many versions
   git has. It has **Open**, **Pin** and **Show in Finder**.

## 3. Apps

### 3.1 The file

An app is one `.html` file with a manifest at the top:

```html
<script type="application/json" id="piopio-app">
{
  "title": "Spending",
  "sources": {
    "expenses": { "file": "data/expenses.csv" },
    "week":     { "tool": "calendar_list_events", "args": { "days": 7 } },
    "bills":    { "script": "bills.js", "tools": ["gmail_search"] },
    "spend":    { "piopio": "stats.spend", "args": { "groupBy": "agent", "range": "month" } }
  },
  "refresh": { "onOpen": true, "onChange": true, "every": "1h" }
}
</script>
<script type="module">
  piopio.onData(({ expenses, week, bills, spend }, { updatedAt, stale }) => draw(...));
</script>
```

- **Where it's saved:** in a project, in the project's folder (`apps/` by default). Elsewhere, in `~/Piopio/Apps/`,
  next to `~/Piopio/Agents/`. A script source sits beside its app (`apps/bills.js`).
- **The rest is a visual:** the same tokens, libraries, CSP and `piopio.send` / `piopio.prefill` as 25 §4. The only
  new thing in the wrapper is `piopio.onData`.
- **It's still a file:** git, checkpoints, the file viewer and Finder all work on it. If you open it in another
  browser it draws its last cached data, or "Open in Piopio to see live data" when there is none.

### 3.2 Sources

| Kind | Reads | Runs a model | Refreshed by |
|---|---|---|---|
| `file` | A file in the app's project, or under the app's own folder: CSV, JSON, Markdown or text. Its parsed rows or text go to the page. | No | Opening it, the file changing, the timer |
| `tool` | One connector or MCP tool with fixed arguments. It must be a **read** tool (12's `access: "read"`, MCP's `readOnlyHint`). | No | Opening it, the timer |
| `script` | A small JavaScript function in codemode's sandbox that calls only the tools listed in the manifest, all of them read tools, and returns JSON. The model writes it once. | No | Opening it, the timer |
| `piopio` | Piopio's own numbers: 34's `stats.*`, automation runs, agents and their status. | No | Opening it, the timer |

There's no source that asks the model on each refresh. Work that needs a model belongs in an automation (27), which
can write a file that an app then reads. That keeps "refreshing costs nothing" true, and it keeps everything that
spends money in Automations, where 34 counts it.

A source has limits: 10 s per read, at most 2 MB of JSON per source, and a script may make at most 20 tool calls.
When a source goes over, it fails (§3.5).

### 3.3 Refresh

- **`onOpen`:** when the page is shown, if the last read is older than a minute.
- **`onChange`:** `file` sources are watched like folder watches (`watchers.ts`), with the same settle delay.
- **`every`:** at least `15m`, and only while the app is pinned. It's an automation with no model (27): it appears in
  Automations as "Refresh *Spending*", with its runs and $0. Unpinning pauses it.
- **Refresh** in the toolbar reads everything now.

The last result of each source is cached in the engine's data folder (`apps-cache/<hash of the path>.json`), not in
the project, so git stays clean. An app opens straight away with that data and then refreshes.

### 3.4 Allowing sources

- **Keep allows them.** The popover lists every source, and clicking Keep allows that list.
- **A different list asks again.** If an edit adds a source or changes a tool or its arguments, the app keeps
  drawing the last version you allowed and shows a banner: "This app now also wants to read *Gmail attachments*",
  with **Not now** and **Allow**. A source is never added silently.
- **Allowed by content, not by name.** What's allowed is the manifest's sources. Changing only the page (layout,
  colours, a new chart) asks nothing.
- **Read only, always.** A write or destructive tool can't be a source at all; the manifest is refused with the
  reason. Acting on data stays in a conversation or with an agent, where approvals live. An app's button can only put
  words in the composer (`piopio.prefill`) from your click.

### 3.5 When a source fails

The app keeps the last good data, and the toolbar says what happened in amber ("Calendar didn't answer at 11:00"),
with the one fix that would help: Sign in again, Retry, or Open the file. `onData` receives `stale: ["week"]` so the
page can grey that part out. A pinned app whose timed refresh fails three times in a row gets the blue dot on its row
under Library.

### 3.6 The app page

- **Toolbar** (44 pt, in the card): ◫ and the title, then "*project* · Updated 10:42", then Refresh, Sources
  (a popover listing each source with its last read and size, the refresh rule with its cost, and Edit…), ⊘ (offline,
  tooltip "This page can't reach the internet"), and ◧ to show or hide the conversation.
- **The app** fills the card at full width and scrolls. It's live while it's shown (25 VS8: one web view per open app).
- **The conversation about it** is a right panel, 300 pt wide, open the first time and remembered after. It's a
  normal conversation in the app's project (or a chat, for apps in `~/Piopio/Apps/`) with the app file attached as
  context. Its prompt says to edit that file and to keep the manifest unless you ask. Each edit reloads the page.
- **Keep from any visual card:** Keep is in the card's header next to Open, Save… and Copy HTML. Save… stays as a
  plain snapshot, which is still useful for sharing.

### 3.7 Making an app on purpose

Besides Keep, you can ask for one directly ("make me an app that shows this week's calendar and the bills due"). The
model calls `make_app({ title, html, sources, refresh, folder? })`. That shows the same Keep popover as a card in the
answer, and nothing is saved until you click Keep. Overview › Spend gets **Make an app of this…**, which opens a
conversation with the question already written (34 stays native; the app reads `stats.spend`).

## 4. The Library

### 4.1 What it is

It's an index of files, not a store: each item is a file where it already lives (25 VS3, 18 CF4). The index is
`<home>/library.json`, with each item's path, kind, the note on it, where it came from (conversation, project or
agent), who made it, when, and whether it's pinned. It lists files but never moves or copies them.

### 4.2 What goes in

Items are added on their own:

| Comes in | When |
|---|---|
| **Apps** | When kept or made (§3) |
| **Files handed over** | Every file in a `present_files` call, from a conversation, a Build session or an agent. That's the signal that "this is for you", and it keeps code out: Build writes many files but hands over few. |
| **Files written in a conversation's folder** | Files a chat writes in its own folder, of a kind meant to be looked at (pages, documents, data, images, slides), even if never presented |
| **Saved visuals** | Save… on a card |
| **Visuals not saved** | Every `show_visual` card, marked "in a conversation", with **Keep** and **Save…**. Drafts replaced in the same turn (25 §3.4) aren't listed. |

You can also add or remove items yourself:
- **Add to Library** is in the ⋯ menu of any file card, in the file viewer, and in Build's file tree.
- **Remove from Library** hides an item and leaves the file where it is.
- **Move to Trash** is a separate, confirmed step, and it uses the Finder Trash.

**Notes:** when Piopio makes a file it writes a one-line note on it, the way agents do with `note_file` (06 §14), so
the list and search can say "Gas offers from Iberdrola, Naturgy and Repsol, compared". The note is generated on the
Library's utility model when `present_files` didn't give one.

**Kinds:** App, Document (`.md`, `.pdf`, `.docx`, `.txt`), Page (`.html` that isn't an app), Visual (a card, or a
saved visual), Image, Data (`.csv`, `.json`, `.xlsx`), Slides.

### 4.3 The page

- **Where:** the sidebar row **Library** (▥), after Automations, and ⌘K ("Library", or an item's name).
- **Title row:** "Library" (20 bold), and a search field on the right.
- **Filters:** a kind segment (All · Apps · Documents · Pages · Visuals · Images · Data), and a place picker as plain
  text ("All places", a project, an agent, Conversations).
- **Pinned shelf:** tiles three per row, each with a thumbnail, the name, and the kind with "updated 9:00" or
  "changed Sat". Clicking a tile opens the item.
- **Everything else:** grouped Today / Yesterday / Earlier this week / by month. Each row has its icon, name and kind
  (plus "● pinned" or "in a conversation" where it applies), where it is, who made it, and when. Hovering a row
  shows Open · Pin · ⋯ (Show in Finder, Open the conversation, Copy path, Remove from Library, Move to Trash).
- **Preview** (290 pt, when a row is selected): a thumbnail, the name, the note, then Kind and size, File (the path),
  Made in (a link to the conversation), By, and Changed (with "3 versions in git" when it's tracked), then Open, Pin
  and Show in Finder.
- **Opening an item** opens apps as their page (§3.6), visuals in their conversation, scrolled to the card, and
  files in the file viewer (25 §7 for HTML).
- **Thumbnails** come from 25's snapshot for visuals and apps, Quick Look for files, and a glyph otherwise. They're
  cached with the index.

### 4.4 Pins

- **Any item can be pinned.** Apps are the usual ones.
- **Pinned items** go on the shelf, and the five most recent pins show under Library in the sidebar. The rest stay
  on the shelf. You can drag to reorder both.
- **The sidebar's Pinned section** stays for conversations and agents (18 CF10, CF27). Apps and files go only under
  Library.
- **Unpinning** an app pauses its timed refresh (§3.3).

### 4.5 Agents, the cloud and the phone

- **An agent's files** go in the Library when it hands them over (`present_files`). Files you sent the agent stay
  on its page (06 §14 FL2), since you made those, not the agent.
- **Cloud items:** a cloud conversation's or cloud agent's files appear once they sync to the Mac (30 K-phases).
  Until then the Library covers This Mac only.
- **The phone (30's Piopio app):** it shows the Library and draws apps from their HTML and cached JSON. It refreshes
  them through the Mac when the Mac is reachable, and otherwise shows the cached data with "as of 10:42".

## 5. Safety

- **The page is still offline** (25 §5): no network, no files, and no channel back except your click. `onData` only
  goes into the page. The worst an app can do is still to look wrong.
- **Data that reaches the page** was read by the engine from sources you allowed, using read tools only. A visual
  made from a hostile page still can't send anything anywhere.
- **Scripts** run in codemode's sandbox, with only the tools their manifest lists. They have no `fetch`, no file
  system, and nothing beyond the listed tools.
- **Prompt injection through data:** source data reaches the page, not a model. A model sees it only when you ask
  the app's conversation about it, and then it's ordinary tool output.
- **The Library index** holds paths and notes, not file contents. It never sends anything anywhere (01 principle 5, no
  telemetry).

## 6. Under the hood

**Engine**
- `library.ts`: the index (`library.json`). It's fed by `present_files`, writes in chat folders, `show_visual`,
  Save…, Keep and `make_app`. It notices a file being moved or deleted when it lists, and keeps a missing item for 30
  days marked "File missing", with **Locate…** and **Remove**.
- `apps.ts`: parses and validates a manifest, reads the sources (the file reader, `connectors` for tools, codemode
  for scripts, `stats.*` for Piopio), caches the results, watches files, and registers the model-free automation for
  `every`.

**Protocol**

| Method / event | Does |
|---|---|
| `library.list { kind?, place?, query?, cursor? }` | Items with their thumbnails' refs |
| `library.add / remove / pin / unpin / reorder` | What the page and menus do |
| `app.open { path }` | The manifest, the cached data and whether the sources are allowed |
| `app.refresh { path, source? }` | Reads now; answers with the data, or what failed |
| `app.allow { path, manifestHash }` | Allows the current list of sources |
| `app.data` (event) | New data for an open app, from a file change or the timer |
| `library.changed` (event) | The index changed |

**App:** `LibraryPage.swift`, `AppPage.swift` (the toolbar, the visual's web view with `onData`, and the panel
conversation), a Keep popover on `VisualCard`, and the sidebar row with its pins.

## 7. Where it touches other specs

| Spec | Change |
|---|---|
| 25 Visuals | Keep on the card; `piopio.onData` in the wrapper; §10's "Editing a visual in place" happens here, through the app's conversation |
| 27 Automations | A trigger with no model, "Refresh *app*", kind `app.refresh`, $0, shown like the others |
| 34 Overview | Make an app of this… on Spend; `stats.*` open to apps; Activity counts apps and Library items |
| 06 Agents | `present_files` also adds to the Library |
| 18 Conversation first | A sidebar row, Library, after Automations; Pinned stays for conversations and agents |
| 12 Connectors | The read access mark decides what can be a source |

## 8. Phases

| # | Delivers | Done when |
|---|---|---|
| **L1 · Library** | The index, fed by `present_files`, chat-folder writes, visuals and Save…; the page with kinds, places, search and preview; Pin and the sidebar row; Remove, Move to Trash, File missing | Last week's mockups, a chat's CSV and an agent's PDF are listed with where they came from, and pinning one shows it under Library |
| **L2 · Apps on files** | The manifest, `file` sources, `onData`, Keep and its popover, the app page, the cache, `onChange` | Keep on a chart of a CSV makes an app that redraws when the CSV changes, without a model turn |
| **L3 · Changing an app** | The app's conversation panel; edits reload it; checkpoints | "Split it by month" changes the app in one turn, and Undo brings the old one back |
| **L4 · Services and Piopio** | `tool`, `piopio` and `script` sources, allowing and re-allowing, failures, `every` as a model-free automation, Make an app of this… | "This week" reads Calendar and Gmail hourly at $0; a changed source waits for Allow |
| **L5 · Elsewhere** | The phone draws apps and the Library; cloud items once they sync | An app pinned on the Mac opens on the phone with its last data |

L1 is useful alone and doesn't need apps. L2 is the smallest version of apps.

## 9. Not in this spec

- **Apps that write.** A source never writes, and there's no `piopio.call(tool)` from the page. If it's ever wanted,
  it would go through MCP Apps' bridge with per-call approvals (25 D6), not through the Library.
- **Sharing an app** with someone else. Save… and export still give a portable snapshot.
- **A gallery of apps** to install. Your own apps and the ones Piopio makes come first.
- **Apps as Piopio's own pages.** Overview, Settings and Home stay native (01 principle 1).

## 10. What you see, in short

You ask for a chart and click Keep, and it becomes an app that stays current, costs nothing to refresh, and changes
when you ask. Everything Piopio and your agents make (apps, mockups, documents, spreadsheets, images, visuals) is in
the Library, which says where each item came from. What you use often is pinned there and under Library in the
sidebar.

## 11. Not verified

- That `present_files` plus chat-folder writes catch most of what you'd want listed, and not too much. To check, run
  it against a month of real sessions.
- That models write `onData` apps reliably without a worked example, and keep the manifest intact when editing the
  layout.
- Quick Look thumbnails from the engine's side, and their cost for a Library of a few hundred items.
- Codemode's sandbox as a script runner outside a session (it's a pi extension today).
- How 30's cloud sync carries file items.

## 12. Questions

| # | Question | Proposed |
|---|---|---|
| AL1 | A section of its own for what Piopio makes, with pins kept there | **Yes** (the user, 2026-11-22) |
| AL2 | Name: Library, Files, Made, Artifacts | Library |
| AL3 | Is it an index of files where they live, or a store of copies? | An index (25 VS3) |
| AL4 | What comes in on its own: `present_files`, chat-folder writes, visuals, apps; Build's other writes stay out | As proposed |
| AL5 | Do unsaved visuals from conversations show in the Library? | Yes, marked, with Keep |
| AL6 | Name: App, View or Board; and the button: Keep | App, Keep |
| AL7 | A source that asks the model on each refresh? | No; that's an automation writing a file the app reads |
| AL8 | Where apps live outside a project | `~/Piopio/Apps/` |
| AL9 | Pins: on the Library's shelf, with the five most recent under Library in the sidebar | **Yes** (the user, 2026-11-22) |
| AL10 | The timed refresh: shortest interval, and only while pinned | 15 min, only while pinned |
| AL11 | Does the app's conversation open by default? | The first time, then remembered |
| AL12 | Does Overview become an app? | No, it stays native; it's the first `piopio` source |

## 13. L1 as built (2026-11-22)

**Engine.** `library.ts`:
- **The index** is `library.json` in the engine's home. Each item is stored with a key (`file:<path>`, or
  `visual:<kind>:<id>:<conversation>:<call>`), its kind, name, path, note, when, how it came in (presented ·
  written · visual · added), where it came from and who made it. The file also holds the pins in order and what you
  removed.
- **How it fills:** `LibrarySearch` is search with the Library listening. It reads the same items search indexes:
  a whole conversation when it's opened, re-read or backfilled at start, and one item as it changes. So the engine's
  start-up search backfill (which covers agents' conversations and runs too) also fills the Library from history,
  with no pass of its own. The session manager turns search's key into where an item came from (`libraryOrigin`):
  the conversation, its title, Piopio or the agent, the project's folder, and a chat's own folder.
- **What comes in:**
  - every file of a `present_files` call that was found;
  - files a chat writes in its own folder (pages, documents, data, images, slides; not code, not hidden files);
  - every `show_visual` that wasn't replaced. A fix replaces its draft by title within a turn, whether the whole
    conversation is read at once (`replacedVisuals`) or one item at a time (the turn starts at your message).
- **Where it came from:** the first conversation to bring a file in keeps it. A later handover only adds a note it
  lacked, and the conversation's title follows renames.
- **What leaves:** re-reading a conversation drops visuals it no longer shows, and deleting one drops its visuals.
  Its files stay listed.
- **Protocol:** `library.list`, `library.pin`, `library.reorder`, `library.remove`, `library.add` and
  `library.relocate`, plus the `library.changed` event, which is sent at most every 300 ms.

**App.**
- `LibraryPage.swift`: the page (title, search, kind chips for the kinds present, the place menu, the Pinned
  shelf, groups Today / Yesterday / Earlier this week / by month), rows with hover actions (Open, Pin, ⋯), the
  preview, the context menu, Move to Trash with a confirmation, and Locate… with an open panel.
- `MainSidebar.swift`: the Library row after Automations, with the five latest pins under it. A pin opens its item.
- ⌘K: "Library", and items by name once you've typed two characters.
- `PIOPIO_DEMO_LIBRARY=page|preview|<name>` for captures.
- The Swift type is `LibraryEntry`, because SwiftUI already has a `LibraryItem`.

**Different from §4:**
- **Thumbnails:** Quick Look only for images, pages, PDFs and slides. Text, data and Word files came out as blank
  pages at these sizes, so they show their kind's glyph.
- **The title** is 28 pt like Automations', not 20 pt as in the mockup.
- **The place menu** also has "Added by you".

**Checked (first pass).**
- **Engine tests** (`library.test.ts`, 13): handovers with their note and origin, the first origin kept, missing
  files skipped, a chat's writes but not code or hidden files, drafts replaced within a turn and not across turns,
  re-reading, pins and removals across a restart, Add bringing a removed file back, Locate… keeping the pin,
  forgetting a deleted conversation, kinds, renamed conversations, and filling through search. The whole engine
  suite passes (296).
- **Swift test:** decoding the list.
- **In a copy of the app**, with a seeded `library.json`: the page, the preview, and a missing file (red path,
  Locate…, Remove), with pins in the sidebar.
- **Fed live by the scripted model**, in a chat that wrote `lisbon.md`, drew a visual twice with the same title and
  then handed the file over: one document noted "The Lisbon plan", and one visual.

**Not checked:** clicking Open, Show in Finder, Move to Trash and Locate… for real; ⌘K; dark mode; an agent's
handover from a real agent; a Library of several hundred items.

**Second pass (2026-11-22, the same day): what L1 had left out.**
- **Show in Library:**
  - **Where:** in a file card's menu, in the file viewer sheet (chats, files you sent) and Build's file viewer (a
    books icon), and in Build's file tree (a row's context menu, with Open and Show in Finder).
  - **What it does:** `library.add` lists the file, or brings it back if you'd removed it, and the Library opens
    with it selected. That's how you add any file by hand.
  - **How the Library selects it:** a pin, ⌘K and Show in Library set `libraryFocus` on the engine controller,
    which the page takes when it shows. The notification it replaced could arrive before the page existed.
- **Reordering pins:** drag a pin onto another, on the shelf or in the sidebar. It takes that one's place.
- **Visuals:**
  - **Kept:** the engine keeps a copy of each listed visual's HTML in `library-visuals/<id>.html` (gone with the
    visual) and serves it with `library.visual`.
  - **Picture:** the app draws it once off screen, as the visual check does (`VisualChecker`, one at a time), and
    shows it whole, with a margin.
  - **Open:** shows the visual large in the visual sheet. What its buttons send or fill in goes to its
    conversation's composer.
  - **Open the Conversation:** scrolls to the card in a chat or a Build session. An agent's opens the agent.
- **Notes:** a new text file (Markdown, text, CSV, TSV, JSON, HTML) that comes without a note gets one line from the
  utility model, read from its first 3,000 characters. The cost goes to the conversation that made it. It runs one
  at a time, at most 20 an hour, and only for files made from now on, not your history.
- **Missing files:** a file missing for 30 days leaves the Library, and its pin goes with it. One that comes back
  before then is listed as before.

**Checked (second pass).**
- **Engine tests:** 16 in `library.test.ts`. They add visuals' HTML kept and dropped, notes (only new text files
  without one), and missing files leaving after 30 days or forgiven when they come back. The whole engine suite
  passes (300).
- **In a copy of the app:** a scripted chat drew a bar chart and handed over `plan.md`, and the Library showed the
  chart's picture in its row and preview.

**Not checked:** dragging pins, Show in Library from each place, opening a visual large or at its card, and notes
from a real utility model, all by hand; dark mode.

**Third pass (2026-11-22): fixes from a review.** Another agent reviewed L1 and reproduced the first three bugs
below; the rest it found in the code. All were real.
- **Locate… held.** A file's earlier paths are kept as aliases. When the conversation hands over the old path
  again, re-reading it or restarting finds the same item with its pin, not a second one marked missing.
- **Visuals stay current.** A visual's copy is compared by content, not size. Each visual carries a `version` (a
  hash of its HTML) that its picture is cached by.
- **Notes follow the agent's choice.** A file from an agent gets its note the way the agent would choose
  (`models.utility` on its default model's provider). With `off` there is no call at all. A conversation's note
  uses that conversation's model.
- **Hidden folders stay out.** What a chat writes under any hidden folder (`.cache/`, `.piopio/`) isn't listed.
  `present_files` and Add to Library still list anything.
- **Save… is linked.** Saving a visual from its card reports an error if the write fails. On success it tells the
  Library (`library.saved`), so the visual keeps its conversation and pin and now has a file. A later handover of
  that file finds the same item. If the file goes, the visual is listed as unsaved again; it never leaves for being
  missing.
- **Opening says what it does.** From the Library, a visual's buttons fill in its conversation's composer (after
  anything already there) and don't send. The sheet says which conversation. Open the Conversation reaches the
  exact place: a chat's or a Build session's card, or an agent's run or person's conversation.
- **Rows tell files apart.** Two lines, the name and then the note (or the kind), with "by <agent>" when the place
  doesn't say it. The By column is gone. Markdown and text files show their heading and first lines, and CSV and
  TSV files their first rows, in tiles and the preview, instead of a glyph.
- **Add vs Show.** File cards, both viewers and Build's file tree say "Add to Library" when the file isn't in it
  and "Show in Library" when it is. The page has **Add File…**, in the header and the empty state.
- **Filters and loading.**
  - The preview shows only what the list shows.
  - An active kind keeps its chip even when nothing of that kind is left.
  - **Clear Filters** appears when nothing matches.
  - A first load that fails offers **Retry**.
  - The page reads the Library again when it appears and when the app comes back to the front, so files moved
    in Finder show as they are.
- **Removing can be undone.** "Removed … · Undo" shows for six seconds. **Removed · N** at the end of the list
  keeps everything you removed, each with **Put Back** (`library.restore`; `library.list` returns `removed`). A
  removed visual can come back now.

**Checked (third pass).**
- **Engine tests:** 22 in `library.test.ts`. They add the review's cases: Locate… then re-reading and a restart;
  two HTMLs of the same size; `.cache/metadata.json`; `noteRequest` returning no request for an agent with its
  utility off; Put Back and the removed list; a saved visual linked, a later handover of its file, and the file
  deleted.
- **In a copy of the app:** two-line rows with notes, a CSV's rows and a Markdown heading in tiles and the
  preview, and Add File….

**Still not checked by hand:** dragging pins, Add/Show in Library from each place, Save… from a card, a visual's
buttons from the Library, Undo and Put Back, refreshing after a move in Finder, dark mode. That's the review's
proposed task: find last week's rate comparison and open the exact conversation that made it.

**Fourth pass (2026-11-22): where an item lives.** The row's place column showed the conversation's title, often
the start of a prompt ("Mañana tengo e…"). It now says only where the item lives, in the sidebar's words and
icons: a folder and the project's name, the agent's tile and name, "Conversation" for a chat without a project, or
"Added by you". A click shows only that place (the same as the place menu). The exact conversation is in the
tooltip ("Made in “…”"), the preview's Made in, and Open the Conversation. The user chose this from three options;
the others were the place on the note line, and grouping by place, which stays a possible later Day / Place switch.
As the window narrows, the name keeps about 260 pt: the place gives way first (to its icon alone below 80 pt,
with the place in the tooltip), then the "in a conversation" badge. The time keeps 52 pt, and the hover actions
float over the end of the row instead of holding a column of their own. The search field shrinks too.

## 14. L2: decisions after the review (2026-11-22)

A design review of L2–L4 found that the riskiest failure is an app that looks current while showing old or wrong
data. These decisions replace §2's Keep flow and refine §3 for L2. L3 (the conversation panel) and L4 (tools,
scripts, Piopio's numbers, timers) are unchanged and come later.

**Making an app**
- **`make_app`** is a tool in chats and Build sessions. It takes a title, the page's HTML (which draws from
  `piopio.onData`), and the sources: `{ name: { file, columns? } }`.
- **From a visual:** the card's header has **Make app** (it replaces Keep; AL6). It sends "Make the “*title*” visual
  into an app" as your message, and the model calls `make_app`. You can also ask for an app directly.
- **Nothing is written until you allow it.** The approval card names the exact files the app will read and where
  it will be saved. Allowing it is what allows those sources (§3.4). After it, the app is in the Library, kind App.

**Where the data comes from**
- **The model names the files**, and the engine checks that each one exists and can be read: CSV, TSV, JSON,
  Markdown or text, at most 2 MB.
- **Figures that only exist in the conversation** get written to a CSV first. The tool's description says so; the
  engine refuses a source that isn't a file.
- **One base for paths:** the engine writes the manifest itself, with each path relative to the app's own file.
  The model gives paths as it knows them (relative to its folder, or absolute). Absolute paths are kept, so a file in
  a synced Drive or OneDrive folder (`~/Library/CloudStorage/`) works.
- **Chat folders are temporary** (deleting a chat deletes its folder). A source in a chat's own folder is copied
  beside the app, and the app reads the copy. The approval card says so.

**Where an app is saved**
- In a project: `<project>/apps/<name>.html`.
- Elsewhere: `~/Piopio/Apps/<name>/<name>.html`, with any copied data in the same folder.

**When the data is wrong**
- **Checks in the engine, not the page.** A CSV source can list the `columns` it needs. A missing column, an empty
  file, a file that's gone or can't be parsed makes that source fail.
- **A failed source keeps its last good data**, and the page gets `stale: ["expenses"]`.
- **The app page's toolbar says it**, in Piopio's own UI rather than the page's: "expenses.csv has no “amount”
  column · showing 10:42's data".
- **Values:** a CSV row is an object by column. Plain numbers (`12.5`, `-3`) become numbers; anything else stays
  text.

**What the file is**
- **Opened anywhere else,** the file shows "Open in Piopio to see live data". The cache lives in the engine's
  folder, not in the page. A dated snapshot to share is later.
- **Pinning is only for finding it.** L2 has no timer; L4 keeps Pin and Refresh in the background as two settings.

**Protocol (L2)**

| Method / event | Does |
|---|---|
| `apps.open { path }` | The manifest, the page's HTML, each source's data and status, and whether the sources are allowed; watches its files while open |
| `apps.refresh { path }` | Reads every source now |
| `apps.close { path }` | Stops watching |
| `apps.allow { path }` | Allows the sources the manifest lists now |
| `apps.data` (event) | New data and status for an open app, after one of its files changed |

**L2 is done when:**
1. A chart of a CSV becomes an app that redraws when the CSV changes, with no model turn.
2. A row in a new category that crosses the budget changes every figure the app shows (checked by hand on a real
   model's app).
3. An empty file and a renamed column fail with the last good data kept and dated.
4. An app made in a chat still opens from the Library after the chat is deleted.

### L2 as built (2026-11-22)

**Engine**
- `apps.ts`: the manifest (checked, and written by the engine), reading and checking sources, the cache
  (`apps-cache/`), what's allowed (`apps.json`), and watching an open app's page and source folders.
- `tools/apps-tool.ts`: `make_app`, in chats, Build sessions and conversations on a coding agent. It asks through
  each one's approval card, and writes nothing before Allow.
- **The Library** lists the app from the tool's result as kind App: an `.html` with a manifest is an app.
- **The protocol** methods are `apps.*` rather than `app.*`, because `app.tool` is already the engine asking the Mac
  app.

**App**
- **Make app** in a visual card's header, in chats and Build. Agents don't have `make_app`, so their cards don't
  show it.
- **The app opens in a large sheet** wherever a file opens: the Library, a pin, the app's card in the conversation.
  The toolbar has the title, "Updated 10:42" (or "Data from 10:42" when a source failed), Refresh, Sources and
  Show in Finder.
- **Notices above the page**, in ink as the design system's warnings are: a source that failed, with what's shown
  and since when; sources waiting for Allow.
- **`piopio.onData`** is in every visual's bridge. A page opened outside Piopio gets a stand-in that says to open it
  in Piopio.
- `PIOPIO_DEMO_APP=<path>` for captures.

**Different from §14:**
- **A sheet, not a page with a conversation panel.** L3 made it a page (§15).
- **An app's buttons sent nothing.** Since L3 they fill in its conversation's box.

**Checked**
- **Engine tests:** `apps.test.ts` (14) covers tables, making in a project and from a chat, refusals, a new
  category, an empty file, a renamed column, a gone file, the watch, Allow and a restart. An `engine.test.ts` case
  covers a scripted chat that writes a CSV and calls `make_app`: the card's text, nothing written before Allow, the
  Library's App item, and opening the app after the chat was deleted. The whole engine suite passes (323), and so do
  the Swift tests.
- **In a copy of the app, with a chart of a CSV:**
  - **A new row:** "Car, 450 €" in November changed every figure: the total (1.032 → 1.482 €), the categories
    (3 → 4), the months over budget (1 → 2 of 3), the chart and the latest rows.
  - **A renamed column** ("amount" → "importe") showed the notice and kept the last good data.
  - **A scripted chat** showed Make app on its visual and waited on `make_app`'s card.

**Not checked:** a real model making an app from a visual; the app redrawing while open as a file is saved, by
hand (the engine's watch is tested); Allow after a page edit adds a source, by hand; dark mode.

## 15. L3: changing an app by talking about it (2026-11-22)

**What you see**
- **An app opens as a page** wherever it's opened from: the Library, a pin, its card in a conversation, or its
  conversation in the sidebar. The app fills the content card. On the right is a 360 pt panel, **Ask or change**,
  that's open the first time and then stays as you left it (AL11). The toolbar's ◧ shows or hides it.
- **The conversation is made when you first write** in the panel, so opening an app leaves nothing behind. It's a
  chat titled "*App* (app)", listed with your conversations, and it opens the app.
- **Its place:** in a project, the project's folder, so it can read the project's data. Otherwise the app's own
  folder, where a copied source sits too. A chat may only edit files in its place.
- **A button in an app** (`piopio.send` or `piopio.prefill`) puts its words in the panel's box, for you to send.

**A question isn't a change** (the review's point 5). Each turn, the conversation is told:
- which page the app is, and what it reads;
- that a question gets an answer, and the app doesn't change;
- that a change you ask for is an edit to the page, keeping its sources unless you ask for new ones;
- that when it's unsure which you meant, it answers and offers the change in one line;
- that a change to how the app looks doesn't need the data, so it doesn't read the data for it.

Data reaches a model only when the answer needs it, as an ordinary file read that says which file.

**Undo is the page's, not the folder's** (the review's point 6)
- **Each change is a revision of the page.** The engine keeps up to 30, with the page before and after, in
  `apps-history/`. One request that edits the page several times is one revision, labelled with the request's first
  line.
- **Undo** (in the toolbar, with that label in its tooltip) puts back the page before the latest change the
  conversation made. Data files aren't touched, so a purchase added since stays.
- **Changes made outside Piopio** (your editor) are revisions too, but they aren't Undo's. If the page changed
  outside after the change you're undoing, Undo says so and asks before overwriting: "spending.html changed outside
  Piopio after “Green bars”. Undo would lose that change too." with **Undo Anyway** and Cancel.
- **A change that breaks the page:** its script errors show above it, with Undo.
- **A change that adds a source** keeps drawing with the data read before, and asks for Allow (§3.4).

**Protocol:** `apps.conversation { path }` (made the first time) and `apps.undo { path, force? }` (CONFLICT when it
would overwrite an outside change). An app's view also carries `undo` (the label and when) and `conversation`.
A session summary carries `app`.

**Checked**
- **Engine tests:** `apps.test.ts` has 18 tests, 4 of them new:
  - one request's edits make one revision, and Undo keeps the new data;
  - Undo goes back one request at a time;
  - an outside edit blocks Undo until it's forced;
  - what the conversation is told.

  An `engine.test.ts` case covers one conversation per app, its title and app, an edit through the chat's tools in
  the app's folder, the label, and Undo. The whole engine suite passes (328), and so do the Swift tests.
- **In a copy of the app:** opening an app showed the page with the panel. A message in the panel ("Lower the
  budget to 1.000 €", with a scripted edit) changed the page, which reloaded by itself ("Over budget" went from 1 to
  3 of 3), and Undo appeared.

**Not checked:** a real model telling questions from changes; Undo, Undo Anyway and a broken page's notice clicked
by hand; an app in a project with a real project chat; dark mode.
