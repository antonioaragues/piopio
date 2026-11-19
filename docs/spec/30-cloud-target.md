# 30 · The cloud, target state: where things run, and what they can do there

Status: draft 2026-11-19; **the six questions decided by the user the same day (§11)**; **K1 built the same day (§13)**,
checked in workerd (Miniflare) and the app build, not yet on the real account. Mockup: [docs/design/cloud](../design/cloud/Cloud.html).
It extends 13 (Phase 5 plan) with the two goals the user set, and with what a cloud agent can use:

1. **You choose where a conversation runs:** a chat, a notebook or a Build session runs on this Mac or in your cloud.
2. **Agents can run in the cloud:** an agent starts on the Mac, and you put it in the cloud when you want it always on
   (decided: This Mac by default, §3.3). The app shows and drives cloud agents like local ones.
3. **They can do real things there:** your services (connectors), the web (search, fetch, a browser), a cloud
   machine, and your Mac's apps when the Mac is on. Computer use from the cloud waits (§4.4).
4. **A Piopio app on your phone** shows the same conversations as the Mac: you read them, write in them, approve, and
   take over a hand-off there. Telegram, WhatsApp, Slack and the rest are **add-ons**: extra ways an agent can reach
   you or other people, not the way you use Piopio away from the Mac. (Added 2026-11-19, from the user.)

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

You use Piopio from **two apps**, the Mac app and the phone app, and both show the same conversations. Everything you
talk to has a **place**: This Mac or Cloud. The place decides two things only: whether it keeps going
when your Mac is off, and which of your things it can reach directly. What it *can do* is the same list everywhere
(§4), and each capability says where it really runs: on the Mac, in the cloud, or **through your Mac** (the Mac Bridge,
§5) when it needs something only the Mac has. When a capability can't be reached right now, the agent says so and
waits or asks, instead of the tool silently missing. Channels (Telegram, WhatsApp, Slack…) are optional, per agent,
for when you want an agent in a messaging app or reachable by other people.

## 3. Where things run

### 3.1 The choice

| Kind | This Mac | Cloud | Default |
|---|---|---|---|
| **Chat** (no project) | The local engine, as today | A conversation object in your Worker; reachable from the phone app | This Mac |
| **Notebook** | As today, with its files on the Mac | Its files in R2; the organizer runs in the cloud | This Mac |
| **Build session** | Your folder, or a separate copy (worktree) | A cloud machine (container) with the project's GitHub repo cloned; it works on a branch and ends in a PR | This Mac |
| **Agent** | The local engine | Its own `AgentDO`, always on | This Mac (§3.3) |
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

### 3.3 Agents start on the Mac; you put them in the cloud

**Decided (2026-11-19): new agents are made on this Mac**, even with a cloud connected. Connecting your cloud
(Settings › Cloud, 13 §5.2) is still one step with a screen that says what goes there (agents' conversations,
memory, channel messages, connector tokens), what it costs (the free plan to try; Workers Paid, $5 a month, for
daily use), and what you get (agents that answer and run with the Mac off). Then:
- The creation card's "Runs on" row (13b) says `This Mac`, and offers `Cloud` when a cloud is connected.
- An existing agent goes up with **Keep it always on** (grey 13a) in its info panel: "Move to cloud".
- Without a connected cloud, `Keep it always on` explains what it is and links to Settings › Cloud.

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
| **Computer use** (23) | One granted app, attended | **Later** | §4.4 |
| **Channels** (add-ons) | Telegram by polling | Telegram, WhatsApp, Slack… by webhook | Optional per agent; 13 §5.3, §5.5 |
| **Other agents** (`ask_agent`) | Yes | Yes, between objects; a cloud agent asks a Mac agent through the Mac | 13 §5.4 |

### 4.1 Your services: connectors in the cloud

- **Connect once, choose where:** Settings › Connectors › Google Calendar › Connect signs you in as today. When a cloud
  is connected, the sheet adds one line: `Also for cloud agents` (on by default for remote connectors). On, the cloud
  gets its **own** sign-in (OAuth with the callback at `https://<worker>/v1/oauth/callback`), so no token is copied
  off the Mac's Keychain. Tokens are stored encrypted with `MASTER_KEY` in the registry, refreshed there.
