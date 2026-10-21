# 06 — Agents mode

Personal agents that are **proactive**, **live inside your messaging apps**, **run on schedules**, and **talk to each other** (decision A1). Authored on the Mac, running 24/7 on the user's Cloudflare account.

## 1. Concepts

```
Agent ── Definition (versioned)
  ├─ Persona & instructions
  ├─ Model(s), budget
  ├─ Tools: built-ins · MCP (remote) · HTTP · codemode · other agents
  ├─ Memory (agent-wide + per contact)
  ├─ Contacts (owner + allowlist) ── Channels (In-app, Telegram, WhatsApp)
  ├─ Schedules (cron / one-off) · Heartbeat · Triggers (webhooks)
  └─ Policies: quiet hours, outbound limits, approvals
```

## 2. Agent Definition

A folder that is a git repo (auto-committed on every save → history, diff, rollback):

```
~/Piopio/Agents/coach/
├─ agent.json          # structured config (schema below)
├─ instructions.md     # persona + behavior (system prompt section)
├─ skills/             # optional skills (SKILL.md format)
└─ knowledge/          # optional files (uploaded to R2 on deploy)
```

```jsonc
// agent.json (schema v1)
{
  "id": "agt_01J…", "slug": "coach", "name": "Coach", "avatar": "🏋️",
  "models": { "default": "anthropic/claude-sonnet-x", "utility": "google/gemini-flash-x" },
  "thinking": "low",
  "tools": {
    "builtin": ["web_search", "web_fetch", "memory", "schedule", "send_message", "http_request", "codemode", "files"],
    "mcp": [{ "name": "strava", "url": "https://…/mcp", "auth": "secret:STRAVA_MCP_TOKEN" }],
    "agents": ["agt_nutrition"]          // agents this one may contact
  },
  "contacts": [
    { "id": "owner", "name": "Antonio", "role": "owner",
      "channels": { "telegram": "123456789", "whatsapp": "+34…" }, "preferred": "telegram" },
    { "id": "c_maria", "name": "María", "role": "contact", "channels": { "whatsapp": "+34…" } }
  ],
  "channels": { "telegram": { "bot": "secret:TG_COACH_TOKEN" }, "whatsapp": { "phoneNumberId": "…", "token": "secret:WA_TOKEN" } },
  "schedules": [
    { "id": "morning", "cron": "0 8 * * 1-5", "tz": "Europe/Madrid",
      "prompt": "Plan today's training given yesterday's log.", "deliverTo": "owner" }
  ],
  "heartbeat": { "every": "4h", "activeHours": "08:00-22:00", "prompt": "Anything worth telling the owner now?" },
  "triggers": [{ "id": "strava", "type": "webhook", "prompt": "New activity: {{body}}" }],
  "policies": {
    "quietHours": "22:30-07:30", "urgentBypassesQuiet": false,
    "maxOutboundPerDay": 20, "maxOutboundPerContactPerDay": 5, "budgetUsdPerMonth": 15,
    "requireApproval": ["send_message:to_non_owner", "http_request:POST", "mcp:*:write"],
    "unknownSenders": "ignore" // ignore | reply_canned | ask_owner
  }
}
```

- **AD1** Two ways to author, both writing the same files: a **form editor** (tabs: Persona, Model, Tools, Contacts, Channels, Schedules, Policies), and the **Agent Builder** (a chat with a built-in agent that edits the definition through tools and shows a diff before applying).
- **AD2** Secrets are referenced as `secret:NAME` and never stored in the folder. Values live in Keychain locally and in encrypted storage in the cloud.
- **AD3** Validation on save (JSON Schema + semantic checks: cron syntax, contact channel IDs, referenced agents exist). Errors show inline.
- **AD4** Templates: "Personal assistant", "Daily briefing", "Habit coach", "Family helper", "Research watcher".

## 3. Runtime (shared Node/Workers code in `@piopio/runtime`)

One agent = **one pi-durable session**. Local dev: Node SQLite. Cloud: `AgentDO` + `PiHarness`.

| Conversation | Ownership | Purpose |
|---|---|---|
| `person:<contactId>` | ownerless | **One conversation per person, unified across channels.** A message from the owner on Telegram, WhatsApp or in-app goes to the same conversation. Replies go back through the channel the message came from. |
| `agent:<agentId>` | ownerless | Incoming agent-to-agent conversation with that peer |
| `run:<runId>` | task | Scheduled runs, heartbeats, triggers. Each run has its own conversation, so runs don't pollute personal chats. The run decides whether to message someone. |
| `builder` | ownerless | (local only) the Agent Builder chat |

