# 30 · The cloud, target state: where things run, and what they can do there

Status: draft for review, 2026-11-19. Nothing here is decided. Mockup: [docs/design/cloud](../design/cloud/Cloud.html).
It extends 13 (Phase 5 plan) with the two goals the user set, and with what a cloud agent can use:

1. **You choose where a conversation runs:** a chat, a notebook or a Build session runs on this Mac or in your cloud.
2. **Agents run in the cloud:** once your cloud is connected, the agents you create live there, and the app shows
   and drives them like local ones.
3. **They can do real things there:** your services (connectors), the web (search, fetch, a browser), a computer, and
   your Mac's apps when the Mac is on.

It resolves roadmap Q4 ("Where things run") and picks up 05 §"Cloud build sessions", 04's "Move to cloud", 18 CF7
(the location chip), 22 and 23 (browser and computer use) for the cloud, and 02 §5 (the Worker's topology).

## 1. What exists today (2026-11-19)

- **The Worker on a real account:** `piopio-cloud` with one `AgentDO` per agent, running `AgentCore` from
  `@piopio/runtime`: memory, reminders, messages, budget, `/pause`, owner token at the door (packages/cloud README).
- **One agent, `trial`,** made by hand from the personal-assistant template. It answers on Telegram by webhook, and
  its reminders reach the phone with the Mac off.
- **Its tools:** memory, `send_message`, schedules. No connectors, no web, no browser, no Mac apps, no `watch`.
- **Not built:** deploy from the app, the app showing cloud agents, a registry of agents, chats or Build in the cloud.

## 2. The idea in one paragraph

Everything you talk to has a **place**: This Mac or Cloud. The place decides two things only: whether it keeps going
when your Mac is off, and which of your things it can reach directly. What it *can do* is the same list everywhere
(§4), and each capability says where it really runs: on the Mac, in the cloud, or **through your Mac** (the Mac Bridge,
§5) when it needs something only the Mac has. When a capability can't be reached right now, the agent says so and
waits or asks, instead of the tool silently missing.

## 3. Where things run

### 3.1 The choice

| Kind | This Mac | Cloud | Default |
|---|---|---|---|
| **Chat** (no project) | The local engine, as today | A conversation object in your Worker; reachable from Telegram and, later, the iOS app | This Mac |
| **Notebook** | As today, with its files on the Mac | Its files in R2; the organizer runs in the cloud | This Mac |
| **Build session** | Your folder, or a separate copy (worktree) | A cloud machine (container) with the project's GitHub repo cloned; it works on a branch and ends in a PR | This Mac |
| **Agent** | The local engine | Its own `AgentDO`, always on | **Cloud**, once your cloud is connected (§3.3) |
| **Automation** (27) | Runs where its owner runs | Same: an agent's in its place; Piopio's in a project on the Mac, or in a cloud session when the project has a repo | Its owner's place |

**Where you pick it:** the composer's location chip (18 CF7), plain text like the other selectors: `This Mac` or
`Cloud`. Its menu says in one line what each means ("Keeps going with your Mac off. Can't open files on this Mac.").
For Build, the same chip offers `This Mac · Separate copy · Cloud`; Cloud is offered only when the project has a
GitHub remote, and the line says which repo and branch it starts from. The chip is hidden until a cloud is connected.

### 3.2 Moving something that already runs

- **A chat:** "Move to cloud" in the conversation's menu copies the transcript and memory up and marks the local copy
  moved (read-only, with a link). "Bring back to this Mac" does the reverse. No running turn moves: the move waits for
  the turn to end.
- **A Build session:** "Continue in cloud" commits the work in progress to a branch (`piopio/<session>`), pushes it, and
  starts the cloud session on that branch with the same conversation. "Continue here" fetches the branch into a
  worktree. Uncommitted, unpushable changes block the move and say why.
- **An agent:** "Move to cloud" / "Move to this Mac" in the info panel's footer (grey 13a's `Keep it always on`):
  definition, instructions, memory, automations and channels move; Telegram's webhook is re-pointed (the cloud reads
  by webhook, the Mac by polling, never both).

### 3.3 Agents live in the cloud: the opt-in is connecting it

The local-by-default rule says a feature that adds a new place for your data is opt-in. Here the opt-in is
**connecting your cloud** (Settings › Cloud, 13 §5.2), once, with a screen that says what goes there (agents'
conversations, memory, channel messages, connector tokens), what it costs (the free plan to try; Workers Paid, $5 a
month, for daily use), and what you get (agents that answer and run with the Mac off). After that, new agents are made
in the cloud, and the creation card's "Runs on" row (13b) says `Cloud`, changeable to `This Mac`. Without a connected
cloud, nothing changes: agents run on the Mac and the row says `This Mac · Keep it always on`.

