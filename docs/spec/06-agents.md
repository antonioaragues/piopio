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
    "quietHours": "22:30-07:30", "maxOutboundPerDay": 20, "budgetUsdPerMonth": 15,
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
| `mac_*` (later, Mac Bridge) | Local tools when the Mac is online (§10). |

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
- **PR3** **Triggers:** generic webhook endpoint per trigger (HMAC-signed URL). The payload is templated into a prompt and runs as a `run`. Later: RSS, email-in, calendar.
- **PR4** **Quiet hours:** outbound messages during quiet hours are queued and delivered at the end of quiet hours, unless the agent marks them `urgent` **and** the policy allows urgent sends.
- **PR5** **Outbound limits:** per-day cap per contact and globally. When hit, messages are queued and the owner gets one notice.
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
- **ME2** Retrieval: v1 puts the most relevant memory in a system section (recency + keyword match, with a token budget) and exposes the rest through `recall`. Semantic retrieval (Vectorize) comes later.
- **ME3** The app's memory view per agent: browse by partition, edit, delete, pin. Each item shows where it came from.

## 9. Approvals & safety

- **AS1** Tools/actions matched by `policies.requireApproval` pause in a `pending_approval` state (our own extension, since PiHarness has no approval step). The approval request goes to:
  1. the app, if connected (notification + inline card), and
  2. the **owner's preferred channel** (Telegram inline buttons / WhatsApp reply buttons: Approve / Deny).
  The first answer wins. Approval tokens are single-use and expire (default 24 h → denied).
- **AS2** Messages from non-owner contacts can never trigger: memory writes to the owner partition, `send_message` to other contacts, or `ask_agent`, unless explicitly enabled.
- **AS3** **Budget:** a monthly $ cap per agent. At 80% the owner is notified. At 100% the agent replies with a canned "I'm out of budget" and stops runs, and the owner can raise the cap from the app or the channel.
- **AS4** **Kill switch:** "Pause agent" (app or `/pause` from the owner on any channel) stops all runs and outbound immediately.

## 10. Mac Bridge (later)
While the Mac is online, the Local Engine keeps a WebSocket open to the Cloud Engine and registers **bridge tools** (`mac_files`, `mac_calendar`/`mac_reminders` via EventKit, `mac_imessage_send`, `mac_shell` with mandatory approval). Cloud agents see these tools only while the bridge is connected. Otherwise the tool returns "Mac offline".

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

- Sidebar: agents list (status dot: live/paused/error; local/cloud badge; unread).
- Agent page tabs: **Chat** (owner conversation) · **Conversations** (per person/agent, read-only except owner) · **Runs** (schedule/trigger/heartbeat log with outcomes and cost) · **Memory** · **Definition** (form/JSON/instructions editor + history) · **Channels** (setup wizards, health) · **Costs**.
- Global "Inbox": pending approvals and agent messages to the owner across agents.

## 13. Resolved questions (Agents)
- **AQ1** Telegram → **one bot per agent** (§5.2).
- **AQ2** WhatsApp → **one number for a single front agent** in v1 (§5.3).
- **AQ3** Identity → **one conversation per person across channels** (§3).
- **AQ4** Spaces vs Agents → **kept separate**. They share runtime code only (04-chat §3.8).