Custom docs:
- `piopio.agent-memory` (session scope, rewindable): agent-wide memory, **partitioned**: `owner`, `shared`, `contacts/<id>`. A conversation only sees `shared` + its own partition (+ `owner` if the person is the owner). This is how contacts stay isolated.
- `piopio.agent-state`: outbound counters, quiet-hour queue, budget usage, schedule cursor.

Custom entries: `piopio.channel-in` / `piopio.channel-out` (delivery metadata), `piopio.agent-msg`.

## 4. Built-in tools

| Tool | Behavior |
|---|---|
| `send_message(to, text, attachments?, channel?)` | Proactive or cross-person messaging. `to` = contact id or `owner`. Respects quiet hours (queues), outbound limits, approval policy. |
| `schedule(when, prompt, deliverTo?)` / `list_schedules` / `cancel_schedule` | One-off and recurring reminders created by the agent ("remind me Thursday at 9"). Durable tasks with `sleepUntil`. |
| `remember(partition, fact)` / `recall(query)` / `forget(id)` | Memory operations. Every write shows up in the app's memory view with provenance. |
| `ask_agent(agentId, message)` → reply | Synchronous-style delegation (§7). |
| `tell_agent(agentId, message)` | Fire-and-forget notification to another agent. |
| `web_search`, `web_fetch` | As in Chat. |
| `http_request(method, url, headers, body)` | Domain allowlist per agent. Non-GET requests need approval by default. |
| `codemode` | pi-durable codemode (QuickJS sandbox; `RemoteCodemodeSandbox` on Cloudflare) that can call the agent's other tools. |
| `files_*` | Agent workspace files (R2-backed in the cloud). |
| MCP tools | From remote MCP servers in the definition. |
| `apple_*`, `shortcuts_run` | Apple apps on the user's Mac (§4.1). Local agents directly; cloud agents through the Mac Bridge (§10). |
| `mac_*` (later, Mac Bridge) | Local tools when the Mac is online (§10). |

Actions that change something return a **result card** with Undo (§4.2).

### 4.1 Apple apps as tools (native bridge)

Agents that live on a Mac should work with the user's own data in Apple's apps. The engine is Node and can't use Apple frameworks, so **the Mac app serves these tools**: the engine sends a reverse request (like `secrets.get`, 03-engine-protocol), and the app runs it with the user's system permissions (TCC prompts appear in Piopio, once).

