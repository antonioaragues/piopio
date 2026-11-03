# Grok Bot: ideas for Agents (2026-11-03)

A walkthrough of the Grok Bot Mac app (bundle `com.anysphere.sand`, billed through Cursor) on this Mac, looking for ideas for Agents (06-agents). Everything below was seen in the app, not taken from its docs.

**Folded into the spec on 2026-11-03:** 06-agents AD5, `ask_user` and `save_skill` (§4), PR7, AS5, UI7–UI11 and §12.2 (later ideas), and roadmap milestone 4.9.

## What Grok Bot is

A messaging app where **every bot is a contact**. The sidebar is a list of bots, each with an avatar, its last message and an unread dot, like WhatsApp. There are no modes, tabs or definition editor: you set a bot up by talking to it.

| Area | What it has |
|---|---|
| Sidebar | Bots (avatar, name, last line), search, **+** new bot. At the bottom: account menu and **Connect apps**. |
| Conversation | One continuous chat per bot, with day separators. Messages have react, reply and a ⋯ menu. The composer has **+** (Attach files, **Teach a task**), dictation and a **voice chat** button. |
| Bot details (side panel) | Three tabs: **Details** (routines, voice settings), **Library** (files the bot made, grouped "This week") and **Computer** (the bot's own screen). |
| Settings | General, Computer, Permissions, Vault, Usage and billing, Updates. |

## What stood out, and what Piopio could take

### 1. Setup is a conversation, with choice cards
A new bot opens with *"Hi Antonio! I'm New Bot, here to take work off your plate"* and a card: *"What would you like me to help with? Pick one or tell me in your words."* Once you answer, the card shrinks to the option you chose ("A · Email and calendar"). The next question is *"What do you use for email and calendar?"*, with options for Gmail and Google Calendar, Outlook / Microsoft 365, and "Something else".

- Each option has a letter (A–E). The last one is always a free-text **"Something else"**. Once you've answered, only your choice stays in the transcript.
- The same card shows up mid-work, for example *"Which project do we pick?"* with options A to D plus "Something else". While a question is open, the composer placeholder changes to *"Type your answer or talk about something else"*.

**For Piopio:** Agents already plans an **Agent Builder** chat (AD1) and a form editor. Grok shows that **the chat can be the whole setup**: the agent interviews you, and the definition is a by-product. Ideas:
- A new agent starts in the Builder conversation and asks 2–3 choice-card questions (what it's for, which apps, how it should reach you). Only after that does it show the definition diff. The form editor stays for later edits.
- Agents get the Build question card (`ask_user`, already built in 2.2), shown **inline in the transcript** rather than above the composer, and collapsed to the answer once you've replied. In Telegram and WhatsApp it becomes buttons (CH: inline keyboards / reply buttons), with "Something else" as a free reply.
- Change the composer placeholder while a question is open.

### 2. Routines are created by asking, not configured
The Details tab doesn't have a schedule form. It just says: *"Routines are recurring tasks this bot runs on a schedule. Ask in the chat to set one up."* The list fills in as the bot creates them.

**For Piopio:** we already have `schedule()` as a tool (PR1). Make the agent page's Schedules section **a list of what exists**, with the empty state "Ask {agent} to set one up", and keep cron editing in the Definition tab. That matches "build only existing features" and saves a form.

### 3. Each bot has its own computer
The **Computer** tab shows "{Bot}'s screen": a live view of a cloud VM that sleeps when idle (*"The computer is asleep"*) and wakes when needed (*"Waking up…"*). In Settings › Computer:
- **Run on this computer:** "Ask every time" (dropdown), described as *"Lets Grok Bot open files and run tasks on your computer. Auto-review still checks everything first."*
- **Route traffic through this computer:** the bot's cloud computer sends its network traffic through your Mac, so sites see your home connection. There's a counter: "0 routed this session".
- **Manage devices:** this Mac (online now), and an iPhone (last opened 5 days ago).
- **Bot computer:** "Update" (apps and packages are wiped, files and logins are kept, every bot updates together) and "Reset" (rebuild from the last snapshot).

**For Piopio:** this is the cloud version of 11-computer-use plus the Mac Bridge (§10). Ideas that fit our "local by default" rule:
- A **Screen** panel on the agent page that shows what the agent is driving, live, when computer use lands (D10). It works the same whether the agent drives the Mac or, later, a cloud sandbox.
- **Sleeping/waking states** for anything slow to start (engine, cloud agent, bridge), named in plain words.
- The **device list** with online and last-seen status fits the Mac Bridge header ("Cloud", "This Mac") as a Settings › Devices section.
- Routing cloud traffic through the Mac is clever but heavy. Note it for later, after 13-cloud-engine.

### 4. Permissions are rules written in plain language
Settings › Permissions has **Auto-review** ("checks Grok Bot's actions against custom rules"), plus two lists:
- **Always ask:** *"Stops and asks when an action matches these rules."*
- **Allow without asking:** *"Continues automatically when an action matches these rules."*

You add a rule as one sentence (placeholder *"Purchases over $50"*, hint *"Say the action and who or what it affects, like 'Emails to dana@acme.com'"*). A model checks each action against these sentences.

**For Piopio:** our `policies.requireApproval` uses patterns such as `send_message:to_non_owner` and `http_request:POST`. These are precise but written for developers. Ideas:
- Show the **existing rules as sentences** ("Messages to anyone but you", "Web requests that send data"), and let the owner **add rules as sentences**. The Builder agent translates each one into a pattern when it can. If it can't, the rule stays a sentence and a reviewer model judges it (a cheap utility model, cached per tool and argument shape). Show which kind each rule is.
- Same two lists, "Always ask" and "Allow without asking", for every agent, plus a global default in Settings. This matches the Build modes, and "Always allow …" from AS1 fills the second list.

### 5. A vault the bot can use but never read
Settings › Vault has the tabs All, Logins, Payments and More, and a **New item** button. *"Grok Bot never sees the number or security code of a saved card. It can see logins and contact details so it can type them for you."*

**For Piopio:** we have `secret:NAME` for API tokens (AD2). A user-facing vault (logins, addresses) only matters once agents fill forms through computer use. Note the rule for then: card numbers are only ever filled by the app and never shown to the model; logins can be shown. It also fits the password-manager connectors (1Password appears as its own category in Grok).

### 6. Library: everything the bot made, in one place
The Library tab lists the files and pages the bot produced, grouped by week. Files show up in the chat as cards (name, size, Open, Save). A web "page" shows as a larger card with a preview.

**For Piopio:** UI4 already plans a per-conversation side panel ("3 links · 2 files"). Grok's version is **per agent across all conversations and runs**, grouped by time. Make the agent page's files view that, with run outputs included, so that "what did my research agent make this week" has one answer.

### 7. Long work runs in the background, and the bot comes back
The bot says *"While I collect the exact links in the background, tell me which path you prefer"* and asks a question card. Later, a new message arrives after a day separator: *"The research has finished… review the matrix and the three drafts and tell me which we pick."*

**For Piopio:** this is `run:` conversations plus `tell_agent`/`send_message` to the owner. The pattern to copy is in the transcript: the agent **says it's starting background work and keeps talking**, and the result comes back as a new message in the same chat (not only in Runs). That message sets the unread dot and posts to Needs you.

### 8. Skills are written by the bot
Connect apps › "1 connected" opens **Manage plugins and skills**, which lists installed plugins (each with how many connectors it has) and **Private skills**: *"No private skills yet. Ask your Bot to create one for you."*

**For Piopio:** agent folders already have `skills/` (SKILL.md). Add a `create_skill` path through the Builder: "remember how to do this as a skill" writes `skills/<name>/SKILL.md` and shows the diff. The same empty state on the agent page.

### 9. Teach a task
The composer's **+** menu has **Teach a task**, with a red record dot: you show the bot how to do something and it learns it. I didn't start it because it records the screen.

**For Piopio:** a natural follow-on to computer use and skills: record a demonstration (screen and events), and the agent writes a skill from it. Far off, but worth a line in the backlog.

### 10. Small touches
- **The accent follows the bot:** Settings › Appearance › Accent defaults to "Bot color". Each bot has a color avatar, and its conversation uses that color (the send button changes color per bot). Piopio agents have avatars; giving each agent a tint for its header and send button would make side-by-side columns (UI3) easier to tell apart.
- **Voice per bot:** Details has voice-chat settings (voice "Liora", speed, language auto-detect), and the composer has a separate voice-chat button next to dictation. UI5 already plans dictation now and hands-free voice later; voice settings belong on each agent.
- **Usage as one meter:** the account menu shows "Weekly usage · 0% used" without opening anything. Settings › Usage shows the weekly limit with "resets in 6 days", and a separate monthly on-demand cap. Piopio's budgets are per agent (AS3). A single "This month · 34% of budgets" line in the sidebar or menu would make them visible.
- **Connect apps is a catalog:** search over "apps and skills", category chips (Password managers, Productivity, Communication, Design, Code, plus Data, Sales, Marketing, Finance, Research and Support under More), a "Recommended for you" row and a **Bot templates** link. 12-connectors is building this. The "recommended" row and templates in the same place are worth copying.

## What Piopio does that Grok doesn't
Things to keep, not trade away:
- **Channels:** Grok bots live only in its own app (plus iOS). Piopio agents answer on Telegram and WhatsApp.
- **Contacts and isolation:** Grok bots serve only you. Piopio agents talk to other people, with separate memory per contact (AS2).
- **Agent-to-agent** with traces and budgets (§7).
- **Undo on result cards** (§4.2): Grok asks before acting but showed nothing about reverting.
- **Local first:** Grok's bots run in its cloud by default, and the Mac is an optional helper. Piopio is the other way round.
- **An inspectable definition:** files in git, with history and rollback. Grok gives no view of what a bot "is".

## Suggested next steps (most value first)
1. Inline question cards for agents (reuse `ask_user`), shown in the transcript and on channels as buttons.
2. Builder-first agent creation that interviews you with choice cards.
3. Approval rules shown as, and added in, plain sentences.
4. The agent page's Schedules, Skills and Files sections as "lists of what exists" with "Ask {agent} to…" empty states.
5. A per-agent Library across conversations and runs.
6. Agent accent color. Usage meter in the sidebar.
7. Backlog: Screen panel (with D10), vault rules (with computer use), Teach a task.
