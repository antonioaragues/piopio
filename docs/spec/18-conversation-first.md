# 18 · Conversation first: one way to start, projects are folders

Status: decided 2026-11-07; **phases 1–3 built 2026-11-07** (§10–§12); **CF4 revised 2026-11-08: a project is always a folder** (§13). The location chip waits for cloud agents (CF7). It changes the start (X10), the Chat lens (C2), notebooks
(C3, CQ1, CQ2, AQ13) and areas (15). Those docs stay as history and point here.

**The idea:** you always start the same way, by writing. Where the conversation lives is a chip in the composer, not
a choice you make before you can type: no project, or a project. A project is always a folder on the Mac; New project
makes one in ~/Piopio. Agents keep their own section. Notebooks stop being their own kind: a notebook is a project.

## 1. Why

- **Five kinds of things to choose from before writing:** chat, Build session, chat in a folder (the Chat lens),
  notebook and agent. Each had its own start page (X10), its own rules and, inside, a different runtime.
- **Three entry points overlap:**
  - Home's Ask box, with `@project` and `@agent` targets;
  - the Chat start page, with project and notebook chips;
  - each project's "new session" page.
- **The same verb did different things:**
  - "Send to a project" on Home opened another composer, while chat and agent sent at once (the 2026-11-06 audit,
    F12).
  - A chat in a folder was a Build session with a hidden profile.
- **Notebooks cost the most for what they give:**
  - a Main conversation and an organizer that files your messages: a concept to learn, and the most fragile part;
  - their own memory (a markdown document inside pi-durable), apart from agents' and About me's (audit F09);
  - every topic inside one pi-durable session, so topics are hard to move or treat like other conversations.
- **The reference:** Google's Antigravity (2026-11) starts every conversation the same way. The composer has a
  project picker (Recent, This Computer, Remote, New Project, No Project) and a location toggle (This Computer /
  Remote). That location toggle is already our principle 6: "a session's location is an attribute, not a separate
  product".

## 2. Decisions