| Tool group | Framework | Examples |
|---|---|---|
| `apple_reminders_*` | EventKit | list (by list, due, overdue), create, complete, reschedule, move between lists |
| `apple_calendar_*` | EventKit | events in a range, create, move, free/busy |
| `apple_contacts_*` | Contacts | find a person, read details (only fields the agent's policy allows) |
| `apple_notes_*` | AppleScript / Shortcuts | search, read, append, create |
| `apple_music_*` | MusicKit / AppleScript | play, queue, current track |
| `apple_home_*` (later) | HomeKit | scenes and accessories |
| `shortcuts_run(name, input?)` | Shortcuts | **any shortcut the user has** becomes a tool. Allowed shortcuts are listed in the agent definition (`tools.shortcuts`). |

- **NB1** Opt-in per agent and per tool group in the definition (`tools.apple: ["reminders", "calendar"]`). Reading is allowed by default; changes follow the agent's approval policy (§9).
- **NB2** Local agents reach the tools while the app is running. In background mode with the app closed, the tools answer "Piopio isn't open" (or the app relaunches as a login item helper, later).
- **NB3** Cloud agents reach the same tools through the Mac Bridge (§10) while the Mac is online.
- **NB4** Build and Chat can use the same bridge later (for example, "add a reminder for this TODO").

### 4.2 Result cards and Undo

Agents act on the user's behalf, so every action that changes something shows **what changed** and can be **undone**.

- **RC1** Tools return a typed result card, not just text: a reminder/event card (the item, with the change shown as "Due Tue 11:00 → Wed 11:00"), a message-sent card, a link card, a file card. Cards render natively in the in-app chat, the Inbox, notifications and the menu bar extra.
- **RC2** Each change records how to reverse it (the previous values, or the created item's id). The card's **Undo** reverts it, within a time window (default 24 h) and only while the item hasn't changed since. Undo is a tool call of its own, logged in Runs.
- **RC3** Cards can be acted on in place when it's safe (tick a reminder, open, copy, share). Larger edits go back through the agent ("Ask Cobot to change this").
- **RC4** The Inbox's "Proposed actions" card (docs/design 4d) uses the same card types before approval; after approval it becomes the result card with Undo.
- **RC5** Undo is the counterpart of permissive approval modes: agents can act without asking for low-risk changes because every change is visible and reversible.

## 5. Channels (v1: In-app, Telegram, WhatsApp)

### 5.1 Common adapter interface
```ts
interface ChannelAdapter {
  id: "inapp" | "telegram" | "whatsapp";
  verify(req): Promise<boolean>;                    // webhook signature
  parse(req): Promise<InboundMessage[]>;            // text, media, buttons, sender id
  send(to, OutboundMessage): Promise<DeliveryReceipt>;
  capabilities: { buttons; media; typing; edits; maxTextLength; proactiveWindow? };
}
```
- **CH1** Inbound flow: webhook → verify → `RegistryDO` resolves `(channel, botId/phoneId)` → agent, and `(channel, senderId)` → contact → `AgentDO.submit(person:<id>, input, whenBusy:"followUp", requestId = channel message id)`. Idempotent, because platforms retry webhooks.
- **CH2** Outbound: long replies are split to fit channel limits. Markdown is converted per channel. Typing indicators are sent while generating (Telegram `sendChatAction`, WhatsApp typing indicator where available).
- **CH3** Media: inbound images/voice/docs are stored in R2 and passed as attachments. Voice notes are transcribed (OpenRouter audio-capable model or a configured STT). Images go to vision models.
- **CH4** Unknown senders: per `policies.unknownSenders`. With `ask_owner`, the owner gets "Unknown +34… wrote 'hi', allow?" with buttons.

### 5.2 Telegram
- One **bot per agent** (via @BotFather). The user pastes the token. Piopio calls `setWebhook` with a secret token.
- Supports inline keyboards (used for approvals and quick replies), edits (live-updating a message while streaming is optional and rate-limited), and groups (later).
- **The recommended primary proactive channel** (no messaging window restrictions).

### 5.3 WhatsApp (official Cloud API)
- Requires a Meta developer app, a WhatsApp Business account, and a dedicated phone number. Piopio provides a **guided setup checklist** (and validates each step with a test call).
- One Meta app webhook → `/v1/channels/whatsapp`, routed by `phone_number_id`. Each number maps to one agent.
- **v1: one WhatsApp number → one "front" agent** (marked `"whatsappFront": true` in Settings › Agents). The front agent reaches the other agents through agent-to-agent (`ask_agent` / `tell_agent`) and answers on their behalf. Other agents are reached directly on Telegram or in-app. The data model already allows several numbers, so "number per agent" can be enabled later without migration.
- **24-hour customer service window:** free-form messages only within 24 h of the person's last message. Outside it, proactive messages MUST use an **approved template**. Piopio ships a generic utility template to register ("{{agent}} has an update for you. Reply to see it."). Proactive sends outside the window send the template, and the actual content is delivered when the person replies.
- Interactive reply buttons (max 3) are used for approvals.

### 5.4 In-app
- The Agents mode chat view. Talking as the owner goes to `person:owner`. It also shows run logs and agent-to-agent traffic.
- Works for both local (dev) and cloud (deployed) agents.

### 5.5 Later
Email (Cloudflare Email Routing in, Email Workers/Resend out), Slack, Discord, SMS (Twilio), iMessage (Mac Bridge only), Telegram/WhatsApp **groups**.

## 6. Proactivity & scheduling

- **PR1** **Schedules:** cron + timezone, defined in the definition or created by the agent at runtime. Each fire creates a `run:<id>` conversation with the prompt + relevant memory. The run may call `send_message`, or decide not to (it records "nothing to report").
- **PR2** **Heartbeat:** optional periodic wake during active hours, with the heartbeat prompt plus a digest of recent activity. Cost-capped (skipped when the budget is above 80%).
- **PR3** **Triggers:** generic webhook endpoint per trigger (HMAC-signed URL). The payload is templated into a prompt and runs as a `run`. Later: RSS, email-in, calendar. Locally: `POST http://127.0.0.1:47615/hooks/<agentId>/<triggerId>/<token>`, where the token is an HMAC of agent and trigger under a key in the engine's home. The body (≤ 1 MB) replaces `{{body}}`; an `Idempotency-Key` or `X-Delivery-Id` header makes a retry the same run. Reaching it from the internet needs a tunnel (optional, the user's own).
- **PR4** **Quiet hours:** outbound messages during quiet hours are queued and delivered at the end of quiet hours, unless the agent marks them `urgent` **and** the policy allows urgent sends (`policies.urgentBypassesQuiet`). Times are in the agent's `timezone` (default: the Mac's).
- **PR5** **Outbound limits:** per-day cap per contact (`maxOutboundPerContactPerDay`) and globally (`maxOutboundPerDay`). When hit, messages are queued until the next day and the owner gets one notice that day.
- **PR6** Durable implementation: schedules are pi-durable tasks (`defineTask` + `runtime.sleepUntil`). The cloud uses `PiHarness` alarm projection, and alarms are at-least-once, so every run is idempotent (keyed by `scheduleId + fireTime`).

