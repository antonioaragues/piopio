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

## 3. After C1
- **C2:** Gmail (own Google project for now), Google Drive, Slack.
- **C3:** Jira and Confluence, Linear, Notion, GitHub, Datadog, Sentry — apps with official servers you sign in to directly.
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
