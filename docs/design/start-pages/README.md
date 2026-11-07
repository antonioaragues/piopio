# Start pages

> **2026-11-07:** [spec 18](../../spec/18-conversation-first.md) replaces the Chat, Project and Notebook pages with
> Home's composer (project and permissions as chips). The Agent page stays.

The + next to Projects, Chats, Agents and Notebooks opens a page in the main window instead of a sheet. First built
on 2026-11-03 (spec decision X10), then redone the same day from a design handoff ("redesign of the + empty states")
so all four follow one layout. `start-pages.html` is the first proposal; `app/` holds captures with the scripted
model in light and dark (none of the project page, which lists real folders on the Mac it runs on).

## Layout (all pages)

One centered column, 720 wide, starting 128pt from the top (112 on Agent and Notebook), 28pt between blocks:

1. **Kind label**: a 24pt tile with the kind's icon in the accent on a soft accent wash, and "New chat" etc.
2. **Title**: 34/700. On Agent and Notebook the title is the name field (no border, placeholder in the same style).
3. **Description**: 15pt, secondary.
4. **Composer card**: card fill, 1pt hairline, radius 16, a soft double shadow. 16pt text with no border; a footer
   with settings on the left and the **main action at the bottom right** (dark, 36pt, radius 10, with its shortcut;
   grey until it can run).
5. **"Start from…" section**: a 13/600 heading and its content.
6. **Hints**: 13pt.

Tokens are the grey-ink ones (`DS`), so dark mode comes with them. The few additions live in `StartStyle`: a soft
accent wash for the kind tile and selected things, the dashed outline, and the debate badges' blue and orange.

## Pages

| Page | Title | In the card | Below |
|---|---|---|---|
| Chat | What's on your mind? | Attach · **Chat \| Debate** · model · send | Projects and notebooks to talk about, and Attach a file |
| Debate (same page) | What should they work out? | A vs B models, swap, "Until they agree · max N rounds" · Start debate ↩ | The maker hint and what a debate costs |
| Project | Open a folder | A drop zone with Choose folder… ⌘O and New empty folder | Recent folders on this Mac, with branch, date and Open |
| Agent | Icon picker + name | What it should do · schedule · "Notifies you in Piopio" · Runs on this Mac · Create ⌘↩ | A 3-column template grid |
| Notebook | Name | First note for Main · Instructions (opens inside the card) · Create with N topics ⌘↩ | Chats to bring in as topics, Select all |

## Behavior

- **Nothing exists until you start.** The draft is kept in `<home>/drafts/start.json`, and the sidebar shows a
  "Draft" row at the top of the section while the page is open or has text.
- **Chat and Debate are one page.** The switch keeps the text. `/debate` in the box switches too. Return sends or
  starts; ⇧↩ adds a line; ⌘↩ submits on every page.