## 7. Agent-to-agent

- **AA1** **Addressing:** agents call each other by id/slug. Permission is explicit: A may contact B only if B is in A's `tools.agents` **and** B accepts A (B's `acceptFrom`, default: all of the owner's agents).
- **AA2** **`ask_agent`**: A creates a durable task that sends a message to B's `agent:<A>` conversation (DO-to-DO RPC in the cloud; in-process locally), then waits (`waiting` status) for B's reply, which resolves the task and returns the reply to A's tool call. A timeout (default 10 min) returns a "no reply yet" result, and the late reply arrives as a follow-up.
- **AA3** **`tell_agent`**: fire-and-forget. B processes it like any input and may reply with its own `tell_agent`.
- **AA4** **Loop guards:** every agent message carries `{traceId, hop}`. `hop > 4` is rejected. Per-pair rate limit (default 30/hour). A shared trace budget ($ cap per traceId, default $0.50).
- **AA5** **Visibility:** the app shows agent-to-agent traffic as `agent_msg` items in both agents, plus a **trace view** (a tree of hops with cost) for any conversation that triggered delegation.
- **AA6** **Shared memory:** none by default. An agent can expose read-only memory partitions to specific peers (`shareMemory: {agt_x: ["shared"]}`).
- **AA7** Local ↔ cloud: in v1, both agents must be in the same engine (both local or both cloud).
- **Later:** **rooms**: a multi-agent conversation the owner can watch and join (and a Telegram group with several agent bots).

## 8. Memory

