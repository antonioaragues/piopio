# 15 · Onboarding and areas: choose what Piopio is for you

Status: spec for review, 2026-10-25. Nothing is built yet. It changes the first-run welcome (docs/design v2, 12b) and
adds a setting to General; the sidebar, Home, menus and the command palette follow it.

**The idea:** Piopio has three areas: **Build** (code), **Chat** (chats and notebooks) and **Agents**. Not everyone
wants all three. On first run you say which ones you want, and the app shows only those. You can turn areas on and
off later in Settings › General. Turning an area off hides it: nothing is deleted, and nothing that's running
stops unless you say so.

## 1. What we have today
- **The welcome:**
  - It shows only when there's no model (`engine.needsKey`).
  - It asks for an OpenRouter key, then offers three first steps: Look at a project, Just ask something, Get a
    morning briefing tomorrow.
  - It never asks what you want Piopio for.
- **The one sidebar** always shows Pinned, Projects, Notebooks, Agents and Chats, plus Home and Needs you.
- **Everything else is always on:**
  - the menu items: New Thread / Session, New Notebook, Quick Chat, Open Folder;
  - the Home cards and the Ask box targets;
  - the menu bar item, which shows once you have an agent.

## 2. Areas
| Area | What it shows | What it doesn't touch |
|---|---|---|
| **Build** | The Projects section with Build sessions; Open Folder (⌘O); New Session; the Ask box's "Start a session in"; git, terminal and the Build inspector | Your folders and their sessions on disk |
| **Chat** | Chats and Notebooks; New chat (⌘N) and New Notebook (⌘⇧N); Quick Chat and its global shortcut; the Ask box's "New chat"; chats in a folder (the Folder lens, 04-chat §2) | Your threads, notebooks and memory |
| **Agents** | The Agents section; new agent and templates; the menu bar item; Home's upcoming runs; agent entries in Needs you | Agents' definitions, memory, schedules and cloud deploys |

**Always shown, whatever you choose:** Home, Needs you, Pinned, Settings and the command palette. Each of them
shows only items from the areas that are on.

**Rules:**
- **At least one area is on.** The last switch that's on can't be turned off.
- **Hiding stops nothing.**
  - **Build:** a running Build session finishes.
  - **Agents:** agents keep their schedules, unless you choose to pause them when you turn Agents off (§4).
