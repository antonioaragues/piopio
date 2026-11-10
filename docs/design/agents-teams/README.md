# Handoff: Agents, teams and projects

## Overview
A redesign of how agents, teams and projects relate in Piopio (native Mac app, SwiftUI). It covers the information architecture (sidebar), the agent page, agent setup, the team page, assigning a team to a project, and the user journeys behind each one. The guiding principle: **start from what the user wants to happen, not from which kind of object to create.** Agents, teams and projects share one visual language: avatar, colour and a role verb.

`agents-brief.md` is the original brief and describes the current state. This README supersedes it wherever they disagree.

## About the design files
The files in this bundle are **design references made in HTML**. They show the intended look and behaviour; they are not code to ship. Rebuild them in the existing SwiftUI codebase with its own patterns and the current `docs/design/grey` style. Open `Agents and teams.dc.html` in a browser (it needs `support.js` and `Sidebar.dc.html` next to it). It is a pan/zoom canvas:
- **Round 2 (top):** the agreed data model, five rules, and storyboards 5a–5f.
- **Round 1 (below):** full-window screens with option ids 1a–4b.

## Fidelity
**Mid-to-high fidelity.** Layout, hierarchy, copy and behaviour are final intent. Colours and type follow the existing grey style; if they differ, use the codebase's tokens (values listed below). Storyboard frames (440×300) are simplified crops of real screens, not separate components.

---

## The data model (agreed)

