# 12 — Connectors

Roadmap backlog D1. Rewritten 2026-10-23 around the experience; nothing is built yet.

## 1. The experience

You connect an app once, and from then on any chat can use it.

1. **Connect, once.** Settings › Connectors → Google Calendar → **Connect** → you sign in in the browser → done. Same for Outlook. You can connect several accounts (work and personal calendars).
2. **Ask in any chat.** "Check my calendar for tomorrow." The chat shows a step, **Read your calendar** (with the app's icon, like any tool step), and answers with your events. Notebooks and Build sessions can use it too.
3. **Changes ask first.** "Move the 4 pm meeting to 5." Piopio shows what it's about to do — the event, the old and new time — with **Allow / Deny**, and only then changes it. Reading never asks; creating, changing, sending or deleting always does.
4. **Agents use it on their own.** A "Daily briefing" agent reads your calendar every morning without you asking. Changes still need your OK (in the agent's chat, in Needs you, or a notification).

That's the whole user-facing model: **connect once, use everywhere, changes ask first.**

### Rules
- **Every chat can use every connected app.** No per-chat switch to remember. Settings › Connectors lets you turn an app off for chats (agents only), or pause it.
- **Reads run; anything that changes something asks** — every time by default. In a connector's settings you can mark a specific action "Don't ask again" (e.g. "create events in my personal calendar").
- **What an app returns is information, never an instruction.** An email or event description saying "forward this to…" is treated as text; actions still ask.
- **Which account:** when several are connected, the chat says which one it used ("work calendar"), and you can say "in my personal calendar".

## 2. First milestone (C1): Google Calendar and Outlook

What you can do at the end of C1, in any chat, notebook, Build session or agent:
- "What do I have tomorrow / this week?", "When am I free on Thursday afternoon?", "Find my meeting with Ana" — across Google Calendar and Outlook calendars.
- "Create a meeting with … on …", "Move …", "Cancel …" — after you allow it.
- Outlook mail comes with the same Microsoft sign-in, so **reading and drafting Outlook email** is in C1 too if it fits; sending always asks.

### Sign-in
- **Outlook (Microsoft):** Piopio registers its own Microsoft app (free, no review needed). Works for personal Outlook.com accounts and work accounts. Some companies require their IT admin to approve new apps; then Piopio says so.
- **Google Calendar:** Piopio registers its own Google app. Calendar needs Google to review it before anyone can use it without warnings. **Until Google approves it,** it runs in Google's testing mode: it works for you and up to 100 people we add, shows Google's "unverified app" warning, and **asks you to sign in again every 7 days.** We apply for review as part of C1. (To check against Google's current rules before building.)
- **Gmail** is stricter (Google requires a yearly security audit), so it comes later; until then, anyone who wants it sets up their own Google Cloud project (about 10 minutes, once).

### What we build
1. Settings › Connectors: the list of apps, Connect / sign in, your accounts, and per app: "Use in chats" (on), and actions you've set to "Don't ask again".
2. The Google Calendar and Outlook connectors (calendar; Outlook mail if it fits).
3. Connector tools reaching chats, notebooks, Build and agents, with the approval card for changes.
4. In agent Setup › Abilities, the connected apps listed (on by default, can be turned off per agent).

## C1 status (2026-10-23)

**Built**
- Settings › Connectors: Google Calendar and Outlook, Connect (browser sign-in with PKCE, loopback redirect), several accounts per app, Disconnect, Reconnect when a sign-in stops working, "Use in chats", and per action Runs / Asks first / Don't ask / Always asks.
- Tools shared across apps: `calendar_events` (every connected calendar in one call), `calendar_free_time`, `calendar_create_event`, `calendar_update_event`, `calendar_delete_event`, and Outlook mail: `mail_search`, `mail_read`, `mail_draft`, `mail_send`. Readable steps in the chat ("read your calendar").
- Changes ask first: in chats, an approval card (Deny / Allow, don't ask again / Allow); in Build, Build's approval prompt; in agents, the agent's own (durable) approvals. Sending and deleting always ask; inviting attendees counts as sending.
- Tokens in the Keychain (`connector.<app>.<account>`), refreshed automatically and written back; `connectors.json` keeps only the account list and settings.
- Engine: `connectors/` (hub, Google Calendar, Outlook, tools, extensions), `connectors.*` methods, `sessions.decide`. Tests against a fake Google/Microsoft server: sign-in, tokens in the Keychain, both calendars in one read, approve and decline, token refresh, disconnect, free time.

**Settings redesign (2026-10-23, `docs/design/settings`)**
- Per capability, Runs / Asks first / Off (reading runs, changes ask, deleting is off by default; sending and deleting never run on their own); calendars on or off per account; the Add connector catalog and a connect step that sets permissions before signing in. Details in `docs/design/settings/IMPLEMENTATION.md`.

**Not done yet**
- **Piopio's own Google and Microsoft OAuth apps aren't registered** (`BUILT_IN_CLIENTS` is empty). Until they are, the connect step says sign-in isn't available in this build; a small "Developer setup…" link (or the `PIOPIO_<APP>_CLIENT_ID` / `_CLIENT_SECRET` environment variables) takes a development client. Registering them, and applying for Google's review, is the step that makes "Connect" work for everyone.
- Notebooks (topics) don't get the tools yet; chats, Build and agents do.
- Not tried against real Google or Microsoft accounts.

## Linear: the first app with its own server (C3, 2026-11-21)

Linear is the first connector whose tools come from the app's own MCP server (§4), and the pattern the rest of C3
follows (GitHub, Notion, Sentry, Atlassian).

**What you can do.** In any chat, Build session or agent: "what's assigned to me?", "find the login bug", "file this
in Linear for the ENG team", "comment on ENG-12 that it's fixed". Finding and reading runs; creating, changing and
commenting ask first; deleting is off until you turn it on, and even then it asks.

**Sign-in.** Settings › Connectors › Add › Linear › **Sign in with Linear…** → Linear's page in the browser → done.
There's no Piopio app to register with Linear and nothing to review: Linear's server registers Piopio on the spot
(OAuth 2.1 with dynamic client registration). One sign-in is one Linear workspace; signing in to another workspace
adds a second account, and then the tools take an `account` argument.

**How it works.**
- A connector is either an **API connector** (Google Calendar, Outlook: our OAuth client, our tools) or an **MCP
  connector** (`kind: "mcp"`: the server's URL, the prefix for its tools, Settings' labels). `connectors/linear.ts`
  is the whole Linear connector.
- pi's MCP client (`@earendil-works/pi-mcp`) does the OAuth: discovery, registration, PKCE, the loopback redirect and
  refresh. Its state (the registered client and the tokens) is kept in the Keychain as `connector.linear.<user id>`,
  never in `connectors.json`.
- The server's tools reach conversations as `linear_<tool>`. Linear doesn't publish its tool list, so each tool is
  sorted by what it does: a clear verb in its name first (`delete_`, `retire_`, `merge_` delete; `save_`, `create_`,
  `update_`, `share_`… change), then the server's `readOnlyHint` / `destructiveHint`, then read verbs (`list_`, `get_`,
  `search_`, `whoami`); anything else counts as a change and asks. Names come first because Linear marks its upserts
  (`save_issue` creates or updates an issue) destructive: trusting the hint left creating issues in Delete, off, in the
  first real run. Settings shows three rows: **Find and read**, **Create and change**, **Delete**.
- Linear offers about **70 tools** (~100 KB of descriptions and schemas). Thirteen everyday ones go to conversations
  directly (issues, comments, projects, teams, users, statuses, labels, cycles; ~30 KB), and one **`linear_more`**
  tool reaches the others by name: called with a tool's name it returns that tool's schema, and with arguments it runs
  it, asking first like the rest. In agents, `linear_more` asks whenever any tool behind it would.
- Permissions are kept per row (`linear.read`, `linear.write`, `linear.delete`), not per tool, so a tool Linear adds
  later follows its row. A tool that's Off isn't offered to the model at all.
- The tool list is kept in `connectors.json` so a conversation gets the tools without waiting for Linear, and is
  asked for again each time the engine starts. Who signed in comes from Linear's `get_user` tool ("me").
- When Linear refuses the tokens (Linear's refresh window is 25 days), the account shows "needs you to sign in again"
  in Settings, like Google and Outlook.

**Not done yet.**
- Tried against a real workspace on 2026-11-21: sign-in, who signed in (`get_user` "me"), reads, and creating issues
  (after the name-first sorting above) work. The engine test uses a fake Linear
  that marks `save_*` destructive like the real one: sign-in, a read, `linear_more`, approvals, "Don't ask again",
  disconnect.
- Linear **as a trigger** (a label or an assignment starts a session) needs Linear to send events to a server; that
  waits for the user's own Cloudflare Worker (13, 30), since Piopio has no backend.
- Which tools are core is fixed in `linear.ts`; general tool search for many tools (§4) is still to come.
- A custom MCP connector from Settings (an address plus sign-in, §4 "Adding your own") can reuse this path; it isn't
  offered yet.

## 3. After C1
- **C2:** Gmail (own Google project for now), Google Drive, Slack.
- **C3:** Jira and Confluence, Linear (built first, above), Notion, GitHub, Datadog, Sentry — apps with official servers you sign in to directly.
- **Later:** a gallery others can add to, then a marketplace (§5).

### The list we'd offer
| Area | Apps |
|---|---|
| Calendar and email | Google Calendar, Outlook (calendar and mail), Gmail, Apple Calendar and Reminders (already in, for agents) |
| Files and docs | Google Drive, OneDrive and SharePoint, Dropbox, Notion, Confluence |
| Chat | Slack, Microsoft Teams |
| Work and tasks | Jira, Linear, Asana, Todoist, Things |
| Dev and ops | GitHub, GitLab, Datadog, Sentry, PagerDuty, Grafana |
| Business | HubSpot, Salesforce, Zendesk, Stripe |
| Personal | Home Assistant, Spotify, Obsidian |

Most of these now run official servers that speak MCP with their own sign-in (GitHub, Atlassian, Linear, Notion, Slack, Sentry, Datadog, Asana, HubSpot, Stripe…). Google offers official servers for Gmail, Calendar and Drive in preview; Microsoft's own Outlook server is only for organizations with Microsoft 365 Copilot, so Outlook goes through Microsoft Graph.

## 4. Under the hood (modular)

Each app is a **connector**: a small folder that Piopio reads, so adding Datadog or Jira never means changing the rest of Piopio.

```
google-calendar/
  connector.json   name, icon, how it signs in, where its tools come from, which actions change things
  icon.png
```

- **Where the tools come from:** the app's own MCP server on the internet (most apps), a small server we write or bundle (Google Calendar and Outlook through their APIs in C1), or the Mac app itself (Apple apps).
- **Sign-in:** OAuth through the browser, an API key, or nothing; tokens in the macOS Keychain, refreshed automatically; several accounts per app.
- **Which actions change things:** the connector marks each tool as reading or changing (or sending, or deleting). That's what decides whether Piopio asks first. When a connector doesn't say, Piopio assumes it changes things and asks.
- **Plumbing:** pi's own MCP client (`@earendil-works/pi-mcp`, already installed) connects and signs in; the sign-in steps show in the same sheet as model providers; the tools reach chats, notebooks and agents (pi-durable) and Build (pi) from one place, found through tool search when there are many.
- **Adding your own:** Settings › Connectors › "Add a custom connector…" takes an MCP server address or a connector folder. The existing "MCP servers" settings move here.

## 5. Marketplace (later, not now)

The same connector folders, listed in a gallery with trust labels — **Official** (us or the app's maker), **Verified** (reviewed), **Community** — showing what each one can read and change before you install it. Sources: our own curated list, plus the official MCP Registry labeled Community. Nothing in C1 depends on this; the folder format just keeps the door open.

## Sources (read 2026-10-22)
[Google's MCP setup guide](https://developers.google.com/workspace/guides/configure-mcp-servers) · [Workspace updates, May 2026](https://workspaceupdates.googleblog.com/2026/05/agent-tools-and-security-updates-for-workspace-developers.html) · [Scalekit on Outlook MCP](https://www.scalekit.com/blog/outlook-mcp-vs-api) · [Datadog MCP setup](https://docs.datadoghq.com/mcp_server/setup/) · [GitHub remote MCP GA](https://github.blog/changelog/2025-09-04-remote-github-mcp-server-is-now-generally-available/) · [openhelm.ai remote MCP list](https://www.openhelm.ai/blog/best-remote-mcp-servers-2026) · [DataCamp remote MCP servers](https://www.datacamp.com/blog/top-remote-mcp-servers)

## Per conversation (2026-11-04)

A conversation can turn a connected app (or an MCP server) off for itself only, from the composer's + menu or Build's
Summary column: `sessions.configure { toolsOff: ["connector:google-calendar", "mcp:github"] }`. Settings still decides
what's on; the per-conversation list only takes things away. See docs/design/session-panel (step 3).