- **Talk about something you already have**: a project chip starts the chat in that folder (it can read the files,
  and it's listed under the project); a notebook chip sends the message to that notebook's Main, where the organizer
  files it. Only one at a time.
- **Debate**: A answers and revises, B critiques (the engine's author and reviewer). Swap exchanges them. Defaults are
  the ones the debate already had: the Chat model, and the last reviewer (or a model from another maker).
- **Agent**: name and instructions are required. A template sets the schedule, and drafts the name, icon and
  instructions unless you wrote your own. The schedule menu offers Every day, Weekdays, Weekends, Mondays or Only when
  you message it, at 07:00, 08:00, 09:00, 12:00, 18:00 or 21:00. The engine takes the instructions and the schedule
  in `agents.create`.
- **Icons, not emoji**: template avatars are `symbol:<SF Symbol>`; the icon picker offers line icons (an emoji can
  still be typed). Older agents keep their emoji.
- **Project**: dropping, choosing or creating a folder opens it as a project (a Build project, or a folder to chat
  about when Build is off). Recent folders are the git repos in the usual code folders and the folders the pi CLI
  worked in, minus the ones that are already projects.

## Different from the handoff

- **Debate copy** says what the engine does (one model answers, the other critiques until they agree) rather than
  "two models answer". The criteria field is gone from the page; put criteria in the question.
- **No "Give both models the same context"** in Debate: debates don't take attachments or folders yet.
- **No Clone from Git** on the project page, and **no Dock tip**: neither exists in the app yet.
- **"Notify me"** is a plain label, "Notifies you in Piopio": in-app (with a Mac notification) is the only channel.
- **Rounds** default to 6 (the debate's existing default), not 4. Template schedules are the templates' own.
- Hints use ↩ (the app's return glyph) rather than ↵.
- **Debates aren't listed** under "Bring in chats as topics": the engine can't move a debate into a notebook
  (docs/spec/16), so every row is a chat.

## New session in a project (addendum, 2026-11-03)

The "New session in <project>" sheet is gone. Starting a session is a page built from the composer alone:

- **Header**: a folder tile with the project's name, and "What should the agent do?". No description.
- **Composer**: "Describe the task…", then attach · **In the folder ▾** · **permissions ▾** · model · the round start
  button (the same as Chat's: grey until there's text). Return or ⌘↩ starts; ⇧↩ adds a line; Esc goes back.
- **Work on**: In the folder, New branch, Worktree. Outside a git repo the last two are disabled, with "Not a git repo"
  in the menu. The branch is named from the task (`git.suggestBranch`), as the sheet did; there's no name field.
- **Permissions**: the three Piopio already has, each with its line in the menu: Ask before edits, Auto-edit, Full
  auto.
- **Defaults** are what the sheet used: the project's own permission mode (Settings › the project; new projects get
  Auto-edit, decision BQ1) and the place it last worked; "In the folder" the first time. Confirmed on 2026-11-04
  (the handoff's "Ask before edits" default was a question to confirm): each project keeps its own mode.
- Starting creates the session, sends the task, and the page moves into the session in place of the draft row.

**Sidebar**: Search, Home and Needs you stay at the top, above Projects, Notebooks, Agents and Chats (the handoff put
them at the bottom; moved back on 2026-11-04 at the user's request). A project row has a + (26pt): always on the open project (grey fill, name in medium weight),
on hover for the others, where it takes the branch's place. VoiceOver gets it as the row's "New session" action. A
folder you only chat about gets a + that starts a chat in it. Sessions nest under their project on a hairline (rows
30pt), with "New session · Draft" at the top while one is being written. Clicking a project row folds or unfolds its
sessions (a chevron after the name marks a folded one; it unfolds by itself when you open one of its sessions); it
no longer opens the Projects page. The handoff's "+ New session ⌘N" row was dropped on 2026-11-04 at the user's
request: the row's + and ⌘N start a session. ⌘N starts a session in the open project, or a chat anywhere else.

**Motion**: on every start page (chat, debate, notebook, agent, session), starting moves the card down into the
conversation's composer (a matched-geometry move, 0.42 s) while the page fades into the conversation, instead of
cutting to it.

## Checked

**Addendum** (throwaway home, its own agents and pi folders): the open project's + and "+ New session" open the
page; the draft row takes the link's place; starting moved into the session, which replaced the draft row; ⌘N from a
session opened a new one there; Esc on an empty page went back and removed the draft row; a chat-only folder shows its
chat +. Screenshots mid-start show the card on its way down. Not clicked: the Work on and permissions menus (menus
can't be opened in the background), and a non-git Build project.

**First version**:

Clicked through in a throwaway home with the scripted model (agent folders in that home too, with
`PIOPIO_AGENTS_DIR`): switching agent templates (name, icon, instructions and schedule follow) and creating an agent
with edited instructions (its `agent.json` has the line icon and the template's schedule, `instructions.md` the text);
creating a notebook with instructions and a first note, and one with two chats as topics; sending from the chat page
to a notebook's Main through its chip; Chat ⇄ Debate keeping the text; starting a debate. That found two bugs, now
fixed: the topic rows didn't respond to accessibility presses (VoiceOver), and a debate in the list made the whole
import fail silently.

Not clicked: opening a folder from the project page (it reuses the existing add-project path, and the recent list
shows real folders), the schedule menu (a menu can't be opened in the background), and a project chip on the chat
page.
