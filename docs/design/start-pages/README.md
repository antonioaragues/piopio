# Start pages

New chat, debate, notebook and agent open a page in the main window instead of a sheet, the way a new conversation
starts in ChatGPT or Claude. Decided on 2026-11-03 (spec decision X10). `start-pages.html` is the proposal with a
clickable mockup; `app/` holds captures of the built pages with the scripted model.

## Behavior

- **Each + opens its own page.** Chats + opens the chat page, Notebooks + the notebook page, Agents + the agent page.
  Projects + still opens the folder picker.
- **Debate lives under Chats.** The chat page has a *Start a debate* link, and the debate page a *Chat instead* link.
  The text moves with you (the message becomes the goal and back). `/debate` in the chat box, ⌥⌘N, the compose menu
  and ⌘K open the debate page too.
- **Nothing exists until you start.** Sending, Start or Create makes the item and opens it. ⌘N no longer creates an
  empty chat.
- **Names are required** for notebooks and agents: Create stays off until there is one.
- **Drafts survive.** What you type is saved in `<home>/drafts/start.json`. While a page is open or has something
  typed, a grey row with "Draft" sits at the top of its section (named with what you typed). Its context menu has
  Discard Draft.
- **Errors stay on the page**, under the box, and say that nothing was created and what you typed is kept.
- **Creating is a page, editing is a sheet.** Notebook settings, commit, restore and traces stay sheets.

## Pages

| Page | Heading | In the box | Below |
|---|---|---|---|
| Chat | What's on your mind? | Message, attach, model, send | Start a debate; the Quick Chat tip |
| Debate | What should they work on? | Goal; "A good result must…"; Start ⌘↩ | *Model writes · Model reviews · up to N rounds*, the estimate, the maker hint, Chat instead |
| Notebook | The name, typed in place | First note for Main (optional); Create ⌘↩ | Instructions (folded), chats to bring in as topics |
| Agent | Avatar and name | First message (optional); Create ⌘↩ | Templates as rows, From scratch |

## Code

`StartView.swift` (pages and `StartDrafts`), `SidebarItem.start(kind)` in `Navigation.swift`, the draft rows in
`MainSidebar.swift`, routing in `RootView.swift`. The New debate, New notebook and New agent sheets were removed.

## Not yet

- A start page for a new Build session (`NewSessionSheet` stays a sheet).
- Naming a notebook or agent from its first message.