## 4. What a cloud agent or conversation can do

One list of capabilities for every place. Each one says where it runs; the agent is told the same, so it never
promises what it can't do (the `watch` fix of 2026-11-19 is the first case of this rule).

| Capability | On the Mac | In the cloud | Notes |
|---|---|---|---|
| **Models** | Every provider, subscription sign-ins included | API-key providers (OpenRouter, Anthropic, OpenAI…), from the Worker's secrets | 29's provider order applies in both; subscriptions stay on the Mac |
| **Memory, automations, messages** | Yes | Yes | Cloud automations fire from the object's alarm |
| **Web search and fetch** | Yes | Yes | The provider's search (OpenRouter's web plugin) or a search connector; `web_fetch` is a plain `fetch` from the Worker |
| **Your services** (connectors, 12) | Local MCP servers and remote ones | **Remote MCP servers**, signed in by OAuth with the callback on your Worker | §4.1 |
| **A browser** | The built-in WebKit browser (22) | **A cloud browser** (Cloudflare Browser Run) | §4.2 |
| **Code, files, scripts** | The project folder, the shell | **A cloud machine** (container) on demand, with a workspace in R2 | §4.3 |
| **Mac apps** (Calendar, Reminders, Mail, Notes, Shortcuts) | Yes | **Through your Mac**, when it's on | §5 |
| **Computer use** (23) | One granted app, attended | **Through your Mac**, attended only | §4.4 |
| **Channels** | Telegram by polling | Telegram and WhatsApp by webhook | 13 §5.3, §5.5 |
| **Other agents** (`ask_agent`) | Yes | Yes, between objects; a cloud agent asks a Mac agent through the Mac | 13 §5.4 |

### 4.1 Your services: connectors in the cloud

- **Connect once, choose where:** Settings › Connectors › Google Calendar › Connect signs you in as today. When a cloud
  is connected, the sheet adds one line: `Also for cloud agents` (on by default for remote connectors). On, the cloud
  gets its **own** sign-in (OAuth with the callback at `https://<worker>/v1/oauth/callback`), so no token is copied
  off the Mac's Keychain. Tokens are stored encrypted with `MASTER_KEY` in the registry, refreshed there.
- **What's offered:** remote MCP servers (most services: Google, Notion, Linear, GitHub, Slack…) and the custom ones
  you add by URL. Local MCP servers (a process on the Mac) and Apple apps are reached through the Mac (§5).
- **Rules stay the same:** reading never asks; changing, sending and deleting ask, by the connector's marks (12 §4).
  From the cloud, the ask goes to the app's Needs you **and** to Telegram as buttons; the first answer wins.
- **Plumbing:** the Agents SDK's MCP client (`addMcpServer`, OAuth with `authenticating` → `authUrl`), or pi-mcp in
  workerd if it runs there (to check). The tools reach `AgentCore` the same way pi-mcp's do on the Mac.

### 4.2 A browser in the cloud

- **Cloudflare Browser Run** (formerly Browser Rendering): a headless Chromium driven by Playwright from the agent's
  object. The model gets the same `browser_*` tools as on the Mac (22 §3), with the same page map, so its skills don't
  depend on where it runs.