| Object | What it is | Rules |
|---|---|---|
| **Conversation** | A chat. Lives in a project or on its own. | Always with Piopio or, in a project that has a team, with that team's lead. Your agents join with `@name`, or when the model calls them. They are never *assigned*. |
| **Project** | A folder. Normal sessions with Piopio. | Can have **at most one team** assigned (optional). The Board only exists when there is a team. A team created inside a project lives there unless saved for reuse. |
| **Agent** | Someone who acts for you: model, instructions, tools, memory, routines, channels, budget. Has its own chat. | Can be a member of teams and keeps its identity there. **Cannot be assigned to a project.** |
| **Team** | Members in roles, plus team settings. No chat. | A member is either **one of your agents** or a **team-only agent** (exists only inside the team, inherits the team's settings). Team settings: model, tools for team-only members, review limit, budget per job, TEAM.md, team notes. |

**Routines** have one of two owners:
- **Agent routine:** the agent messages *you* (Piopio or Telegram), e.g. "every weekday 8:00, your briefing".
- **Project routine:** opens a new session in that folder, with the lead if there is a team, e.g. "every Monday 9:00, write this week's brief".

**Memory ownership:** what an agent learns while working in a team goes to the team's notes or the project's NOTES.md, never to its personal memory. Say this in the UI when an agent joins a team.

## Five rules
1. **Teams are born in a project.** When work grows, Piopio offers a team and drafts it by reading the project. It can then be saved for reuse. Creating a team from Teams › + still works but is secondary.
2. **Every member is an agent.** Same avatar, same page, same setup. Team-only members can be turned into your agents ("Make it one of your agents").
3. **Create by talking, adjust by seeing.** Nothing starts with a form. Talking produces a card you can correct, with Undo; Setup is for later.
4. **One agenda.** Home brings together what's waiting on you, what happened while you were away, and today's timeline of all routines (agents and projects).
5. **Memory has an owner** (see above).

---

## Screens

Recommended options are marked ★. Alternatives stay in the file for reference.

### Sidebar: ★1a "One Agents section"
- 248pt wide, background `#1a1a1a`, right hairline `rgba(255,255,255,0.06)`.
- Order: Search ⌘K · Home · Needs you (count) · **Projects** · **Agents** · **Conversations** · user footer.
- **Agents** lists your agents *and* saved teams together. Agent row: 18pt avatar (5pt radius, colour fill, initial in `#151515`, 10pt bold). Team row: a stack of 3 overlapping 10pt circles (−4pt overlap, 1.5pt ring in the sidebar colour) plus its member count.
- A project with a team shows the team's avatar stack on its row. Team-only (unsaved) teams appear **only** there, never under Agents.
- Agent rows: a blue dot for unread; "Draft" in secondary text for drafts.
- Rows are 28pt tall, 6pt radius; selected background `rgba(255,255,255,0.08)`; section headers 11.5pt `#7a7a7a` with a `+`.
- 1b (expandable teams) and 1c (directory + pinned) are alternatives.

### Agent page: ★2a "Chat first, with an at-a-glance strip"
Two tabs only: **Chat | Setup**. The separate Activity tab and the 300pt info panel go away.
- **Header (52pt):** 22pt avatar · name (14 semibold) · one-line description (secondary) · spacer · segmented Chat/Setup · "Run now" button · ••• menu.
- **Glance strip:** 4 equal cells, hairlines above, below and between; 12×20 padding; label 11.5 `#7a7a7a`, value 13:
  - **Next:** e.g. "Tomorrow 8:00 · weekdays".
  - **Can:** e.g. "Web · Memory · Message you".
  - **Reaches you:** e.g. "In Piopio · Add Telegram", where "Add Telegram" is a link.
  - **This month:** e.g. "$0.05 of $15", with an 80pt progress bar.
  - Clicking a cell opens that section in Setup.
- **Chat column:** max 640pt, centred, 14pt text, 1.55 line height.
  - **Runs are dividers in the chat:** a centred line, e.g. "Today 8:00 · Automatic run · 2 steps ›". "2 steps ›" expands the steps inline.
  - A run that produced nothing collapses to a single grey divider ("nothing new, didn't write · $0.0004").
  - Held messages show as a divider too: "Held until quiet hours ended".
  - **Setup-change card:** border `rgba(255,255,255,0.09)`, background `#232323`, 10pt radius, title "Changed its setup" with "Undo" on the right, and a list of what changed.
  - **Permission request inline:** row on `oklch(0.3 0.05 255)`, text plus "Not now" / "Allow" (primary is white `#ececec` with `#111` text).
- **Composer:** placeholder "Reply, or ask it to change how it works…", with the model name on the right.
- 2b (profile + side chat) is an alternative. Its "Coming up" and "While you were away" blocks can be reused elsewhere.

### Agent setup: ★2c "Ordered by questions"
Left nav (180pt), then content up to 720pt wide. Six sections instead of the current ten:
1. **What it does:** name, avatar, colour, one line, instructions, model, thinking.
2. **When it acts:** routines.
   - Time and event routines in one list. Each row: type label ("At a time" / "On an event"), a plain sentence ("Weekdays at 8:00"), the task below it, "Next: …" or "Last: …", and a toggle.
   - Add links: "+ At a time", "+ When an email arrives", "+ When a file appears", "+ From a link (webhook)".
   - Cron only appears when editing, as "Custom".
   - Quiet hours and time zone go here.
3. **What it can use:** Abilities and Mac apps merged into one list. Each tool has a 3-way segmented control **Off · Asks · Allowed**; this replaces the global approval mode.
4. **Who it talks to:** people and channels (Telegram).
5. **What it knows:** memory.
6. **Limits:** budget, messages a day, unknown senders.

Footer links: "History · View as file". Keep "Saved … · Revert · Save ⌘S" in the header.

### Team page: ★3a "Team as a chain of work"
- **Header:** team name · "Works in piopio" · segmented **Members | TEAM.md | Notes | Projects** · ••• (Save as template lives here).
- **Members** are shown as the path a task takes, in a 4-column grid with "→" separators:
  - Columns: **Plans** (lead) → **Does tasks** (builders, with a "×3 at once" badge) → **Reviews** → **Merges** (CI, dashed border, "No model · automatic").
  - Each card: 26pt avatar, name, the role as a sentence, and model or origin. A member that is your agent shows "Is your agent Code reviewer ↗", linking to its page. Team-only members show their model.
  - Selected card: 1.5pt accent border, background `#252525`.
- **Inline editor** below the chain (not a modal): Responsible for · Done means · Who it is (dropdown "A new member" / one of your agents) · Model ("The team's · Haiku 5.5") · "Remove from team".
- **Add member** (storyboard 5f-2) is one picker with two groups:
  - **"Your agents":** each shows its model and tools.
  - **"New, only in this team":** "Blank member" or "From a role…".
  - Every member carries a tag: `your agent` (filled in its own colour) or `team only` (outlined).
- **Team settings** (5f-3): Model · Tools (for team-only members) · Review ("sent back at most 2 times, then ask me") · Budget per job · TEAM.md.
- **Projects tab** (5c-3): rows per project with status ("2 tasks doing", "Idle · last job 5 days ago") and tasks at once. Footer note: "Changing a member changes it in every project. Tasks already started keep how they began."

### Project settings: ★4a "Who works here as a choice"
- Two radio cards side by side:
  - **Piopio alone:** "Each conversation works on its own."
  - **A team:** a team dropdown and a mini chain (16pt avatars: Lead → Builder ×3 → QA → CI).
  - The selected card has a 1.5pt accent border.
- Below: "No team fits? Describe one for this project…".
- **"How the team works here"** (only shown with a team): Tasks at once · Checks (monospace, e.g. `swift test`) · project routines + "Add a routine".
- **Instructions and notes:** AGENTS.md and NOTES.md, each with a "Create" or "Edited …" action.
- **Fit check** when adding a team to a project (5c-2): ✓ / ! rows, each with a one-click fix ("Start git", "Write one with Piopio"), then Cancel / Add to project.

### Board empty state: ★4b
Replace "Choose a team in Settings" with an inline picker:
- your teams ("Use here"),
- templates ("Use here"),
- "Or describe one…".

The same pattern is used in the project's "Give it a team" card.

### Home: 5e
Home absorbs **Needs you**. Two columns:
- **Left:**
  - **Waiting on you · N:** inline actions: Allow, Review, or an answer field for questions.
  - **While you were away:** one line per agent or team, with quiet runs greyed.
- **Right:**
  - **Today:** a vertical timeline (left hairline) of all routines from agents and projects, past items greyed and a "now" row highlighted.
  - Footer: quiet hours and where held messages wait.

---

## Journeys (storyboards in the file)

**5f · Build a team**
1. Describe it in a sentence; naming one of your agents adds it as such.
2. Add member: your agents, or a new team-only one.
3. Team settings are the base that team-only members inherit.

**5a · "I want this to happen on its own": create an agent by talking**
1. An empty agent asks "What should I do for you?", with 3 suggestion chips and a free field. Entry points: Agents › +, ⌘⇧N, "Turn into an agent" from a conversation.
2. At most 3 questions, one at a time, with quick-reply chips and "Question n of 3".
3. **It comes alive:**
   - Avatar, colour and name appear; header and sidebar update together. Animate the avatar from a dashed outline to a filled colour with a soft ring (`colour / 0.18`, 6pt).
   - It shows an identity card: Does / When / Uses (permissions that need OK are marked in amber) / Reaches, with "Looks good" or "Change something".
4. It offers a **trial run now**, shown as a "Trial run · now" divider, then the header shows "Next: tomorrow 8:00".

**5b · "This has got too big": a team is born in the project**
1. In a project conversation with Piopio, divisible work makes Piopio offer "Do it here, one by one" or "Bring in a team for piopio".
2. **"A team for piopio" sheet:**
   - A draft read from the repo (language, tests, crash reports).
   - Members with counts; it suggests your agents where they fit, and the reviewer dropdown can swap one in.
   - Detected checks, an estimated cost, and "Start with this team".
   - Alternative: "Use Development team instead".
3. The same conversation is now with the lead. The plan is **one live block** (task rows with a state dot: building, in review, approved), not a stream of events. Grey event lines only for notable things ("Reviewer sent 'Settings screen' back once").
4. **Merge card:**
   - Green border `oklch(0.66 0.14 150)` on `#222a24`.
   - Content: "Ready for main · 3 tasks · 14 files · all checks passed · $0.36", with Merge into main / See changes / Push for a PR.
   - Then: "This team stays on piopio. Use it elsewhere too?" → "Save as 'App team'" / "Keep it here only".

**5c · "Who am I talking to here?"**
1. In a project with a team, the composer has a "with the lead ⌄" pill offering the team's lead (default) or Piopio alone (no board). With no team, there is no pill.
2. **@ mentions:**
   - `@Code reviewer` brings one of your agents in for that message. Its reply is indented with a 2pt left rule in its colour, its avatar and "joined for this message".
   - When the model calls an agent on its own, show "Asked Code reviewer".
3. The team's Projects tab, plus the fit check when adding to another project.

**5d · Agents moving in and out of teams**
1. **From an agent page, "Join a team":** pick the team and the role ("replaces QA"). The panel explains: it keeps its instructions plus TEAM.md; it uses the team's model unless kept; it writes what it learns to the team's notes.
2. A team-only member has the same page as an agent (what it's doing now, history) and a "Make it one of your agents" button.
3. **A conversation that asks to be repeated:** Piopio offers "Make it" (an agent), "Just a routine here" (a project routine) or "No".

**5e · Living with them:** see Home above.

---

## State (suggested)
- `Agent { id, name, line, colour (hue), initial/emoji, instructions, model, tools: [ToolID: .off|.asks|.allowed], routines, channels, budget, memory }`
- `Team { id, name, saved: Bool, settings { model, tools, reviewLimit, budgetPerJob, teamMD }, notes, members: [Member] }`
- `Member { role: .plans|.doesTasks(parallel: Int)|.reviews|.merges, responsibleFor, doneMeans, model?, source: .agent(AgentID) | .teamOnly(AgentDefinition) }`
- `Project { folder, teamID?, tasksAtOnce, checks, routines, agentsMD, notesMD }`
  - `teamID` refers to a team with `saved == false` (lives only in this project) or `saved == true` (reusable, listed under Agents).
- `Routine { owner: .agent(ID) | .project(ID), trigger: .time(cron, humanLabel) | .email(filter) | .file(path) | .webhook, task, enabled }`
- `Conversation { projectID?, with: .piopio | .lead(teamID) }`
  - `@mentions` are per-message invocations, not membership.

## Design tokens (as used; prefer the codebase's grey tokens)
- **Window background:** `#1f1f1f`
- **Sidebar background:** `#1a1a1a`
- **Raised surfaces:** `#232323`, `#252525`, `#262626`
- **Fields and segmented controls:** `#2a2a2a`; selected segment `#3a3a3a`
- **Hairlines:** `rgba(255,255,255,0.06–0.09)`
- **Text:** primary `#e6e6e6`, secondary `#9a9a9a` / `#8a8a8a`, tertiary `#7a7a7a`
- **Accent:** `oklch(0.66 0.17 255)`; links `oklch(0.72 0.14 255)`
- **Primary button:** `#ececec` with `#111` text
- **Status colours:**
  - success / approved: `oklch(0.72 0.14 150)`
  - warning / held / needs OK: `oklch(0.75 0.13 70)`
  - running: accent
  - idle: `#555`
- **Agent colours:** `oklch(0.72 0.12 H)` with hues 70 (amber), 150 (green), 190 (teal), 255 (blue), 300 (violet). CI or system members use `#555`.
- **Type:** SF Pro. Sizes:
  - 11.5 (labels)
  - 12–13 (UI)
  - 14 (chat, row titles)
  - 16–17 (section titles)
  - 20 (agent name in profile)
- **Radii:**
  - avatars: 5pt at 18pt size, 6pt at 22pt, 7pt at 26pt, 12–14pt at 44–52pt
  - rows and buttons: 6–7pt
  - cards: 10–12pt
  - composer: 14pt

## Assets
None. Avatars are colour plus initial; the app may keep emoji or SF Symbols as the avatar glyph. Icons in the mock are placeholders; use SF Symbols.

## Files
- `Agents and teams.dc.html`: all screens and storyboards (open in a browser).
- `Sidebar.dc.html`: sidebar variants (`unified` = 1a, `grouped` = 1b, `directory` = 1c).
- `support.js`: runtime needed to open the HTML files.
- `agents-brief.md`: the original brief (current state).