- **Things waiting for you are never hidden.**
  - **Needs you:** an approval or a question from a hidden area still shows there, marked with its area ("Agents ·
    hidden").
  - **Notifications:** these items still notify you.
  - **Answers:** "answer finished" notifications come only from areas that are on.
- **Links into a hidden area still open.** This covers a notification, a deep link or an automation (`.selectItem`).
  The page shows a thin bar: "Agents is hidden · Show it in the sidebar".
- **Pins:** pinned items from hidden areas are hidden but kept, and they come back when the area does.
- **Search:** the command palette searches only the areas that are on.
- **Home:**
  - The Ask box's placeholder and targets follow the areas: "Ask anything, start a build session, or message an
    agent…" loses the parts for hidden areas.
  - Its "Running now" and upcoming cards drop hidden areas' items.
- **Settings:** every pane stays visible (you may want to set something up before turning its area on). Only the
  new Areas row (§4) is added.

**Projects without Build:** with Build off and Chat on, the Projects section stays, as folders to chat about:
- its + reads "Add a folder to chat about";
- a folder offers New chat;
- Build-only actions are hidden: New Session, git, terminal and Run.

With both Build and Chat off, Projects is hidden. (Q1)

## 3. The new welcome
It shows on first run, whether or not a model is set up. People who already use Piopio don't see it again: they
get all three areas and one tip on Home ("You can hide areas you don't use · Settings › General"). It stays one
window that fills the screen, with the chick talking, as today. **Skip setup** stays at the bottom of every step.

**Step 1 · What's Piopio for you?**
- **The question:** the chick introduces itself and asks what Piopio is for you.
- **The cards:** three cards you can tick, more than one:
  - **Build:** "Work in your code: sessions in your project folders, with diffs, git and a terminal."
  - **Chat:** "Ask, draft and think things through. Notebooks keep personal projects together, with their own
    memory and files."
  - **Agents:** "Small assistants that keep going while you're away: briefings, reminders, messages."
- **Shortcut:** an "All three" link ticks every card.
- **Selection:** nothing is ticked at first (Q2), and Continue needs at least one card.

**Step 2 · A model to think with**
- **Already connected:** if a model provider is connected, this step is one line ("Connected to OpenRouter ✓") and
  moves on by itself.
- **Otherwise,** it's the same connect step as Settings › Models (10-model-providers), with the first suggestion
  based on what you chose:
  - **Build:** sign in with a subscription you already pay for (ChatGPT/Codex) or an OpenRouter key.
  - **Chat:** an OpenRouter key, or a local model server if one is found (LM Studio, Ollama).
  - **Agents:** an OpenRouter or provider API key. Cloud agents need an API key, because subscription sign-ins stay
    on the Mac (13 §5.1). The step says so in one line.
- **Paste and check:** the key or sign-in is checked as you paste, as today.

**Step 3 · Set up what you chose**
One short card per chosen area, in the order Build, Chat, Agents. Each card has its own Skip.
- **Build:** add a project folder (⌘O). It says whether the folder is a git repo and whether `gh` is signed in.
- **Chat:** a few lines about you for About me (optional, editable later in Settings › Chat), and the Quick Chat
  shortcut.
- **Agents:**
  - pick a first agent from the templates (Daily briefing first, or none);
  - choose whether Piopio stays in the menu bar so agents run with the window closed (background mode, 06-agents
    §11).

**Step 4 · Ready**
- **First steps:** today's three, kept only for the areas you chose, so a Chat-only user sees just "Just ask
  something".
- **After it:** it opens Home, or the item you just set up, such as the project you added.

**Run setup again:** a button in Settings › General opens the welcome again, with your current choices ticked.

## 4. Settings › General › Areas
- **The rows:** a new card at the top of General, one row per area. Each row has its icon, name, one-line
  description, a switch and a count of what it holds ("6 projects · 14 sessions").
- **Turning an area off:**
  - **Build:** if a session is running, the row says it will finish ("1 session is still running; it will
    finish").
  - **Agents with agents that run:** a small sheet asks "3 agents run on this Mac (2 schedules, 1 cloud). Keep them
    running, or pause them?" Keep running is the default (Q3). Pausing uses each agent's existing pause.
- **Turning an area on:** its section comes back where it was, collapsed or not, with its pins.
- **Run setup again** sits below the card.

## 5. Implementation notes
- **Storage:** the areas are an app setting, `UserDefaults` `areas` (`"build,chat,agents"`), with `welcomeVersion`
  set when the welcome is done or skipped. The engine doesn't need to know: hiding is UI only, and pausing agents uses
  the protocol we already have.
- **One source of truth:** an `Areas` model (an observable set of `AppMode`) read by:
  - MainSidebar (sections), HomeView (cards, the Ask box), PiopioApp (menu items, MenuBarExtra), CommandPalette,
    NeedsYou and QuickChatController (its global shortcut is unregistered while Chat is off);
  - RootView, which decides when the welcome shows (first run instead of `needsKey`).
- **Modes and sections:**
  - `AppMode` (build, chat, agents) already exists and becomes the area type.
  - `SidebarSection` maps to it: projects → build (or chat, §2), notebooks and chats → chat, agents → agents.
- **Welcome:** WelcomeView becomes four steps. Its key card is replaced by the Models connect view, so there's one way
  to connect a provider.
- **Capture hooks** for the welcome and the settings card: `PIOPIO_DEMO_WELCOME` (exists), plus `PIOPIO_DEMO_AREAS`
  (for example `chat`) to start with some areas.

## 6. Done when
- **Choosing areas:** a new user who picks only Chat sees Home, Needs you, Notebooks and Chats. The menus have no
  Build or Agents items, the Ask box offers only chats, and there's no menu bar item.
- **Turning Agents off with agents scheduled:** Keep running leaves them firing on time, and their approvals show
  in Needs you and as notifications. Pause pauses them.
- **Turning an area back on** restores its section, its collapsed state and its pins.
- **Links:** a notification or link into a hidden area opens it with the "is hidden" bar.
- **Existing users** keep everything, see the tip once and never see the welcome.
- **Verified with:** Swift tests for the `Areas` model and the section mapping, plus app captures of each welcome
  step, a Chat-only sidebar and the Areas card.

## 7. Questions for you
- **Q1 · Projects without Build:** keep it as folders to chat about (proposed), or hide Projects whenever Build is
  off?
- **Q2 · First choice:** nothing ticked so you have to choose (proposed), or all three ticked so Continue works
  straight away?
- **Q3 · Turning Agents off:** keep agents running by default (proposed), or pause them by default?
- **Q4 · Names in the welcome:** the product names (Build, Chat, Agents), or plain words (Code, Chat and notebooks,
  Assistants)? The sidebar keeps its section names either way.
