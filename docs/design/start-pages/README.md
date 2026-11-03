# Start pages

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

## Checked

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