| ID | Decision |
|---|---|
| CF1 | **One start: "New conversation".** Home is that page: a greeting and the composer, with Needs you, Coming up and Recent below. It replaces the Chat, Project and Notebook start pages and the project "new session" page. The Agent start page stays. *(Since §14, 2026-11-08, and CF9: New opens a centered New conversation page in the main window, not Home; Home keeps its box.)* |
| CF2 | **The project is a chip in the composer:** No project, or a project (a folder). *(Since CF11, §16, 2026-11-15: a selector in the box's bottom row, not a chip on top.)* |
| CF3 | **Permissions are a chip too**, in conversations with a folder: Read only, Ask, Auto-edit, Full auto, plus Plan. **Read only replaces the Chat lens**, and it's the default for folders of documents. Before you press Return, the composer says where the message goes and whether Piopio may change files. |
| CF4 | **A notebook is a project, and a project is always a folder** (revised 2026-11-08, §13). New project makes a folder in ~/Piopio. Its instructions are AGENTS.md, its shared memory is NOTES.md, its files are the folder's files: plain files you can open in Finder, that pi reads as it always does. The Notebook kind, Main and the organizer's routing go away. Phase 2 first built projects *without* a folder (§11); two kinds under one word confused more than they helped. |
| CF5 | **Moving is manual first.** You start where you are and take the conversation to a project later with "Continue in": a new conversation in the project's folder, with this one's history (§5). Automatic suggestions ("This looks like Kitchen renovation") wait until a week of use shows conversations left loose by forgetting. Nothing files your messages without asking. |
| CF6 | **Agents keep their own section and start page.** Later, a conversation can also become an agent ("Turn into an agent"). |
| CF7 | **Location is a chip once the cloud exists** (This Mac / Cloud). Until then it isn't shown. |
| CF8 | **No migration of notebooks:** there's no real notebook data (2026-11-07). Existing notebook folders stay on disk but stop showing once phase 2 lands. |

## 3. The model

| Thing | What it is | Runtime (unchanged; never shown) |
|---|---|---|
| **Conversation, no project** | Today's chat | pi-coding-agent in a folder of its own (since 2026-11-15, §15); a pi-durable thread before |
| **Conversation in a project** | Today's Build session; Read only is today's Chat lens | pi-coding-agent |
| **Project** | A folder and its conversations: instructions in AGENTS.md, shared notes in NOTES.md, its files | — |
| **Agent** | A conversation that lives on its own: identity, contacts, schedules, channels, memory | pi-durable agent |

A project, whether you opened the folder or New project made it:

| | |
|---|---|
| Instructions | AGENTS.md / CLAUDE.md, as pi reads them. New project writes AGENTS.md from what you type. |
| Files | The folder |
| Memory | NOTES.md, when the folder has one: every turn reads it, and the model adds what later conversations need (§13) |
| Edits, terminal, git, worktrees | As permissions allow. New project's folders start in Auto-edit (so the notes can be kept); folders of documents you open start in Read only. |
| Its conversations | pi-coding-agent sessions |

Glossary changes (01-product §4):
- **Thread → Conversation** in the app. The protocol keeps `kind: "thread"`.
- **Space, Topic, Organizer, Lens** leave the app. `kind: "space"` stays readable in code until phase 2 removes the
  runtime.

## 4. The start (phase 1)

```
             Good morning, Antonio
┌──────────────────────────────────────────────────────────┐
│ No project ▾                                              │
│ Ask anything, @ to mention, / for commands                │
│ +   Claude Opus 5.5 ▾                                  ↑  │
└──────────────────────────────────────────────────────────┘
  Needs you · Coming up · Recent
```

With a folder chosen, the permissions chip appears and the line under the box says what that means:

```
┌──────────────────────────────────────────────────────────┐
│ ▣ piopio ▾                                                │
│ Fix the failing test in the policy package                │
│ +   Claude Opus 5.5 ▾                     Auto-edit ▾  ↑  │
└──────────────────────────────────────────────────────────┘
  In piopio · can edit files; asks before commands
```

**The rule for phase 1:** before pressing Return you can see where the message goes (the project chip) and whether
Piopio may change anything (the permissions chip and the line under the box). With no project there's no chip and no
line: a conversation without a folder can't touch your files.

> **Since CF11 (§16, 2026-11-15):** the project is a selector in the box's bottom row, not a chip on top, and with no
> project the line under the box says so: "Not in a project · it can't see or change your files". On the New
> conversation page the line is in the permissions' tooltip (CF26).

**Project ▾**, a popover with search:
- **Recent:** the last projects you used, with and without folders.
- **Folders on this Mac ›:** the recent-folders list the project start page had (git repos in the usual folders,
  folders the pi CLI used).
- **Open folder… ⌘O** and **New project…:** a name, and optionally a folder. Phase 1 creates folder projects only;
  phase 2 adds folder-less ones.
- **No project ✓.**

> **Since §13 (2026-11-08, CF4 revised):** a project is always a folder, so there are no projects without one. New
> project makes a folder in ~/Piopio.

**Permissions ▾**, shown only with a folder.
- **The default is the project's own**, `ProjectInfo.approvalMode`, which gains `read_only`. The chip can change it
  for new conversations in that project ("Use … for new conversations here", as `EditModeChip` does today).
- **New folders:** a folder without code markers (`detectLens` today: no package.json, .git, Cargo.toml…) starts
  in **Read only**; a code repository starts in Auto-edit, as now.
- **Existing projects (migration):**
  - Lenses `["chat"]` only: `read_only`.
  - `["build"]` or both: they keep their mode.
  - Then `lenses` is no longer read. No folder of documents silently becomes editable.

| Mode | Reads, search, web | Edits | Commands |
|---|---|---|---|
| **Read only** | yes | no | no |
| Ask | yes | ask | ask |
| Auto-edit | yes | yes | ask unless a rule allows |
| Full auto | yes | yes | yes (the deny-list still asks) |
| Plan | yes | after you approve the plan | after you approve the plan |

> **05 §6 and 22 §14:** in Ask the web tools ask. They count as network tools, which run in Read only and Auto-edit
> and ask in Ask. The Ask row's "yes" holds for reads and search.

Read only differs from today's Chat lens:
- **It can't write files.** The lens could when asked; choose Ask for that.
- **What it keeps from the lens:** the knowledge-assistant prompt and the web tools.
- **It covers more than files.** Connected apps and MCP tools ask before every change:
  - connectors already know which of their tools read and which write;
  - MCP tools are trusted only when the server marks them `readOnlyHint`.

  So "Read only" holds for your calendar and your MCP servers too (audit F15).

**The rest of the composer:**
- **Model, `+` and Debate don't change.** `+` is files, folder, commands, web search, extensions. Debate is `/debate`
  or a `+` item, with no project.
  > **Since 16 (2026-11-15):** Debate was removed; its code is gone.
- **`@`** mentions files in a project, and agents: `@agent` sends the message to that agent, as Home does today.
- **Return sends.** Nothing exists until then; the draft is kept as start drafts are today
  (`<home>/drafts/start.json`).

**Other ways in,** each to a centered start page with this same box (§14), not to Home:
- **⌘N, "New conversation" and the sidebar's `+`:** no project.
- **A project row's `+`:** that project preselected.
- **⌘O:** opens a folder and preselects it.
- **Quick Chat doesn't change:** it starts a conversation with no project.

## 5. After the start

- **Permissions change anytime.**
  - Between Ask, Auto-edit, Full auto and Plan: as today.
  - Into or out of Read only: the engine reopens the session with the other tool set, same history (pi session file).
    A note in the transcript says so.
- **Taking a conversation somewhere else:** manual, from the conversation's folder button or its sidebar menu (CF5):
  - **Continue in <project>** (phase 1): a new conversation in that folder, because folder
    conversations run on the other runtime. The original stays where it was, and ends with "Continued in …",
    linking to the new one.
    - **What arrives:** the active branch only. User and assistant text, and one line per tool call (tool and
      result status). Thinking and other branches stay behind.
    - **Attachments:** images go along; other attached files arrive as their names, since the folder already holds
      the files that matter there.
    - **How it looks:** the new conversation opens with a folded "Continued from <title>" block holding that history,
      and the model reads it as context. Nothing is sent until you write.
  - **Out of a folder project:** not offered. Copy the text, or export.
- **Suggestions (later, CF5):**
  - S11's code (after the first and fifth exchange, above 0.75 confidence) can be aimed at projects.
  - It's turned on only if, after the week of use, conversations stay loose because people forget to move them.
  - Until then, S11's notebook suggestion is off: it targets notebooks, which phase 2 removes.

## 6. The sidebar

> **Since §13 (2026-11-08), §19 (2026-11-16) and 21 §8 (2026-11-18):** three things below are history.
> - A project is always a folder (CF4 revised), so there is no "(no folder)" row and no icon for it.
> - Clicking a project's row folds or unfolds its conversations (CF20), and there is no project page (CF21); its
>   settings are a sheet (CF22).
> - The Needs you row is gone, and so is its page: Home's "Waiting on you" lists everything (21 §8).

```
+ New conversation        ⌘N
Search                    ⌘K
Needs you            3
─────────
Pinned
Agents                    +
Projects                  +
  ▸ piopio            (folder)
  ▸ Kitchen renovation  (no folder)
Conversations             +
```

- **Notebooks and Chats become Projects and Conversations.** Conversations are the ones with no project.
- **Projects:**
  - Each project folds open to its conversations, as projects do today.
  - Its icon says whether it has a folder.
  - Clicking its name opens the project page: instructions, files, memory and every conversation, with the Summary
    column. For folder projects, also git.
- **Agents stay a section** (CF6), with their own start page.

## 7. What goes away

| Goes away | Replaced by |
|---|---|
| Chat, Project and Notebook start pages; the "new session" page | Home's composer (CF1) |
| Lenses (`ProjectInfo.lenses`, "Use as: Code / Documents") | The permissions chip; Read only as the default for documents (CF3) |
| Notebook kind, Main, the organizer, routing cards, topic merge, the Thread → Notebook suggestion | Projects without a folder; moving by hand (CF4, CF5) |
| Notebook memory (markdown in pi-durable) | The project's memory bank (built-in provider) |
| The Ask box's targets on Home | The project chip and `@agent` |
| Areas: the Chat switch (15) | Conversations are always on. Build and Agents stay as switches: Build off hides folder projects' code tools (terminal, git, edit modes); folders can still be read in Read only |

> **Since §13 and §14 (2026-11-08):** a project is always a folder, so a notebook's place is a folder New
> project makes, with NOTES.md as its memory, not a project without a folder or a memory bank. New opens a centered
> New conversation page, not Home's composer (§14, CF9).

## 8. Phases

### Phase 1: one start, with chips
Engine:
- **Read only:**
  - `ProjectInfo.approvalMode` gains `read_only`.
  - New folders get it when they have no code markers.
  - Existing chat-only projects are migrated to it (§4).
  - The chat profile also removes `edit` and `write`.
  - In Read only, connector writes and MCP tools without `readOnlyHint` ask.
- **Switching an open Build session:** `sessions.configure({ profile })` reopens it with the other tool set.
- **Continue in a folder:** `sessions.continueIn({ ref, projectId })` creates a Build session whose first context is
  the original's active branch (§5), and links the two.
- **The suggestion:** S11's Thread → Notebook suggestion is off by default.

App:
- **Home becomes the start page:** the project chip, the permissions chip and the line under the box, `@agent`,
  drafts.
- **Pages:** remove the Chat, Project and new-session pages, and their routes and menu items. ⌘N and ⌘O go to Home
  (§4).
- **Continue in…:** the project chip on an open conversation with no project offers it.
- **Sidebar:** "Chats" becomes "Conversations". Folder conversations in Read only are listed under their project
  like other sessions.
- **Settings:** remove the lens switches and the areas switch for Chat.

Acceptance, the test of the whole simplification:
- **From Home, with one Return each:** ask a question, look something up in a folder, and ask for a change.
  - Before pressing Return, each time, you can tell where the message goes and whether Piopio may change files.
- **Other ways in:** a project's `+` and ⌘O open the start page with the project chosen (§14).
- **Defaults and switching:**
  - A folder of documents starts in Read only.
  - Switching Read only ↔ Auto-edit in a running conversation keeps its history.
- **Continue in:** a chat that turns out to be about a repo continues there with its text and images.
- **Then a week of daily use** (status.md, Build and Chat rows). Note how often conversations stay loose: that
  decides the suggestions.

### Phase 2: projects without a folder; notebooks go

> **Since §13 (2026-11-08):** projects without a folder were replaced by folders New project makes, so the project
> parts of this phase are history (as §11's note says). The notebook removal stands.

Engine:
- Projects without a path: an id, name, instructions, a files folder in Piopio's data, and a memory bank
  `project:<id>`.
- Threads take a `projectId`. Their system section gets the project's instructions and memory recall (as agents
  get theirs), plus the files tools (`space-files.ts` reused).
- Remove the Space runtime, its protocol methods and the notebook memory.

App:
- The project chip offers folder-less projects and "New project" without a folder.
- The project page for both kinds.
- Remove the Notebooks section and pages.

Acceptance:
- Make a "Kitchen renovation" project, add two files and instructions, and start three conversations.
- Each one knows the instructions, can read the files, and remembers what another one saved.
- "Move to Kitchen renovation" on a no-project chat keeps its whole history, branches and attachments.

### Phase 3: from conversation to agent
- **Turn into an agent:** "Turn into an agent" on a conversation opens the Agent start page with a draft: the name,
  the instructions taken from the conversation, and a schedule if it said one ("every morning").
- **Location:** the location chip, once cloud agents work (13-cloud-engine).

## 9. Open questions

1. **Memory for folder projects:** answered by CF4's revision (§13): NOTES.md, a plain file in the folder.
2. **Debate inside a project:** today debates take no folder or attachments. It stays that way for now.
   > **Since 16 (2026-11-15):** Debate was removed, so this question is closed.
3. **Agents in projects:** should an agent belong to a project and share its memory? Not now.

## 10. Phase 1 as built (2026-11-07)

**Engine:**
- `read_only` is a fourth approval mode. A Build session's profile follows it:
  - Read only drops `bash`, `edit` and `write`, and adds the finders.
  - The web tools (`web_search`, `web_fetch`) and their prompt section are on in every mode, as the table above says
    (until 2026-11-17 only Read only had them, so other modes reached the web through the browser).
  - It switches live with `setActiveToolsByName`, so the transcript and subscriptions stay.
  - The knowledge prompt is added only while Read only.
- **The policy in Read only:**
  - These run: reads, web, todos, plans, subagents, and connectors' read capabilities.
  - Anything else asks, with a tool rule to allow it.
- **Projects:**
  - New folders without code markers start in Read only.
  - Projects saved with only the Chat lens migrate to it, and `lenses` is dropped from `projects.json`.
- **Sessions:**
  - Chat-profile sessions load as Read only.
  - `sessions.continueIn` seeds a new Build session with a `piopio.continued` custom message (text and images),
    shown as "Continued from “…” · N messages".
- **S11's notebook suggestion is off by default.**

**App:**
- **Home's box is the start:** a target menu (No project, Projects, Folders on this Mac, Open folder…, Work on, Message
  an agent), the permissions chip, and the line under the box.