- **Sign-ins and payments are hand-offs,** as on the Mac (22 §4.3): the agent stops and asks you to take over. In the
  cloud you take over in **Live View**, Browser Run's real-time view of the session, opened from the app (a pane like
  the Mac browser's), from Needs you, or from a Telegram button on your phone. The agent resumes when you hand back
  (Browser Run's structured hand-off).
- **Profiles:** one per agent, so a site you signed in to stays signed in for that agent. Whether Browser Run keeps
  cookies across sessions, and for how long, is not verified (§10); if it doesn't, the profile's cookies are saved
  in the agent's storage, encrypted, and restored at the start of a session.
- **Levels per site** (22 §4.4) are decided by the engine, so they're the same in the cloud.
- **Cost:** browser hours. Workers Paid includes 10 hours a month, then about $0.09 an hour (third-party figure, to
  check); a session closes after 60 s idle unless kept alive. Settings › Cloud shows the hours used.

### 4.3 A cloud machine: code, files, Build

- **One container per session that needs it,** started on demand with the Sandbox SDK from the session's object:
  a shell, files, git, the language toolchains in the image. It sleeps when idle and **its disk is fresh after
  sleep**, so work lives in git (Build) or in R2 (a notebook's or an agent's workspace), never only on the machine.
- **Build in the cloud:** the session clones the repo (a GitHub token from the GitHub connector), works on its branch,
  runs the checks, commits and pushes, and opens a PR. The conversation, diffs, approvals and review work as in Build
  today; "Open in Zed" becomes "Continue here".
- **For agents and chats:** the `code` capability (run a script, make a chart from a CSV, convert a file) uses the
  same machine with an R2 workspace. Without it, codemode (sandboxed JS in the Worker) covers small things.
- **Cost:** CPU and memory per 10 ms while awake (Workers Paid includes some). The session's footer shows it.

### 4.4 Computer use: through your Mac, not a cloud desktop

Computer use is for **your** apps on **your** Mac (23), attended. A Linux desktop in a container would give an agent
a computer, but not yours, and Cloudflare deprecated the sandbox's built-in desktop. So:
- A cloud agent or conversation asks for computer use **through the Mac Bridge**, with the same grants and levels.
  You see it on the Mac as you do today; if you're not at the Mac, the request waits in Needs you.
- A cloud desktop (for a site the cloud browser can't handle, or a Linux app) goes to Later.

## 5. The Mac Bridge

The link that lets cloud work use what only your Mac has.

- **What it is:** when the app is open (or the engine runs in the menu bar), the local engine keeps one outbound
  WebSocket to the Worker (no port opened on the Mac). The Worker routes `app.tool` requests from cloud objects to it,
  the same reverse requests the Mac's own agents use (03 §3.12, 22 §8).
- **What goes through it:** Mac apps (Calendar, Reminders, Mail, Notes, Shortcuts), local MCP servers, files on the
  Mac you've granted, computer use, and asking a Mac agent.
- **When the Mac is off or asleep:** those tools stay listed with `needs your Mac`. A call returns at once with that,
  and the agent says so ("I'll add it to your calendar when your Mac is back on"), parks the step, and it runs on
  reconnect, or asks you. Nothing is queued silently for more than a day.
- **Who may use it:** your own cloud objects only (the Worker's owner token, plus a per-Mac key the app makes at
  connect). The grants are the Mac's: a cloud agent gets Calendar only if that agent has Calendar on.
- **Status:** Settings › Cloud and the sidebar footer (`This Mac · reachable from the cloud`).

## 6. What you see

- **Badges, not colors:** a small `cloud` glyph in `fg2` next to cloud agents and conversations in the sidebar
  (grey's "no decoration" holds: no chips). Toolbar subtitle: `Cloud · keeps going with your Mac off`.
- **Composer:** the location chip (§3.1).
- **Agent info panel (13a):** footer `Haiku 5.5 · Cloud · $0.31 this month`; the **Can** list shows each capability
  with where it runs when it isn't plain (`Calendar · through your Mac`, `Browser · cloud browser`), and a grey
  `needs your Mac` while the Mac is away.
- **Settings › Cloud:** the account and Worker, the Mac Bridge's state, usage this month (requests, duration, browser
  hours, machine time, models), the agents and conversations up there, Disconnect.
- **Needs you:** approvals and hand-offs from the cloud, with where they come from. Each also goes to Telegram.
- **Telegram:** approvals as buttons (Approve / Deny), a hand-off as a button that opens Live View on the phone.

## 7. Under the hood

- **One socket for the app:** `GET /v1/ws` goes to a gateway (the Worker plus `RegistryDO`) that fans out to objects
  over RPC (13's open item), instead of one socket per agent.
- **CloudLink in the local engine:** the app keeps talking to its local engine only; the engine relays `sessions.*`
  for cloud refs (`location: "cloud"` on the ref) to the gateway, and merges the lists. The app needs no second
  connection, and works offline with the cloud's items marked unreachable.
- **Objects:**
  - `RegistryDO`: agents and their definition versions, cloud conversations, routing (bots, numbers), connector
    tokens and channel credentials (encrypted), deploy history, the Mac Bridge's connection.
  - `AgentDO`: as built.
  - `ConversationDO`: a cloud chat or notebook, a pi-durable session like the Mac's chats, with no agent around it.
  - `SessionDO` + container: a cloud Build session (pi-coding-agent in the container, its events relayed by the DO).
- **Bindings:** `BROWSER` (Browser Run), `SANDBOX` (containers), `FILES` (R2).
- **The timeline:** moves into `@piopio/runtime` (13's open item), so the Mac and the cloud draw the same items.
- **Tools say where they run:** each tool gets a `where: "anywhere" | "mac" | "cloud"` and `engine.hello` reports what a
  host serves; `AgentCore` offers a tool only where it can run or reach it, and marks bridge tools `needs your Mac`
  when the bridge is down.

## 8. Security and data

- **Your account, your data:** everything in the cloud is in your Cloudflare account. Model calls go from Cloudflare
  to the provider, as they go from the Mac today.
- **Doors:** the owner token for the app and the Mac Bridge; channel webhooks by their own secrets; OAuth callbacks by
  state; nothing else open (as built).
- **Secrets:** Worker secrets for `OWNER_TOKEN`, `MASTER_KEY` and model keys; connector and channel tokens encrypted
  with `MASTER_KEY` in the registry, never in transcripts (the Telegram token interception is the pattern).
- **What pages and tool results say is data** (22 §4.5): the same rule and prompt in the cloud.
- **Leaving:** Disconnect offers "Bring everything back to this Mac" before deleting the Worker's data.

## 9. Phases

| Phase | What | Shows it works |
|---|---|---|
| **K0** · done | One agent in a Durable Object, Telegram by webhook, reminders with the Mac off | `trial` on the account |
| **K1** · agents from the app | Settings › Cloud connect and deploy (13 5.2), `RegistryDO`, the gateway, CloudLink, badges; new agents in the cloud; Move to cloud / this Mac | An agent made in the app answers on Telegram with the Mac off, and its chat shows in the app |
| **K2** · capabilities anywhere | Web search and fetch, remote connectors with OAuth from the Worker, approvals as Telegram buttons, tools with `where` | "What's on my calendar tomorrow?" on Telegram, answered from Google Calendar, with the Mac off |
| **K3** · the Mac Bridge | The outbound socket, Mac apps and local MCP through it, `needs your Mac` | A cloud agent adds an Apple Reminder while the Mac is on, and says it will when it's off |
| **K4** · chats in the cloud | `ConversationDO`, the location chip for chats and notebooks, Move to cloud | A chat started on the Mac continues from Telegram with the Mac off |
| **K5** · the cloud browser | Browser Run, the same `browser_*` tools, Live View hand-offs (app and phone), profiles | An agent checks an order on a site you signed in to from your phone |
| **K6** · Build in the cloud | Containers, clone, branch, PR; Continue in cloud / here | A Build session started at the Mac finishes in the cloud and opens a PR |
| **Later** | A cloud desktop; the iOS app over the same gateway; WhatsApp (13 5.5) | |

K1 and K2 are what make "agents run in the cloud" true. K4 and K6 make "choose where a session runs" true.

## 10. Questions for you

1. **New agents in the cloud by default once it's connected** (§3.3)? Or ask at creation each time?
2. **Connector sign-ins:** a separate sign-in for the cloud (proposed, nothing leaves the Keychain), or copy the Mac's
   tokens up once?
3. **Build in the cloud needs GitHub** (a remote to clone and a branch to push). Fine as a requirement?
4. **Computer use only through your Mac** (§4.4), with a cloud desktop in Later?
5. **The order of the phases:** K1 → K2 → K3 → K4 → K5 → K6 as proposed, or chats in the cloud (K4) earlier?

## 11. Not verified

- Whether Browser Run keeps cookies across sessions, and its current paid limits (sources disagree).
- Containers' current instance sizes and rates (sources disagree); the Sandbox SDK 1.0's git API (it changed).
- Whether pi-mcp's client runs in workerd, or the Agents SDK's MCP client is needed.
- pi-coding-agent inside a container, driven from a Durable Object, with its events relayed.
- What resting saves on Durable Object billing (13's open item).

Sources (read 2026-11-19): [Browser Run changelog](https://developers.cloudflare.com/changelog/product/browser-run/),
[Live View](https://developers.cloudflare.com/browser-run/features/live-view/),
[Human in the loop](https://developers.cloudflare.com/browser-run/features/human-in-the-loop),
[Sandboxes changelog](https://developers.cloudflare.com/changelog/product/sandbox/) (desktop deprecated),
[Containers pricing](https://developers.cloudflare.com/containers/pricing/),
[Sandbox git workflows](https://developers.cloudflare.com/sandbox/guides/git-workflows/),
[Agents SDK MCP client](https://developers.cloudflare.com/agents/api-reference/mcp-client-api),
[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).