- **What's offered:** remote MCP servers (most services: Google, Notion, Linear, GitHub, Slack…) and the custom ones
  you add by URL. Local MCP servers (a process on the Mac) and Apple apps are reached through the Mac (§5).
- **Rules stay the same:** reading never asks; changing, sending and deleting ask, by the connector's marks (12 §4).
  From the cloud, the ask goes to Needs you in both apps (a notification on the phone), and to a channel as buttons
  only if the agent has one and you asked for it there; the first answer wins.
- **Plumbing:** the Agents SDK's MCP client (`addMcpServer`, OAuth with `authenticating` → `authUrl`), or pi-mcp in
  workerd if it runs there (to check). The tools reach `AgentCore` the same way pi-mcp's do on the Mac.

### 4.2 A browser in the cloud

- **Cloudflare Browser Run** (formerly Browser Rendering): a headless Chromium driven by Playwright from the agent's
  object. The model gets the same `browser_*` tools as on the Mac (22 §3), with the same page map, so its skills don't
  depend on where it runs.
- **Sign-ins and payments are hand-offs,** as on the Mac (22 §4.3): the agent stops and asks you to take over. In the
  cloud you take over in **Live View**, Browser Run's real-time view of the session, opened from the app (a pane like
  the Mac browser's), from Needs you, or from the phone app, where Live View opens full screen. The agent resumes when you hand back
  (Browser Run's structured hand-off).
- **Profiles:** one per agent, so a site you signed in to stays signed in for that agent. Whether Browser Run keeps
  cookies across sessions, and for how long, is not verified (§12); if it doesn't, the profile's cookies are saved
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

### 4.4 Computer use: later

**Decided (2026-11-19): not now.** Cloud agents and conversations don't get computer use in these phases, neither
through the Mac Bridge nor on a cloud desktop. The options, for when it comes back:
- **Through your Mac:** a cloud agent drives one of your Mac's apps over the Mac Bridge, attended, with 23's grants.
- **A cloud desktop:** a Linux desktop in a cloud machine, for what the cloud browser can't handle. Cloudflare
  deprecated the sandbox's built-in desktop, so we'd build it.

## 5. The Mac Bridge

The link that lets cloud work use what only your Mac has.

- **What it is:** when the app is open (or the engine runs in the menu bar), the local engine keeps one outbound
  WebSocket to the Worker (no port opened on the Mac). The Worker routes `app.tool` requests from cloud objects to it,
  the same reverse requests the Mac's own agents use (03 §3.12, 22 §8).
- **What goes through it:** Mac apps (Calendar, Reminders, Mail, Notes, Shortcuts), local MCP servers, files on the
  Mac you've granted, asking a Mac agent, and the phone app's requests for conversations that live on
  the Mac (§6).
- **When the Mac is off or asleep:** those tools stay listed with `needs your Mac`. A call returns at once with that,
  and the agent says so ("I'll add it to your calendar when your Mac is back on"), parks the step, and it runs on
  reconnect, or asks you. Nothing is queued silently for more than a day.
- **Who may use it:** your own cloud objects only (the Worker's owner token, plus a per-Mac key the app makes at
  connect). The grants are the Mac's: a cloud agent gets Calendar only if that agent has Calendar on.
- **Status:** Settings › Cloud and the sidebar footer (`This Mac · reachable from the cloud`).

## 6. The Piopio app on your phone

The second client, not a channel. It shows what the Mac app shows, sized for a phone.

- **What's in it:** Home (what needs you, what's running), your agents, chats, notebooks and projects' sessions, each
  conversation as on the Mac: the transcript, processing lines, visuals, approvals in the composer tray.
- **What it can reach:**
  - **Cloud items, always.** The phone talks to your Worker's gateway directly, so they're live with the Mac off.
  - **Mac items, while the Mac is on,** through the Mac Bridge (§5): the gateway relays the phone's requests to the
    Mac's engine. With the Mac off they show their last state, read-only, with `On your Mac · off`, and "Move to cloud"
    is offered for a chat (it moves when the Mac is back) or "Continue in cloud" for a Build session with a branch.