- **Routes:**
  - The Chat and Project start pages and the new-session page are gone.
  - Their routes, ⌘N, ⌘O and a project's `+` land on Home.
  - The Debate page stays, as before.
    > **Since 16 (2026-11-15):** Debate was removed; the page and its code are gone.
- **Conversations:**
  - A conversation with no project has "Continue in a project" (its folder icon) and a "Continued in …" bar.
  - The composer's mode chip has Read only.
- **Areas:** the Chat area is always on, and its switch is gone.
- **Sidebar:** "Chats" is "Conversations".

**Different from §4–§8, for now:**
- ~~The project chip is a menu, not a popover with search.~~ It became a popover with search in phase 3 (§12).
- **⌘N always opens Home with no project.** It used to follow the selected project. A project's `+` and
  "New Conversation…" in its menu still preselect it.
  > **Since §14 (2026-11-08) and CF9:** ⌘N opens the New conversation page with no project, not Home. A project's `+`
  > and ⌘O open the same page with the project chosen.
- ~~Plan isn't in Home's permissions chip.~~ Added in phase 3 (§12).
- **MCP tools in Build sessions ask in Read only.** They're reached through codemode, so `readOnlyHint` isn't seen
  there yet.
- **With Build off,** Home starts folder conversations in Read only, and (since phase 3) the conversation's chip greys
  every mode but Read only.
