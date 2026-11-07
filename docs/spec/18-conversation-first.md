# 18 · Conversation first: one way to start, projects with or without a folder

Status: decided 2026-11-07, not built. Phases in §8. It changes the start (X10), the Chat lens (C2), notebooks
(C3, CQ1, CQ2, AQ13) and areas (15). Those docs stay as history and point here.

**The idea:** you always start the same way, by writing. Where the conversation lives is a chip in the composer, not
a choice you make before you can type: no project, a project with a folder, or a project without one. Agents keep
their own section. Notebooks stop being their own kind: a notebook is a project without a folder.

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
| CF1 | **One start: "New conversation".** Home is that page: a greeting and the composer, with Needs you, Coming up and Recent below. It replaces the Chat, Project and Notebook start pages and the project "new session" page. The Agent start page stays. |
| CF2 | **The project is a chip in the composer:** No project, a project with a folder, or a project without one. |
| CF3 | **Permissions are a chip too**, in conversations with a folder: Read only, Ask, Auto-edit, Full auto, plus Plan. **Read only replaces the Chat lens.** |
| CF4 | **A notebook is a project without a folder:** shared instructions, memory and files; its conversations are ordinary conversations. The Notebook kind, Main and the organizer's routing go away. |
| CF5 | **Routing becomes a suggestion.** A conversation with no project may get "This looks like Kitchen renovation. Move it there?" (S11's suggestion, aimed at projects). Nothing files your messages without asking. |
| CF6 | **Agents keep their own section and start page.** Later, a conversation can also become an agent ("Turn into an agent"). |
| CF7 | **Location is a chip once the cloud exists** (This Mac / Cloud). Until then it isn't shown. |
| CF8 | **No migration of notebooks:** there's no real notebook data (2026-11-07). Existing notebook folders stay on disk but stop showing once phase 2 lands. |

## 3. The model

| Thing | What it is | Runtime (unchanged; never shown) |
|---|---|---|
| **Conversation, no project** | Today's chat | pi-durable thread |
| **Conversation in a project with a folder** | Today's Build session; Read only is today's Chat lens | pi-coding-agent |
| **Conversation in a project without a folder** | Today's notebook topic, as a plain conversation | pi-durable thread with the project's context |
| **Project** | A group of conversations with shared context: a name, instructions, memory, files, and an optional folder | — |
| **Agent** | A conversation that lives on its own: identity, contacts, schedules, channels, memory | pi-durable agent |

Projects with and without a folder:

| | With a folder | Without a folder |
|---|---|---|
| Instructions | AGENTS.md / CLAUDE.md, as pi reads them | Written in the project page |
| Files | The folder | Files you add (kept in Piopio's data) |
| Memory | Later (§9) | A built-in memory bank per project, the same provider as agents and About me |
| Edits, terminal, git, worktrees | Yes, as permissions allow | No |
| Its conversations | pi-coding-agent sessions | Threads |

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
│ +   Claude Opus 5.5 ▾                  Auto-edit ▾     ↑  │
└──────────────────────────────────────────────────────────┘
  Needs you · Coming up · Recent
```

**Project ▾**, a popover with search:
- **Recent:** the last projects you used, with and without folders.
- **Folders on this Mac ›:** the recent-folders list the project start page had (git repos in the usual folders,
  folders the pi CLI used).
- **Open folder… ⌘O** and **New project…:** a name, and optionally a folder. Phase 1 creates folder projects only;
  phase 2 adds folder-less ones.
- **No project ✓.**

**Permissions ▾**, shown only with a folder. The default is the project's approval mode (today's
`ProjectInfo.approvalMode`), and the chip can change it for new conversations in that project ("Use … for new
conversations here", as `EditModeChip` does today).

| Mode | Reads, search, web | Edits | Commands |
|---|---|---|---|
| **Read only** | yes | no | no |
| Ask | yes | ask | ask |
| Auto-edit | yes | yes | ask unless a rule allows |
| Full auto | yes | yes | yes (the deny-list still asks) |
| Plan | yes | after you approve the plan | after you approve the plan |

Read only differs from today's Chat lens:
- **It can't write files.** The lens could when asked; choose Ask for that.
- **What it keeps from the lens:** the knowledge-assistant prompt and the web tools.

**The rest of the composer:**
- **Model, `+` and Debate don't change.** `+` is files, folder, commands, web search, extensions. Debate is `/debate`
  or a `+` item, with no project.
- **`@`** mentions files in a project, and agents: `@agent` sends the message to that agent, as Home does today.
- **Return sends.** Nothing exists until then; the draft is kept as start drafts are today
  (`<home>/drafts/start.json`).

**Other ways in, all to this page:**
- **⌘N, "New conversation" and the sidebar's `+`:** no project.
- **A project row's `+`:** that project preselected.
- **⌘O:** opens a folder and preselects it.
- **Quick Chat doesn't change:** it starts a conversation with no project.

## 5. After the start

- **Permissions change anytime.**
  - Between Ask, Auto-edit, Full auto and Plan: as today.
  - Into or out of Read only: the engine reopens the session with the other tool set, same history (pi session file).
    A note in the transcript says so.
- **Moving a conversation:**
  - **No project → a project without a folder:** a re-tag; same thread, same runtime (phase 2).
  - **No project → a project with a folder:** a new conversation in that folder that starts with the old one's
    history, copied as `transfer.ts` copies threads today. The old one shows "Continued in …" with a link.
  - **Out of a folder project:** not offered. Copy the text, or export.
- **The suggestion (CF5):** after a no-project conversation's first exchange, and again after its fifth, the
  background model compares it with your projects' names, instructions and recent conversation titles. Above 0.75
  it offers "Move to <project>" or "Not now". It's S11's code and thresholds, aimed at projects; dismissals are
  remembered.

## 6. The sidebar

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
| Lenses (`ProjectInfo.lenses`, "Use as: Code / Documents") | The permissions chip; Read only (CF3) |
| Notebook kind, Main, the organizer, routing cards, topic merge | Projects without a folder; the move suggestion (CF4, CF5) |
| Notebook memory (markdown in pi-durable) | The project's memory bank (built-in provider) |
| The Ask box's targets on Home | The project chip and `@agent` |
| Areas: the Chat switch (15) | Conversations are always on. Build and Agents stay as switches: Build off hides folder projects' code tools (terminal, git, edit modes); folders can still be read in Read only |

## 8. Phases

### Phase 1: one start, with chips
Engine:
- `profile` can change on an open Build session: `sessions.configure({ profile })` reopens it.
- The chat profile removes `edit` and `write` too: Read only.
- Projects keep `lenses` in the file but stop using them.

App:
- Home becomes the start page: the project chip, the permissions chip, `@agent`, drafts.
- Remove the Chat, Project and new-session pages, and their routes and menu items. ⌘N and ⌘O go to Home as in §4.
- Sidebar: "Chats" becomes "Conversations"; folder conversations in Read only are listed under their project like
  other sessions.
- Settings: remove lens switches. The areas switch for Chat goes.

Acceptance:
- From Home you can start a chat, a Read only conversation in a folder, and an Auto-edit one, without opening
  another page.
- A project's `+` and ⌘O land on Home with the project chosen.
- Switching Read only ↔ Auto-edit in a running conversation keeps its history.
- A week of daily use before phase 2 (status.md checklist: Build and Chat rows).

### Phase 2: projects without a folder; notebooks go
Engine:
- Projects without a path: an id, name, instructions, a files folder in Piopio's data, and a memory bank
  `project:<id>`.
- Threads take a `projectId`. Their system section gets the project's instructions and memory recall (as agents
  get theirs), plus the files tools (`space-files.ts` reused).
- The S11 suggestion targets projects.
- Remove the Space runtime, its protocol methods and the notebook memory.

App:
- The project chip offers folder-less projects and "New project" without a folder.
- The project page for both kinds.
- Remove the Notebooks section and pages.

Acceptance:
- Make a "Kitchen renovation" project, add two files and instructions, and start three conversations.
- Each one knows the instructions, can read the files, and remembers what another one saved.
- A no-project chat about kitchens gets the move suggestion, and moving it keeps its history.

### Phase 3: from conversation to agent
- **Turn into an agent:** "Turn into an agent" on a conversation opens the Agent start page with a draft: the name,
  the instructions taken from the conversation, and a schedule if it said one ("every morning").
- **Location:** the location chip, once cloud agents work (13-cloud-engine).

## 9. Open questions

1. **Memory for folder projects:** the same project bank as folder-less ones (recall in Build sessions too), or only
   AGENTS.md? Proposal: later, once phase 2 shows whether project memory is useful.
2. **Debate inside a project:** today debates take no folder or attachments. It stays that way for now.
3. **Agents in projects:** should an agent belong to a project and share its memory? Not now.