- **What you do there:** write, start a new chat (in the cloud by default from the phone), approve or deny, answer an
  agent's question, take over a hand-off (Live View full screen), stop a run, read a diff and merge a PR.
- **Notifications:** what needs you and what an agent sends you on its own arrive as push notifications, sent by the
  Worker through Apple's push service. An approval can be answered from the notification itself.
- **Sign-in:** pair the phone from the Mac (Settings › Cloud › Add a phone shows a QR code). The phone gets its own
  device token, which you can revoke; the owner token never leaves the Mac.
- **Built with:** SwiftUI, sharing the Mac app's models, protocol client and transcript views; the Engine Protocol over
  the same gateway socket.
- **Without a cloud:** the phone app needs one (it's the always-on part); before you connect it, it says what it's
  for and how to connect from the Mac.

## 7. What you see

- **Badges, not colors:** a small `cloud` glyph in `fg2` next to cloud agents and conversations in the sidebar
  (grey's "no decoration" holds: no chips). Toolbar subtitle: `Cloud · keeps going with your Mac off`.
- **Composer:** the location chip (§3.1).
- **Agent info panel (13a):** footer `Haiku 5.5 · Cloud · $0.31 this month`; the **Can** list shows each capability
  with where it runs when it isn't plain (`Calendar · through your Mac`, `Browser · cloud browser`), and a grey
  `needs your Mac` while the Mac is away.
- **Settings › Cloud:** the account and Worker, the Mac Bridge's state, usage this month (requests, duration, browser
  hours, machine time, models), the agents and conversations up there, Disconnect.
- **Needs you:** approvals and hand-offs from the cloud, with where they come from, in both apps.
- **Channels, when an agent has one:** approvals as buttons (Approve / Deny) there too, if you choose; never instead
  of the app.

## 8. Under the hood

- **One socket per app:** `GET /v1/ws` goes to a gateway (the Worker plus `RegistryDO`) that fans out to objects
  over RPC (13's open item), instead of one socket per agent.
- **CloudLink in the local engine:** the app keeps talking to its local engine only; the engine relays `sessions.*`
  for cloud refs (`location: "cloud"` on the ref) to the gateway, and merges the lists. The app needs no second
  connection, and works offline with the cloud's items marked unreachable.
- **The phone app** connects to the gateway directly with its device token. Requests for Mac items are relayed over the
  Mac Bridge; the gateway knows which items live where from the registry.
- **Push:** an APNs key (from your Apple developer account) is a Worker secret; the registry keeps each phone's push
  token. Notifications carry a title and a short line, not the conversation.
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

## 9. Security and data

- **Your account, your data:** everything in the cloud is in your Cloudflare account. Model calls go from Cloudflare
  to the provider, as they go from the Mac today.
- **Doors:** the owner token for the Mac app and the Mac Bridge; a revocable device token per phone; channel webhooks by their own secrets; OAuth callbacks by
  state; nothing else open (as built).
- **Secrets:** Worker secrets for `OWNER_TOKEN`, `MASTER_KEY` and model keys; connector and channel tokens encrypted
  with `MASTER_KEY` in the registry, never in transcripts (the Telegram token interception is the pattern).
- **What pages and tool results say is data** (22 §4.5): the same rule and prompt in the cloud.
- **Leaving:** Disconnect offers "Bring everything back to this Mac" before deleting the Worker's data.

## 10. Phases

Decided order (2026-11-19): chats in the cloud before the phone app, so the phone has agents and chats to show from
its first day.

| Phase | What | Shows it works |
|---|---|---|
| **K0** · done | One agent in a Durable Object, Telegram by webhook, reminders with the Mac off | `trial` on the account |
| **K1** · agents from the Mac app | Settings › Cloud connect and deploy (13 5.2), `RegistryDO`, the gateway, CloudLink, badges; Keep it always on / Move to this Mac; Cloud in the creation card | An agent made on the Mac and moved up runs its automations with the Mac off, and its conversation shows in the Mac app |
| **K2** · chats in the cloud | `ConversationDO`, the location chip for chats and notebooks, Move to cloud / Bring back | A chat started in the cloud keeps answering automations and messages with the Mac off |
| **K3** · the phone app (iPhone) | Pairing by QR, device tokens, Home and the conversation list, the transcript, the composer and its tray (approvals, questions), push notifications | With the Mac off, you write to a cloud agent and a cloud chat from the phone, and a reminder arrives as a notification |
| **K4** · capabilities anywhere | Web search and fetch, remote connectors signed in from the Worker (OAuth), tools with `where` | "What's on my calendar tomorrow?" from the phone, answered from Google Calendar, with the Mac off |
| **K5** · the Mac Bridge | The outbound socket, Mac apps and local MCP through it, `needs your Mac`; the phone sees Mac items through it | A cloud agent adds an Apple Reminder while the Mac is on, and says it will when it's off; the phone opens a Mac chat |
| **K6** · the cloud browser | Browser Run, the same `browser_*` tools, Live View hand-offs (Mac app and phone app), profiles | An agent checks an order on a site you signed in to from your phone |
| **K7** · Build in the cloud | Containers, clone from GitHub, branch, PR; Continue in cloud / here | A Build session started at the Mac finishes in the cloud and opens a PR |
| **Channels** (add-ons, any time after K1) | Telegram's approval buttons and `/pause`; WhatsApp (13 5.5); Slack; email | An agent other people write to on WhatsApp or Slack |
| **Later** | Computer use from the cloud (§4.4); a web app over the same gateway | |

K1 makes "agents can run in the cloud" true, K2 and K7 make "choose where a session runs" true, and K3 makes all of
it usable away from the Mac. Channels are independent of the rest.

## 11. Decisions (2026-11-19)

| ID | Decision |
|---|---|
| CT1 | **New agents start on this Mac**, even with a cloud connected. Cloud is a choice in the creation card and Keep it always on in the info panel (§3.3). |
| CT2 | **Connectors sign in separately for the cloud** (OAuth back to the Worker); nothing is copied from the Mac's Keychain (§4.1). |
| CT3 | **Build in the cloud needs a GitHub repo**: clone, branch, PR. Projects without one stay on the Mac (§4.3). |
| CT4 | **Computer use from the cloud waits** for a later phase, in either form (§4.4). |
| CT5 | **Order:** agents from the Mac app, chats in the cloud, then the phone app; then capabilities, the Mac Bridge, the cloud browser, Build (§10). |
| CT6 | **The phone app is iPhone only** (SwiftUI, shared with the Mac app); a web app is Later. Push needs an Apple developer account and its APNs key. |

## 12. Not verified

- Whether Browser Run keeps cookies across sessions, and its current paid limits (sources disagree).
- Containers' current instance sizes and rates (sources disagree); the Sandbox SDK 1.0's git API (it changed).
- Whether pi-mcp's client runs in workerd, or the Agents SDK's MCP client is needed.
- pi-coding-agent inside a container, driven from a Durable Object, with its events relayed.
- What resting saves on Durable Object billing (13's open item).
- How much of the Mac app's SwiftUI (transcript, composer, models) builds for iOS as is.

Sources (read 2026-11-19): [Browser Run changelog](https://developers.cloudflare.com/changelog/product/browser-run/),
[Live View](https://developers.cloudflare.com/browser-run/features/live-view/),
[Human in the loop](https://developers.cloudflare.com/browser-run/features/human-in-the-loop),
[Sandboxes changelog](https://developers.cloudflare.com/changelog/product/sandbox/) (desktop deprecated),
[Containers pricing](https://developers.cloudflare.com/containers/pricing/),
[Sandbox git workflows](https://developers.cloudflare.com/sandbox/guides/git-workflows/),
[Agents SDK MCP client](https://developers.cloudflare.com/agents/api-reference/mcp-client-api),
[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

## 13. K1 as built (2026-11-19)

An agent made on the Mac goes up to your cloud and comes back, and its conversation shows in the Mac app while it's
there. Checked in workerd (Miniflare) with the real engine from source and the faux model; the app builds. **Not yet
on the account:** the Worker there predates K1 and needs a redeploy (`node scripts/deploy.ts`, which adds the
registry's migration `v1 → v2`).

**What you do**
- **Settings › This Mac & cloud › Cloud › Connect…**: the Worker's address and owner token (kept in the Keychain).
  Both are checked before anything is saved (`/v1/health`, then `/v1/agents` with the token). The card then shows
  whether it answers, its version and the agents up there; **Disconnect** is refused while an agent runs there.
- **An agent's ⋯ menu › Keep It Always On…** (or **Move to This Mac…**), with a confirmation that says what moves.
  Without a cloud, it explains and opens Settings. The result says what moved and what didn't, in lines.
- **New agent › Runs on**: `This Mac` or `Cloud` once a cloud is connected. It's made on the Mac and sent up (CT1).
- **Badges:** a `cloud` glyph by the name in the sidebar, the Agents list and the agent's header, and "Cloud" in its
  line under the name.

**What moves, up**
- The definition and instructions, as data (`agents.deploy`; no Worker redeploy). A model the cloud can't reach (a
  subscription, a local server, an API-key provider other than OpenRouter) becomes the Worker's default, and the line
  says so; the Mac's copy of the definition is changed to match.
- Its **time automations** become the cloud definition's schedules (cron) and reminders (once). Ones that watch a
  folder, your email or a URL, and ones that are off, **stay on the Mac, off** (kept in its catalog entry) and come
  back with it.
- **Memory** from the built-in provider, every partition; the Mac's copy is wiped once the cloud has it. Another
  provider's memory doesn't move (the line says so).
- **Telegram:** the bot token goes up and the cloud sets its webhook; the Mac stops polling that bot. The owner's chat
  id is in the definition, so pairing carries over.

**What moves, back**
- `agents.export` (read only) → the Mac saves the definition (without schedules), memory and the bot token, turns
  the cloud's schedules and reminders into automations again (27's migration), and adds back what was parked. Then
  `agents.retire` stops the webhook, removes it from the registry and deletes its data there.
- **Its conversations from the cloud are not merged** into the Mac's: each person's is saved as Markdown in the agent's
  folder (`cloud-conversations/`), and the Mac shows the conversation it had before it went up.

**How it's wired**
- **Worker:** `RegistryDO` (one object, `registry`) lists the agents; `GET /v1/agents` reads it (owner only).
  `AgentDO` answers `agents.deploy`, `agents.export`, `agents.retire` and `agents.conversations`. A retired object keeps
  only a marker and refuses everything until it's deployed again. A deploy without `schedules` keeps the ones the
  cloud has, so editing the definition on the Mac doesn't drop them.
- **Engine:** `CloudLink` (`packages/engine/src/cloud.ts`) with one socket **per cloud agent**, opened on use and
  reopened after a drop (the open conversations subscribe again and send a fresh snapshot). A cloud agent's catalog
  entry has `cloud`; `sessions.*` for it go to `CloudAgentView`, which keeps the cloud's snapshot in step. Runs,
  conversations, definition edits, Run now, pause, approvals and Undo are forwarded (the same methods, on its
  socket); the Inbox merges the cloud agents' own. Their status (paused, spend, Inbox count, next run) is read every
  minute and after anything you do to them, and an approval they ask for notifies once. The trace and memory views
  aren't forwarded yet.
- **Decided while building:** the gateway with one socket for everything (§8) waits for K3, where the phone needs it;
  for the Mac's engine, one socket per agent is simpler and enough.

**Added the same evening:** Run now, pause and resume, approvals, Undo, the Inbox, and spend against the budget for
cloud agents (`agents.runNow`, `pause`, `decide`, `undo`, `status`, `inbox.list`, `inbox.read` on the object).
Automations: Automations refuses a new one for a cloud agent (or turning one on, or changing its trigger) and says to
ask the agent, which keeps its own up there as schedules and reminders. Run now and pause are checked in workerd; an
approval is not (the test model can't call a tool), only that `agents.decide` reaches the object.

**Not in K1 (next)**
- A cloud agent's approval card in its chat (it shows in Needs you, not in the transcript: the cloud's timeline
  doesn't draw approval items yet); its memory view and the trace.
- Connect by Cloudflare API token, with the app deploying the bundled Worker (13 §5.2's setup). Today the Worker is
  deployed with `scripts/deploy.ts` and connected by address and token.
- The definition the cloud agent changes itself (its interview, a Telegram pairing) shows on the Mac only when it moves
  back; an edit on the Mac in between replaces it.
- Attachments in a cloud agent's chat.