- **Checked in the app (2026-11-07,** scratch data, scripted model, driven by computer use**):**
  - From Home, with one Return each: a question in a documents folder, a change in a code folder, and a question
    with no project.
  - Before Return, each showed where it goes and what it may do: "Read only · reads files and the web; can't change
    anything", "Auto-edit · can edit files; asks before commands", and nothing with no project.
  - A project's `+` and File › New Conversation land on Home with the right choice.
  - "Continue in" (triggered through the engine; background control can't open menus) showed "Continued in … · Open"
    on the chat, and "Continued from … · 2 messages" in the new conversation.
  - Fixed after the check: the project `+` label said "New session", and an old "New session · Draft" sidebar row
    could linger.
  - Not clicked: the menus themselves (target, permissions, mode chip). The engine tests cover switching Read only
    live.
- **Home goes back to No project after each send** (decided 2026-11-07). A loose question never lands in the last
  project; a project's `+` or ⌘O preselect it again.

## 11. Phase 2 as built (2026-11-07)

> **Superseded on 2026-11-08 (§13):** projects without a folder were replaced by folders New project makes. What
> follows about them (their files in Piopio's data, `projects.addFile`, `sessions.setProject`, the project page, the
> `piopio-project` extension and its bank) is history. The notebook removal stands.

**Engine:**
- **Projects without a folder:** `projects.create` makes one, with a name and instructions.
  - Its files live in `<home>/projects/<id>/files`, which is also its `path`, so the folder APIs list and show them.
  - `projects.addFile` and `projects.removeFile` add and remove files; PDFs keep the text the app extracted.
  - `projects.configure` renames it and sets its instructions.
- **Its conversations:** threads with a `projectId`. The `piopio-project` extension is on only while the thread is in
  a project, so the tools follow a move on the next turn. It gives them:
  - a section with the instructions, the file list and the project's facts (up to about 1,500 tokens);
  - `read_project_file`;
  - `remember_in_project`, which writes to the bank `project:<id>` in the built-in memory.
- **Moving:** `sessions.setProject` moves a conversation in or out; same thread, same history.
- **Removing a project:** its conversations stay, with no project; its files and memory bank are deleted.
- **Settings › Memory** lists each project's bank under its name.
- **Notebooks removed:**
  - The Space runtime, the organizer, routing, notebook memory, `spaces.*`, `threads.dismissSuggestion`, the
    Thread → Notebook suggestion, `transfer.ts` and `scripts/routing-replay.mjs` are gone.
  - The catalog skips `space` entries; their files stay in `spaces/` on disk (CF8).
  - `ContainerKind` keeps `space` only to read old refs.

**App:**
- **Home:** the target menu lists both kinds of project, plus "New project…". A project without a folder has no
  permissions chip; its line reads "reads its files and shares what it remembers…". `@Kitchen renovation`
  (names with spaces) works too.
- **New project (⇧⌘N, the Projects `+`, the palette):** a sheet with a name and instructions, or "Use a Folder
  Instead…".
- **The project page:**
  - Clicking a project without a folder in the sidebar opens it.
  - It holds the instructions (saved on demand), the files (add, open, remove), what it remembers (add, forget) and
    its conversations.
  - Rename and Remove are in its menu.
- **Sidebar:** projects without a folder use a tray icon and nest their conversations; "Conversations" lists the
  ones with no project. The Notebooks section, pages and menu items are gone.
- **A conversation's folder button:** "Move to a project" (with No Project and New Project…) and "Continue in a
  folder". Its header names the project.

**Checked in the app (scratch data, scripted model):**
- A project with instructions and two files.
- Three conversations started from its page, its `+`, and `@Kitchen renovation` on Home; all three were listed under
  it.
- One saved "The sink moves 40 cm left.", which the page then showed under "What it remembers".
- Another read `budget.md`, checked through the engine.
- A loose chat moved in (through the engine call; background control can't open menus) and kept its history.

**Not done:**
- Searching projects in the target menu.
- Memory for folder projects (§9 Q1).
- Old notebook data is left on disk, unread.

## 12. Phase 3 as built (2026-11-07)

**Turn into an agent (CF6):**
- **Where:** the ··· menu of a conversation (with or without a folder) and of a Build session, and File › Turn
  Conversation into Agent….
- **The draft:** the engine (`sessions.agentDraft`) drafts from the active branch, and the Agent start page opens
  with it filled in. Nothing is created until Create; templates, the schedule menu and the icon still work.
  - **With a background model** (07 §1.3): it writes a short name, the instructions in the second person (with the
    standing details the conversation settled), and a cron when the conversation said when.
  - **Without one:** the user's messages become the instructions, and the name comes from the title, skipping a
    leading schedule phrase.
- **The schedule reader** understands phrases in English and Spanish ("every morning", "weekdays at 7:30", "cada lunes
  a las 9", "todas las noches", "every hour"…). The model's cron is used only when it's valid; otherwise the user's
  own words decide. The schedule menu shows any cron in words.

**Gaps from phases 1 and 2, closed:**
- **Home's target chip is a popover with search** over projects, folders on this Mac and agents. It also holds Open
  folder…, New project… and Work on; Return picks the first match.
- **Home's permissions chip has Plan.** The conversation then starts in Plan mode, and the line says "plans first;
  changes only after you approve the plan".
- **With Build off,** the conversation's mode chip greys every mode but Read only.
- **`scripts/recovery-smoke.sh` passes:** a conversation in a project without a folder survives backup and restore,
  and search finds it.

**Checked in the app (scratch data, scripted model):**
- Searching "kit" in the target popover and pressing Return chose Kitchen renovation.
- "Every weekday at 7:30, check the weather in Valencia…", then File › Turn Conversation into Agent…, opened the
  Agent start page with the instructions and "Weekdays · 07:30". Create made the agent, with "Weekdays at 7:30".

**Still open:**
- The location chip (CF7) waits for cloud agents.
- In Read only, MCP tools in Build sessions always ask, because `readOnlyHint` isn't visible through codemode.
- Memory for folder projects (§9 Q1).
- Old notebook data stays in `spaces/`, unread.

## 13. Projects are folders (CF4 revised, 2026-11-08)

**Why:** phase 2 gave the word "project" two kinds. One had a folder, Build sessions and AGENTS.md. The other kept its
files in Piopio's data, used threads, had its instructions in a page and its memory in a bank. They behaved
differently, and the same menu said "Move to" for one and "Continue in" for the other. A folder Piopio makes gives the
same things with nothing new to learn: you can see the files in Finder, edit the instructions in any editor, and the
pi CLI works there too.

**Engine:**
- **`projects.create(name, instructions?)`** makes `~/Piopio/<name>` (then `<name> 2`, …; a `/` becomes `-`), with:
  - `AGENTS.md`: a heading and the instructions (or a comment saying what goes there);
  - `NOTES.md`: a heading and a comment.
  It's added as an ordinary project in Auto-edit. A test copy (another `PIOPIO_HOME`) makes them in
  `<home>/Piopio`; `PIOPIO_PROJECTS_DIR` overrides both.
- **NOTES.md in every turn:** Build sessions in a folder with a `NOTES.md` get it in the system prompt (up to about
  1,500 tokens; the rest stays in the file), with the request to add a short line for what later conversations will
  need, when the session can edit files. Any folder can have one.
- **Removed:** `projects.addFile`, `projects.removeFile`, `sessions.setProject`, `sessions.create`'s `projectId`,
  `projects.configure`'s `name` and `instructions`, `ProjectInfo.folder` and `instructions`,
  `SessionSummary.projectId`, the `piopio-project` extension, `ProjectFiles` and the `project` memory area.
- **Migration:** a project without a folder in projects.json becomes a folder in ~/Piopio on the next start. Its files
  move there, its instructions become AGENTS.md, its saved facts are appended to NOTES.md and its bank is wiped.
  Its conversations stay, as conversations with no project. Old threads reopen without the extension; pi-durable skips
  extension names it doesn't know.

**App:**
- **New project** (⇧⌘N, the Projects `+`, Home's target popover, the palette): a name and optional instructions; the
  page says which folder it makes. "Open a folder instead…" adds one you have. Once made, its new conversation page
  opens (§14).
- **Continue in** replaces "Move to a project": the conversation's folder button and its sidebar menu list the
  projects, Open Folder… and New Project…, which makes the folder and continues there.
- **Removed:** the project page, the tray icon, project rows in Settings › Memory, and the folder-less branches on
  Home (its line, its model role) and in the sidebar.
- Old conversations still label `read_project_file` and `remember_in_project` calls.

**Not done:**
- A summary view of NOTES.md in the app; it's a file, opened like any other.
- Agents don't read a project's NOTES.md (§9 Q3).

## 14. Start pages again (2026-11-08)

**Why:** phase 1 sent every `+` to Home. Home is a landing page, with Needs you, Coming up and Recent under the box,
and a `+` that lands there reads as "nothing happened". New project had become a sheet. The `+` buttons open a
centered start page in the main window again, as they did before phase 1.

**App:**
- **New conversation** (⌘N, Conversations' `+`, File › New Conversation, `/new`): the start page with Home's box and no
  project, under "What's on your mind?". Its sidebar row is "New conversation · Draft".
- **A project's `+`** (and its "New Conversation…", ⌘O, Open folder): the same page with that project chosen, its name
  over "New conversation", and the project's row marked in the sidebar. Choosing another target in the box keeps the
  page and what's typed; the sidebar follows.
- **New project** (⇧⌘N, the Projects `+`, the box's popover, the palette, Continue in › New Project…): a start page with
  the name as the title, optional instructions and the folder it makes (§13). Create opens the new project's
  conversation page; from Continue in, the conversation continues in the new folder. Back or Esc returns.
- **Kept:** the box is Home's (`AskBox`), so Plan, permissions, Work on, `@` and the morph into the conversation's
  composer work the same from both. Home keeps its box too.

## 15. One engine for conversations (2026-11-15)

**Why:** a conversation without a project ran on pi-durable and one in a project on pi-coding-agent: two runtimes, two
storage formats and two ways to search and read history, for what the app shows as one thing. T3 Code (pingdotgg/t3code)
runs every thread on the same agent, giving a thread without a project a folder of its own.

**What changed:**
- A chat is a pi SDK session (BuildRuntime with a **chat profile**), its file in `<home>/chats/`, run in
  `<home>/scratch/<id>/`. The app still knows it as a `thread`; the folder isn't shown.
- **Same tools as before:** web search and pages, connected apps, MCP servers on for chats (the others are refused),
  the browser, About me, earlier chats (`@conversation`, as a CHAT chip), skills (pi's own; `read` opens a skill's files
  only) and `/templates` (shown as typed). No file or command tools, no approval modes; a connector change or a browser
  action asks with a card in the transcript, as before.
  > **Since 04 T14 (built 2026-11-20):** a chat writes files in its own folder with `write` and `edit`, which refuse
  > any other path. A chat on a coding agent runs in its own folder in Auto-edit (31 CA4).
- **Files** go in the message itself, tagged, so the session file is all there is; their chips still open the kept copy.
  Folder conversations take files now too.
- **Versions** (edit, retry, ‹ 1 / 2 ›) are pi's session tree.
- **Old chats move once**, when the engine starts (`migrate-chats.ts`): the branch they showed, with their files and
  `/commands`. Other branches and approval cards stay behind in the old SQLite file, which is kept until the chat is
  deleted.
- An MCP server turned off in a chat is refused when called, as in a folder conversation, instead of being hidden.

**Not changed:** agents stay on pi-durable. "Continue in" still makes a new conversation in the project's folder.

## 16. One New, and Agents beside Home (2026-11-15)

> **Since §23 (2026-11-22):** Conversations have their `+` again (CF32).

> **Since §21 (2026-11-20):** your agents are back in the sidebar under an Agents heading with a +, and the compose
> button is a menu of New Conversation and New Agent (CF27–CF29). That replaces CF10 and the "button, not a menu" part
> of CF9; the rest of CF9 stands.

> **Since 26 (2026-11-17):** the team parts of §16–§20 go in 26 C2. The Agents page lists agents only (CF10, no
> Teams tab and no New team); the Board row under a project is the project's, not a team's (CF21); How it works in the
> settings sheet becomes the project's way of working (CF22, 26 §4); and the New conversation page has no team mark
> or "What should **Development team** do?" (CF24). The rest stands.

**Why:** the compose button was a menu of four kinds (conversation, conversation in a project, project, agent), and
every sidebar section had its own `+`. Agents and teams sat between Projects and Conversations, as if they were more of
your work, when they are things you set up once and that then run on their own. The user picked proposal A of three
([docs/design/new-and-agents/proposals.html](../design/new-and-agents/proposals.html)), with two borrowings.

| ID | Decision |
|---|---|
| CF9 | **New always lands on the same page.** The compose button, ⌘N and File › New Conversation open the New conversation page with no project; a project's `+` opens it with that project chosen. The compose button is a button, not a menu. Conversations lose their `+`. Projects keep theirs: it makes a folder. |
| CF10 | **Agents is a place, beside Home.** The sidebar's top is Search, Home and Agents. The Agents and Teams lists leave the sidebar; the Agents row opens one page with **Agents · Teams**, whose one black button is New agent or New team. The row is selected inside an agent or a team, and shows a grey ring while one runs, or the blue dot when one wrote to you. Pinned agents stay in Pinned. |
| CF11 | **The project is a selector in the box's bottom row**, after attach, as plain text with its icon (grey ink, principle 6), not a chip on top. With no project, the line under the box says so: "Not in a project · it can't see or change your files". |
| CF12 | **The project menu shows each project's permissions** ("piopio · Auto-edit"), recent first (from proposal B). |
| CF13 | **Quick picks under the box** on the New conversation page, with no project chosen: "Or in piopio · BioGen · financial_ia", the three latest projects (from proposal C). Home doesn't show them. *(Since CF25, §20, 2026-11-16: the "Or in" line is pills under the box.)* |

**Not now:** the location selector (This Mac / Cloud) waits for the cloud engine (CF7); the mockups draw it greyed.

## 17. Adding a project from the sidebar (2026-11-15)

**Why:** the New project page put a large instructions box first and hid the more common case, a folder you already
have, in a link at the bottom. The user picked proposal A of three
([docs/design/new-project/proposals.html](../design/new-project/proposals.html)).

| ID | Decision |
|---|---|
| CF14 | **The Projects `+` stays, and opens a menu:** New Project (an empty folder in ~/Piopio), Open Folder… (⌘O), and the folders this Mac already has (git repos in the usual places and folders pi worked in, minus existing projects): four in the menu, more under More Folders. A folder opens as a project and lands on its New conversation. |
| CF15 | **New Project is named in place,** like a new folder in Finder: a row at the top of Projects with the name field focused and "Makes ~/Piopio/Name" under it. Return makes the folder (with AGENTS.md and NOTES.md, as before) and opens its New conversation; Esc, or leaving the field empty, cancels and nothing is made. ⇧⌘N, File › New Project…, the palette, the box's popover and Continue in › New Project… all open this row (the sidebar and the Projects section open if they were hidden). From Continue in, the conversation continues in the new folder. |
| CF16 | **Instructions come after.** A project made this way shows, on its New conversation page until its first conversation, "Instructions for every conversation here go in AGENTS.md. Write them", which opens the project's Settings. Who works here (Piopio or a team) is chosen there too, no longer at creation. |

**Kept:** the New project page, only for when the Projects section is hidden (the Projects area off).
**Not built:** "let the first conversation draft them" from the mockup; drafting AGENTS.md from a message needs engine
work.

## 18. The project page, and folders linked to a project (2026-11-15)

**Why:** the project page was three tabs (Conversations · Board · Settings), and a project could only use one folder,
so a project made in ~/Piopio couldn't reach the folders where your things already are. The user picked proposal A of
three ([docs/design/project-page/proposals.html](../design/project-page/proposals.html)) for its discoverability: what
the project is stays visible, not behind a panel.

| ID | Decision |
|---|---|
| CF17 | **The project page is a home, not tabs.** On the left: the name, where it is (path · branch · who · permissions), the box (in this project, with its own target and draft, apart from Home's), a team's board as one line ("Board · 2 doing · 1 in review · Open ›"), and the conversations as a hairline list. On the right, a 300 pt column in the Summary panel's blocks, open by default (a toolbar button hides it): Instructions and Notes (a few lines of AGENTS.md / NOTES.md, with Edit), Folders, and Project (who works here, the permissions new conversations start in, routines). Board and Settings open in place with "‹ Project" to go back; Settings is in the … menu, with Reveal in Finder and Remove from Piopio. *(Since §19, 2026-11-16: replaced. There is no project page (CF21); the project's settings are a sheet (CF22).)* |
| CF18 | **A project can link other folders on the Mac.** Nothing is copied or moved. Each is **Read only** (the default) or **Can edit**. Add them from the column (Add folder…, several at once) or by dropping folders from Finder on the column or on the project's row in the sidebar. A folder that is the project's own, inside it, or holds it can't be linked. |
| CF19 | **What a linked folder does.** Every turn, the model is told the folders and what it may do in each. `@` searches them too (absolute paths). A Can edit folder is written to like the project's own folder: without asking in Auto-edit and Full auto (path rules), writable in the sandbox, and still asking in Ask; Read only can't. Writing to a Read only folder asks, as anywhere outside the project. The line under the box counts them: "In Tesis and 2 linked folders · …". |

**Not built:** adding a folder to a single conversation from the box's `+`. Instructions and notes always stay in the
project's own folder.

## 19. Project settings in a sheet, and no project page (2026-11-16)

**Why:** the user didn't want the project's settings as a column on a page. They live in a sheet, opened from the
project's row; the row itself only folds. Designs: [proposal](../design/project-settings/proposal.html) and
[editing](../design/project-settings/editing.html). Replaces CF17's page; CF18–CF19 (linked folders) are unchanged.

| ID | Decision |
|---|---|
| CF20 | **Clicking a project's row folds or unfolds its conversations.** On hover (and on the project you're in), two buttons replace the branch: **settings** (sliders, not the app's gear) and **+**. A project with nothing under it starts a conversation there instead. Right-click: New Conversation, Project Settings…, Board, Pin, Reveal in Finder, Remove from Piopio. Dropping folders on the row links them and says "Linked <name>" for two seconds; nothing else moves. |
| CF21 | **No project page.** Links to a project (palette, Home, a team's page) open its New conversation page; "Review" on Home opens its board. A team's **Board** is the first row under its project, with "2 doing" and the ring, or the blue dot when a task is blocked. |
| CF22 | **The settings sheet:** Folders (its own and linked ones, Add folder…, drop), Instructions (AGENTS.md, or CLAUDE.md when that's the project's) and Memory (NOTES.md, renamed from Notes), How it works (the permissions new conversations start in, who works here, a team's tasks at once and checks), Routines. Changes apply as they're made; Done closes; Remove from Piopio… asks first. *(Since 27 AU10 and §4, 2026-11-18: in place of Routines, "N automations work here ›" opens the Automations list filtered to the project.)* |
| CF23 | **Instructions and Memory are edited in the sheet or in your editor.** Each row has Edit and an arrow that opens the file in Settings › Open files in (or the default app). Edit widens the sheet to the file: plain markdown in a monospaced font, a line on what the file does, saved half a second after you stop typing and on leaving, Undo all, ⌘O to open it in your editor. Memory shows how much of it each turn reads (~6,000 characters). While it's open the file is watched: with nothing typed it reloads; with your edits pending a bar offers "Use theirs and mine" (the lines the file gained, after yours) or "Keep mine", and "Reload" when the file changed lines rather than adding them. |

**Not built from the design:** bold headings and grey list marks in the editor (it's a plain text view), and the dashed
line where memory stops being read (the footer says it instead). "Who works here" keeps today's two cards rather than
the drawn segmented control.

## 20. The New conversation page: one question, centered (2026-11-16)

**Why:** the page said "New conversation" and a sentence about how projects work, the same for every project. The user
picked proposal A of four ([docs/design/new-conversation/proposals.html](../design/new-conversation/proposals.html)).

| ID | Decision |
|---|---|
| CF24 | **One question in the middle of the window:** a 44 pt mark (folder, team or conversation), then "What's next in **Tesis**?" with the name in grey ("What should **Development team** do?" with a team, "What's on your mind?" with no project), then the box, a little larger, with "Ask, or describe a task…". No kind label, no description. |
| CF25 | **Pills under the box.** In a project: **Pick up** with its two latest conversations, and **Uses** with its linked folders ("2 folders") and **Memory** when NOTES.md exists; those open the project's settings, on Memory for the second. With no project: **Or in** with your three latest projects, which choose that project (replacing the box's "Or in" line from §16, CF13). Hairline capsules, centered, wrapping when they don't fit. |
| CF26 | **The line under the box moves into the permissions' tooltip** on this page ("In Tesis and 2 linked folders · reads files and the web; can't change anything"). Home and project boxes elsewhere keep the line. |

**Fixed along the way:** ⌘N after using a team's page opened the team's version of this page; New conversation now
forgets a chosen team as it already forgot a chosen project.

## 21. Agents in the sidebar, and New is a menu (2026-11-20)

**Why:** with agents behind one row, every visit to an agent took two clicks and a second list column beside the
sidebar, and making one meant finding that column's +. The user asked to hang the agents under Agents in the main
sidebar, with a +, and to put New Agent in the compose button
([mockup](https://claude.ai/artifact/VPZz4p42SpxCd2JD6jj5qM)).

| ID | Decision |
|---|---|
| CF27 | **Agents is a sidebar section,** after Pinned and before Projects: the heading folds it like the others, a **+** opens the New agent page, and each agent is a row with its tile and name, the grey ring while it works, the blue dot when it wrote to you, or "Paused" / "Draft". The five latest show, then "N more ›", which opens the Agents page with all of them. An unfinished New agent page shows as a "Draft" row at the top. Pinned agents stay in Pinned. |
| CF28 | **An agent's page fills the content card.** The agents' list column beside it is gone; so is the Agents row under Home and Automations. |
| CF29 | **The compose button is a menu:** New Conversation (⌘N) and New Agent (⌥⌘N, also in File and the command palette). Both open their start pages. With Agents turned off it stays a plain button. Projects are still made from the Projects +. *(Since CF31, §22, 2026-11-20: New is a round + beside Search, not the pencil, and New Project… joins its menu.)* |
| CF30 | **piopio tries on jobs on the New agent page:** secretary, doctor, detective, chef, mail carrier, coach, one every 2.8 s with a hop and its line in a bubble ("Say ahh… peep!"), and the box's example follows the job. Clicking it moves to the next job. Picking a template dresses it for that template's job (a briefing is the secretary, a watcher the detective); a template or anything typed stops the cycle. |

## 22. New moves beside Search (2026-11-20)

**Why:** the compose button was a small pencil next to the sidebar toggle, easy to miss, and once it became a menu
the pencil no longer said what it does. The user compared three placements and picked a search pill with a round +
beside it (option C2 of the [mockups](https://claude.ai/artifact/Bec6wd9tVE31VgftFmL8Eg)).

| ID | Decision |
|---|---|
| CF31 | **Search and New share the sidebar's first row.** The top bar keeps only the toggle. Search is a pill on the window's field grey ("Search", ⌘K) that opens the search and command box; New is a 32 pt black circle with a +, the sidebar's one black action. Clicking it opens its menu: New Conversation (⌘N), New Agent (⌥⌘N, with Agents on) and New Project… (⇧⌘N, with Chat on), the same as File › New. With neither Agents nor Chat on, it starts a conversation straight away. This replaces CF29's pencil, and New Project joins the menu (the Projects + still makes one too). |

## 23. Conversations get their + back (2026-11-22)

**Why:** with a long sidebar, starting a conversation meant scrolling back up to New. The user asked for a + beside
the Conversations heading, like Agents and Projects have.

| ID | Decision |
|---|---|
| CF32 | **Conversations' heading has a +** that opens the New conversation page with no project, the same as ⌘N and New › New Conversation. This undoes "Conversations lose their `+`" in CF9; the rest of CF9 stands. |
