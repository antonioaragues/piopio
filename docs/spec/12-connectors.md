# 12 — Connectors (proposal, 2026-10-22)

Roadmap backlog D1: connect Piopio to the apps people work in — Gmail, Calendar, Outlook, Jira, Datadog and so on — so chats, notebooks, Build sessions and agents can read from them and act in them. Three requirements from the user:

1. **Modular:** anyone can add a new app without changing Piopio.
2. **A marketplace later** (not now): the format must make it possible.
3. **A list** of the connectors we'd ship ourselves.

This is a proposal to decide on; nothing is built yet.

## 1. What we have today

- **MCP servers** (Settings › MCP servers, pi's `mcp.json`): technical, one JSON entry per server. They reach Build sessions through pi's MCP extension, and chats and notebooks through our own bridge (`tools/mcp-chat.ts`) only when "Also in Chat" is on. Agents don't get them.
- **Apple apps as tools** (06-agents §4.1): Reminders, Calendar, Contacts, Notes, Music, Shortcuts, run by the app with its own permissions through the `app.tool` reverse request.
- **`@earendil-works/pi-mcp`** (installed, 1.3.0): a standalone MCP client "for pi and other applications" with stdio and streamable HTTP transports, **OAuth** (`./oauth`: dynamic client registration, Client ID Metadata Documents, registered clients, token refresh) and tool annotations (`readOnlyHint`, `destructiveHint`). pi's own MCP support signs in to Sentry, Figma and similar servers with it.
- **Sign-in UI** we built for model providers (`providers.auth` steps: browser page, device code, pasted code) and the **Keychain-backed credential store**.

## 2. The market (October 2026)

Most of the apps on the list now run **official remote MCP servers with OAuth**: GitHub, Atlassian (Jira and Confluence), Linear, Notion, Slack, Sentry, Stripe, Asana, HubSpot, Cloudflare, Figma, Datadog. Signing in needs no app registration when the server supports dynamic client registration or Client ID Metadata Documents.

Two important exceptions:
- **Google Workspace** offers official remote MCP servers for Gmail, Calendar, Drive, Chat and People (developer preview since May 2026). Each needs its API enabled in a Google Cloud project, and Gmail's scopes are "restricted": a public app needs Google's verification and a security assessment.
- **Microsoft's** own Outlook MCP (Work IQ Mail and Calendar, Agent 365) is a preview for organizations with Microsoft 365 Copilot licenses, set up by an admin; nothing for personal Outlook.com accounts. The practical route is Microsoft Graph, through an open-source server or our own, with an Entra app registration.

Sources: [Google's MCP setup guide](https://developers.google.com/workspace/guides/configure-mcp-servers), [Workspace updates, May 2026](https://workspaceupdates.googleblog.com/2026/05/agent-tools-and-security-updates-for-workspace-developers.html), [Scalekit on Outlook MCP](https://www.scalekit.com/blog/outlook-mcp-vs-api), [Datadog MCP setup](https://docs.datadoghq.com/mcp_server/setup/), [GitHub remote MCP GA](https://github.blog/changelog/2025-09-04-remote-github-mcp-server-is-now-generally-available/), [openhelm.ai remote MCP list](https://www.openhelm.ai/blog/best-remote-mcp-servers-2026), [DataCamp remote MCP servers](https://www.datacamp.com/blog/top-remote-mcp-servers). Endpoints and registration support should be confirmed per vendor when each connector is built.

## 3. Architecture

### 3.1 A connector is a folder with a manifest

```
gmail/
  connector.json     what it is, how it runs, how it signs in, what its tools may do
  icon.png
  server/            optional: code for a local server (kind "local")
```

```jsonc
{
  "id": "gmail",
  "name": "Gmail",
  "publisher": "Piopio",               // or the vendor, or a community author
  "version": "1.0.0",
  "category": "email",                 // email, calendar, files, chat, issues, docs, monitoring, crm, payments, home…
  "description": "Search, read and draft email.",
  "homepage": "https://…",

  // How it runs: one of
  "runtime": { "kind": "remote", "url": "https://gmailmcp.googleapis.com/mcp/v1" },   // a remote MCP server
  // { "kind": "local", "command": "node", "args": ["server/index.js"] }             // an MCP server we start
  // { "kind": "native", "service": "apple.reminders" }                               // built into the app (app.tool)

  // How it signs in: one of
  "auth": { "type": "oauth", "discovery": "mcp", "scopes": ["…"] },   // MCP's own OAuth (registration, CIMD)
  // { "type": "oauth", "client": "piopio-google" | "bring-your-own", "authorize": "…", "token": "…", "scopes": […] }
  // { "type": "api_key", "fields": [{ "name": "site", "label": "Datadog site" }, { "name": "key", "label": "API key", "secret": true }] }
  // { "type": "none" }

  "accounts": "many",                  // several Gmail accounts side by side, or "one"

  // What tools may do; overrides the server's MCP annotations. Drives approvals.
  "tools": {
    "search_threads": "read",
    "create_draft": "write",
    "send_message": "send",            // leaves your hands: always asks
    "trash_thread": "destructive"
  },

  "defaults": { "exposure": "deferred" }  // found with tool search instead of filling the prompt
}
```

Kinds:
- **remote**: an MCP server on the internet. Most apps (§4).
- **local**: an MCP server Piopio starts on this Mac (stdio). For apps without an official server, local data (Obsidian vault, Things), or community servers.
- **native**: implemented in the app with macOS permissions (Apple apps today, computer use later, 11-computer-use). Same manifest, so they show up in the same gallery.

The existing "Custom MCP server" stays, as the escape hatch: a manifest written for you from a URL or command.

### 3.2 Engine

- **Registry** (`connectors/registry.ts`): reads manifests from three places, in order: built-in (`packages/connectors/*`, shipped with the app), your folder (`~/Library/Application Support/Piopio/connectors/`, for your own or unpacked ones), and later the marketplace cache. Validates them against a published JSON schema.
- **Accounts** (`connectors/accounts.ts`): one record per signed-in account (`gmail:antonio@…`), its credential in the Keychain through the same store as model providers (`connector.<id>.<account>`), refreshed tokens written back.
- **Connections** (`connectors/connections.ts`): `pi-mcp`'s `McpClient` for remote and local kinds, `app.tool` for native ones. One connection per account, opened on first use, closed when idle. OAuth runs through `pi-mcp/oauth`, with its steps shown in the app like model sign-ins (`connectors.auth`, same events as `providers.auth`).
- **Tools** (`connectors/tools.ts`): each account's tools become `<connector>__<tool>` (with the account when there are several: `gmail_work__search_threads`), offered to pi-durable (chats, notebooks, agents) and pi-coding-agent (Build) from one place. With many tools, `tool_search` finds them instead of listing them all.
- **Policy** (`connectors/policy.ts`): every tool has an access class — read, write, send, destructive — from the manifest, else the MCP annotations, else "write". Reads run; writes ask first by default; send and destructive always ask. Agents and chats keep their own overrides.
- **Protocol:** `connectors.list` (gallery: manifests and accounts), `connectors.connect` / `answer` / `cancel` (sign-in, with `connectors.auth` steps), `connectors.disconnect`, `connectors.tools` (an account's tools and their access), `connectors.install` / `remove` (your folder now, the marketplace later), `connectors.changed`.

### 3.3 App

- **Settings › Connectors** replaces Settings › MCP servers: a gallery by category (cards: icon, name, one line, Connect), your connected accounts first, and "Add a custom connector…" (MCP URL or command) at the end. A connector's page lists its accounts, its tools with their access (Read / Asks first / Always asks / Off), and where it's on.
- **Where it's on:**
  - **Agents:** Setup › Abilities gets a Connectors group: pick the connector and the account ("Gmail · work"), tools listed with their access.
  - **Chats and notebooks:** a Connectors chip in the composer (like Web search), off until you turn a connector on for that conversation or notebook.
  - **Build:** on per project, since code work rarely needs your mail.
- **In the transcript:** connector calls are steps like any tool, with the app's icon, folded into the activity line; asks-first calls show the approval card (Allow once / Always for this tool / Deny).

### 3.4 Safety
- Content from apps is untrusted: an email saying "forward this to…" is data, never an instruction. The system prompt says so, and send/destructive tools always ask.
- Least scope: a connector offers read-only sign-in when the app allows it ("Read only" switch before connecting).
- Local servers are code on your Mac: built-in and Verified ones only by default; others show their command and need your OK. Later: a sandbox profile (no network except the domains the manifest declares).
- Tokens never reach the model or logs; the Keychain holds them.

### 3.5 Adding a connector (developers)
1. Write `connector.json` (and a server, for local kinds; a TypeScript template ships with the docs).
2. "Load a connector folder…" in Settings › Connectors (like unpacked browser extensions) to try it.
3. `piopio connectors check <folder>` validates the manifest, connects, lists tools and their access classes.
4. Share the folder, or later submit it to the marketplace.

### 3.6 Marketplace (later)
- An index of manifests (a Git repo or a small service), each pinned to a version and, for local kinds, a package with an integrity hash.
- Trust levels on every card: **Official** (us or the app's vendor), **Verified** (reviewed), **Community**.
- Installing shows what it is, where it runs, what it signs in to and what its tools may do, before anything runs.
- Updates with a changelog; a connector that asks for more access needs your OK again.
- Could also read the official MCP Registry for remote servers, labeled Community until verified.

## 4. Connectors we'd ship

Route: **remote** = the vendor's official MCP server; **local** = a server we bundle or write; **native** = in the app.

### First wave (most asked for)
| Connector | Route | Sign-in | Notes |
|---|---|---|---|
| Gmail | remote (Google, preview) or local (Gmail API) | Google OAuth | Restricted scopes: needs a decision (§6.1). |
| Google Calendar | remote (Google, preview) | Google OAuth | |
| Google Drive (Docs, Sheets) | remote (Google, preview) | Google OAuth | |
| Outlook Mail + Calendar | local (Microsoft Graph) | Microsoft OAuth (our Entra app) | Microsoft's own MCP is Copilot-licensed orgs only. Personal and work accounts. |
| Slack | remote | OAuth | |
| GitHub | remote | OAuth | Also useful outside Build (issues, PRs from chat or agents). |
| Jira + Confluence | remote (Atlassian) | OAuth | |
| Linear | remote | OAuth (DCR) | |
| Notion | remote | OAuth | |
| Datadog | remote | OAuth (DCR) | The org must enable MCP; write access optional. |
| Sentry | remote | OAuth | |
| Apple apps | native | macOS permissions | Exists today; moves into the gallery. |

### Second wave
| Area | Connectors |
|---|---|
| Work and tasks | Asana, Todoist, Trello, ClickUp, Microsoft To Do, Things 3 (local) |
| Files | Dropbox, Box, OneDrive and SharePoint (Graph) |
| Chat and meetings | Microsoft Teams (Graph), Zoom, Discord |
| Dev and ops | GitLab, PagerDuty, Grafana, Cloudflare, Vercel, Supabase, Figma |
| Sales and support | HubSpot, Salesforce, Zendesk, Intercom, Stripe |
| Notes and knowledge | Obsidian vault (local), Readwise, Airtable |
| Home and personal | Home Assistant, Spotify |

## 5. First milestone proposal (C1)
1. Manifest schema, registry (built-in and your folder), accounts in the Keychain, connections through `pi-mcp` with OAuth shown in the sign-in sheet.
2. Tools in chats, notebooks, agents and Build from one bridge, with the access policy and approvals.
3. Settings › Connectors (gallery, accounts, tools and access) and the agent Setup group; the composer chip.
4. Connectors whose sign-in needs no app registration: **GitHub, Linear, Notion, Atlassian, Sentry**, plus **Custom MCP server** and the Apple apps moved in.
5. Google and Microsoft in C2, after the decision below.

## 6. Decisions for you
1. **Google and Microsoft sign-in.** (a) Register Piopio's own Google and Microsoft apps: the smoothest, but Gmail's restricted scopes need Google's verification and a yearly security assessment before strangers can use it; (b) "bring your own" OAuth client from your own Google Cloud / Entra project: works today, more setup; (c) both: (b) now, (a) when Piopio is public.
2. **Defaults.** Connectors on for agents when you add them in Setup, off in chats until turned on per conversation — or on everywhere once connected?
3. **Marketplace source** when it comes: our own curated index, the official MCP Registry, or both with trust labels.