- **ME1** A memory item is `{id, partition, text, source: {conversationId, itemId}, createdBy: agent|user, at, expiresAt?}`.
- **ME2** Retrieval goes through the memory provider (07-shared §5.1). Each partition is its own bank (`<agent>/owner`, `<agent>/shared`, `<agent>/contacts/<id>`), so a contact's memory can't leak into another's (AS2): isolation comes from the storage, not from filtering. Each turn's system section gets the most relevant memory within a token budget (`recall` over the conversation's banks), plus the provider's standing answers when it has them. The rest is reachable through the `recall` tool. With the built-in provider, retrieval is recency + keyword. With Hindsight, it is semantic, keyword, graph and time.
- **ME2a** What gets retained: the owner's and contacts' messages, and the agent's final answers and run outcomes (schedules, triggers). Tool output is not retained. Retaining happens after the turn and never delays the reply. A provider's extracted facts appear in the memory view as "learned", with their source message; deleting one forgets it.
- **ME2b** Cloud agents need a provider reachable from Cloudflare: the built-in one (Durable Object SQLite) or a remote Hindsight URL. A local Hindsight daemon only serves local agents. Moving an agent to the cloud with Hindsight local asks to export its banks, or to switch providers.
- **ME3** The app's memory view per agent: browse by partition, edit, delete, pin. Each item shows where it came from.

## 9. Approvals & safety

- **AS1** Tools/actions matched by `policies.requireApproval` pause in a `pending_approval` state (our own extension, since PiHarness has no approval step). The approval request goes to:
  1. the app, if connected (notification + inline card), and
  2. the **owner's preferred channel** (Telegram inline buttons / WhatsApp reply buttons: Approve / Deny).
  The first answer wins. Approval tokens are single-use and expire (default 24 h → denied).
  Locally (4.4) the call waits in pi-durable's `beforeTool` hook. The decision lives in the agent's state doc, so a request answered after an engine restart still runs. Rules are `tool` or `tool:qualifier`: `to_owner`, `to_non_owner`, `to:<contactId>`, an HTTP method, or `*`; and `mcp:<server>:<tool>`. The owner can approve as asked or with edited arguments, deny with a reason, or tick "Always allow …" (kept per agent: messages to one person, one tool, one HTTP method).
- **AS2** Messages from non-owner contacts can never trigger: memory writes to the owner partition, `send_message` to other contacts, or `ask_agent`, unless explicitly enabled. (A contact's conversation may still message that contact or the owner.)
- **AS3** **Budget:** a monthly $ cap per agent. At 80% the owner is notified. At 100% the agent replies with a canned "I'm out of budget" and stops runs, and the owner can raise the cap from the app or the channel.
- **AS4** **Kill switch:** "Pause agent" (app or `/pause` from the owner on any channel) stops all runs and outbound immediately. Paused, fires are recorded as skipped runs, messages wait in the outbox, and people's messages are kept without a turn; `/resume` or the app's Resume starts it again and releases what was held.

## 10. Mac Bridge (later)
While the Mac is online, the Local Engine keeps a WebSocket open to the Cloud Engine and registers **bridge tools**: the Apple app tools of §4.1 (served by the Mac app), `mac_files`, `mac_imessage_send`, and `mac_shell` with mandatory approval. Cloud agents see these tools only while the bridge is connected. Otherwise the tool returns "Mac offline". The agent header says where an agent runs ("Cloud", "This Mac", or another of the user's Macs once multi-Mac exists).

## 11. Lifecycle: author → test → deploy

```
[Create] → local dev agent (Local Engine, pi-durable on Node SQLite)
   │  chat in-app (simulator) · "Simulate contact" (talk as María on WhatsApp) · run schedule now · fake clock
   ▼
[Deploy] → agents.deploy(target: cloud)
   • validates definition, uploads knowledge files to R2, pushes secrets (encrypted)
   • RegistryDO stores version N, AgentDO reconfigures (no Worker redeploy)
   • registers Telegram webhook / validates WhatsApp mapping
   ▼
[Live] cloud is source of truth for conversations/memory; app subscribes for live view
   • edit definition locally → "Deploy changes" (diff shown) · rollback to version N-1
   • "Pull state" exports conversations+memory snapshot for local debugging
```

- **LC1** A deployed agent is badged ☁︎. Local-only agents are badged 💻 and only run while the engine runs (background mode keeps them alive with the app closed).
- **LC2** Definition changes don't migrate state. Memory and conversations carry over across versions.
- **LC3** Deleting a cloud agent: unregister webhooks → wipe AgentDO storage → remove from RegistryDO → delete R2 prefix. Confirmation is required, with an export offered first.

## 12. Agents UI

- Sidebar: **Inbox** (count badge) at the top, then **Pinned** agents and the rest (status dot: live/paused/error; local/cloud badge; unread; last activity time), and Archived. Each agent has an **avatar** (generated or chosen).
- Agent page tabs: **Chat** (owner conversation) · **Conversations** (per person/agent, read-only except owner) · **Runs** (schedule/trigger/heartbeat log with outcomes and cost) · **Memory** · **Definition** (form/JSON/instructions editor + history) · **Channels** (setup wizards, health) · **Costs**.
- **Inbox** (the name stays "Inbox"): pending approvals, questions and agent messages to the owner across agents (docs/design 4d). Its count also shows as a badge in the toolbar, the menu bar extra and the Dock.
- **UI1 Agent header:** avatar, name, model (and fast mode), the approval mode as a badge (e.g. "Auto", "Asks first"), and where it runs (Cloud / This Mac). The header's menu switches model and mode.
- **UI2 Compact progress:** in agent conversations (and Chat), a turn's tool calls collapse into one line, "Worked 18s · 2 steps" with the tools' icons, and thinking into "Thought for 6s". Clicking expands the steps. Result cards (§4.2) stay visible. Build keeps its detailed tool cards.
- **UI3 Side by side:** open several agents (and Chat threads) in columns of the same window, each with its own composer, to watch one agent while talking to another. Columns close individually; a toolbar button collapses the extra ones. Pinned agents get keyboard shortcuts (⌥⌘1, ⌥⌘2…; ⌘1–3 stay the mode switcher).
- **UI4 Links and files:** links in messages get a preview card (title, site, image, summary) with Open / Copy / Share. A side panel lists a conversation's links and files ("3 links · 2 files").
- **UI5 Voice:** dictation in every composer (on-device speech recognition), and voice notes sent as audio and transcribed like channel voice notes (CH3). A hands-free voice mode comes later.
- **UI6 Quick entry to an agent:** Quick Chat (04-chat §4) can address an agent ("@Cobot remind me…"), so the request goes to that agent instead of a new thread.

## 12.1 Agent boards (later)

A **board** of tasks for agents ("Projects" in Agents): columns To do / Doing / Done, with cards assigned to an agent. The agent picks up a card as a run, keeps its checklist on the card (the Build `todo` tool), moves it, and posts the result card when done. The owner can add, reorder or reassign cards; agents can add cards for each other (agent-to-agent, §7) within their budgets.

## 13. Resolved questions (Agents)
- **AQ1** Telegram → **one bot per agent** (§5.2).
- **AQ2** WhatsApp → **one number for a single front agent** in v1 (§5.3).
- **AQ3** Identity → **one conversation per person across channels** (§3).
- **AQ4** Spaces vs Agents → **kept separate**. They share runtime code only (04-chat §3.8).
