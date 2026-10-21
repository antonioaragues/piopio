# 03 — Engine Protocol

The single contract between clients (Mac app, later the iOS app) and engines (Local, Cloud). It is defined in `packages/protocol` with TypeBox, exported as JSON Schema, and compiled into Swift `Codable` types.

## 1. Transport

| Engine | Transport | Framing |
|---|---|---|
| Local | Unix domain socket | newline-delimited JSON-RPC 2.0 |
| Cloud | WebSocket (wss) | one JSON-RPC message per frame |

- Requests: `{jsonrpc, id, method, params}`. Responses: `{jsonrpc, id, result | error}`.
- Notifications (engine → client): `{jsonrpc, method, params}` with no `id`.
- The protocol is versioned (`protocolVersion: "1.x"`). `engine.hello` negotiates it. Minor versions only add fields, and clients ignore unknown fields.

## 2. Conventions

- **IDs:** ULIDs, with a type prefix: `prj_`, `ses_`, `thr_`, `spc_`, `top_`, `agt_`, `apr_`, `run_`, `itm_`.
- **Container reference:** `ContainerRef = { kind: "build" | "thread" | "space" | "agent", id }`. A Space topic is `{kind:"space", id, conversationId}`.
- **Idempotency:** every mutating call accepts `clientRequestId`. It maps onto pi-durable `requestId` / `operationId`.
- **Errors:** JSON-RPC error codes plus a `data.code` string (`NOT_FOUND`, `BUSY`, `AUTH`, `ENGINE_UNAVAILABLE`, `MODEL_ERROR`, `INVALID`, `CONFLICT`, `QUOTA`).
- **Time:** ISO-8601 UTC strings.

## 3. Methods (v1 surface)

### 3.1 Engine
| Method | Purpose |
|---|---|
| `engine.hello({token, client, protocolVersion})` → `{engineId, kind, version, capabilities}` | Handshake. `capabilities` lists which runtimes/features this engine supports (e.g. cloud has no `build`). |
| `engine.status()` | Health, open harnesses, queue depth, background mode |
| `engine.logs.tail({level, since})` | Stream logs (notifications `engine.log`) |

### 3.2 Catalog
| Method | Purpose |
|---|---|
| `catalog.list({kinds, filter, cursor})` | Sidebar data: projects, sessions, threads, spaces, agents, with status |
| `catalog.search({query, scope})` | FTS across timeline items |
| `catalog.pin / rename / archive / delete({ref})` | Housekeeping |
| `catalog.subscribe()` | Notifications `catalog.changed` (upserts/removals) |

### 3.3 Projects (Build + Chat lens)
`projects.add({path})`, `projects.remove`, `projects.get`, `projects.setLens({lens:"build"|"chat"})`, `projects.files.tree({path, depth})`, `projects.files.read({path})`, `projects.files.write({path, content})` (user quick edit), `projects.openIn({editor})`.

### 3.4 Sessions (common to all containers)
| Method | Purpose |
|---|---|
| `sessions.create({container, options})` | Build: `{projectId, worktree?: bool, profile: "build"\|"chat", model?, thinking?}`. Thread: `{model?}`. Space: `{name, instructions?}` |
| `sessions.open({ref})` → `Snapshot` | Load the full timeline + state |
| `sessions.subscribe({ref})` → `{subscriptionId, snapshot}` | Then `session.events` notifications. Always starts from a snapshot (matches pi-durable semantics). |
| `sessions.unsubscribe({subscriptionId})` | |
| `sessions.submit({ref, input, whenBusy: "followUp"\|"steer"\|"reject", clientRequestId})` | `input = {text, attachments[], mentions[]}` |
| `sessions.abort({ref})` | Stop current work |
| `sessions.configure({ref, model?, thinking?, approvalMode?, tools?})` | Mid-session changes |
| `sessions.fork({ref, fromItemId})` → new ref/conversation | Thread/Space fork, Build fork/clone |
| `sessions.compact({ref, instructions?})` | Manual compaction |
| `sessions.export({ref, format:"md"\|"html"\|"jsonl"})` | |
| `sessions.queue.clear({ref})` | Clear queued follow-ups |

### 3.5 Approvals
| Method / notification | Purpose |
|---|---|
| `approval.requested` (notification) | `{approvalId, ref, tool, summary, args, risk, expiresAt?}` |
| `approvals.list()` | Pending approvals across all containers |
| `approvals.respond({approvalId, decision:"allow"\|"deny"\|"allowAlways", scope?, note?})` | `allowAlways` adds a rule (per project/agent) |

### 3.6 Models
`models.list({refresh?})` → OpenRouter catalog with `{id, name, contextLength, pricing, supports:{tools, vision, reasoning, files}}`. `models.favorites.set`, `models.defaults.get/set({mode})`.

### 3.7 Git & GitHub (Build)
`git.status`, `git.diff({ref | paths, against: "checkpoint"\|"HEAD"\|"base"})`, `git.commit`, `git.push`, `git.branch.*`, `git.worktree.*`, `checkpoints.list/restore`, `github.auth.status/start`, `github.pr.create/get/list`, `github.checks.get`, `github.reviews.get`.

### 3.8 Spaces
`spaces.topics.list`, `spaces.topics.rename/archive/merge`, `spaces.memory.get/set`, `spaces.files.add/remove/list`, `spaces.reroute({routingItemId, toTopicId})`.

### 3.9 Agents
`agents.list/get/create/update/delete`, `agents.definition.diff/history/rollback`, `agents.deploy({agentId, target:"local"|"cloud"})`, `agents.undeploy`, `agents.contacts.*`, `agents.channels.*` (connect/test/disconnect), `agents.memory.get/set`, `agents.schedules.list/pause/resume/runNow`, `agents.runs.list/get`, `agents.simulate({agentId, as: contactId, channel, text})`.

### 3.10 Cloud (Local Engine only)
`cloud.setup({cfAccountId, cfApiToken})`, `cloud.status`, `cloud.upgrade`, `cloud.rotateToken`, `cloud.teardown`. Once set up, the Local Engine **proxies** cloud containers to the app, so the app can use a single connection (direct connection is used later for iOS).

### 3.11 Secrets (engine → app, reverse request)
`secrets.get({name, purpose})` is sent by the engine to the app. The app reads the Keychain and may prompt. `secrets.set` goes the other way during onboarding.

### 3.12 App services (engine → app, reverse requests)
Things only the Mac app can do, asked for by the engine the same way:
- `app.tool({name, args, agentId})` → `{result, card?, undo?}`: Apple app tools (06-agents §4.1: EventKit, Contacts, Notes, Music, Shortcuts). The app checks the agent's allowed tool groups and runs the call with the user's permissions. `undo` describes how to reverse a change (06-agents §4.2).
- `app.utility({task, input})` → `{output}`: the on-device model (Apple Foundation Models) for utility work (07-shared-resources §1.3). The engine falls back to its OpenRouter utility model when the app is closed or the model is unavailable.
- With no app connected (background mode, app closed), these return `unavailable` and the tools say so.
- A client says which of these it answers in `engine.hello` (`services: ["app.tool"]`); only those clients are asked, newest first.

## 4. Timeline model (normalized)

Everything a transcript shows is a `TimelineItem`:

```ts
type TimelineItem =
  | { kind: "user";        id; at; text; attachments; via?: ChannelInfo; author?: ContactRef }
  | { kind: "assistant";   id; at; parts: AssistantPart[]; model; usage?; status: "streaming"|"done"|"error"|"aborted" }
  | { kind: "tool";        id; at; tool: string; args: unknown; status: "pending_approval"|"running"|"done"|"error"|"interrupted"|"denied";
                           output?: string; details?: ToolDetails; durationMs?; parentId? }
  | { kind: "routing";     id; at; decision: "answer"|"route"|"create"; topicId?; topicTitle?; reason; preview? }   // Spaces
  | { kind: "task";        id; at; title; status; childRef?: ContainerRef }                                         // subagents, runs
  | { kind: "system";      id; at; level: "info"|"warn"|"error"; text }
  | { kind: "compaction";  id; at; summary; tokensBefore; tokensAfter }
  | { kind: "checkpoint";  id; at; checkpointId; filesChanged }                                                     // Build
  | { kind: "agent_msg";   id; at; fromAgent; toAgent; text; direction: "in"|"out" }                                 // Agents

type AssistantPart = { type: "text"; text } | { type: "thinking"; text; redacted? } | { type: "image"; url }
type ToolDetails =
  | { type: "diff"; path; hunks }                 // edit/write
  | { type: "file"; path; range?; language }      // read
  | { type: "terminal"; command; exitCode?; output }  // bash
  | { type: "web"; results: {title,url,snippet}[] }   // search
  | { type: "page"; url; title; excerpt }             // fetch
  | { type: "json"; value }                           // fallback
```

Tool renderers in the app key off `details.type` first, then `tool` name. Unknown tools fall back to JSON.

## 5. Session events (notification `session.events`)

```ts
{ subscriptionId, seq, events: SessionEvent[] }   // batched; seq is strictly increasing per subscription

type SessionEvent =
  | { type: "item.added";   item: TimelineItem }
  | { type: "item.delta";   itemId; partIndex; textDelta }        // streaming text/thinking
  | { type: "item.updated"; item: TimelineItem }                  // status/output changes
  | { type: "item.removed"; itemId }                              // reset/branch switch
  | { type: "item.replaced"; oldId; item }                        // provisional id → durable id, same position
  | { type: "state";        state: SessionState }                 // idle/running/waiting_approval/error, queue, model, usage
  | { type: "branch";       activeLeafId; branches }              // fork navigation
  | { type: "resnapshot";   snapshot }                            // engine-side restart → client replaces state
```

`SessionState = { status, queue: QueuedInput[], model, thinking, approvalMode, usage: {inputTokens, outputTokens, cacheTokens, costUsd}, contextWindowUsed }`.

**Gap handling:** if a client sees a `seq` gap, it re-subscribes. Engines MAY drop to `resnapshot` at any time (e.g. a DO waking up).

## 6. Mapping notes

Verified against pi 1.3.0 in Spike S1 (`packages/engine/src/timeline/`, fixtures in `packages/engine/test/fixtures/`). Both runtimes feed one `TimelineBuilder` through a thin adapter each, because their event shapes differ even though they share names.

| pi-coding-agent SDK (`AgentSessionEvent`) | pi-durable (`watchEvents`) | Maps to |
|---|---|---|
| `agent_start` / `agent_settled` | `run_start` / `run_end` | `state` running / idle |
| `message_start` (user) | `message_end` with a `pi.user` entry | `item.added` user |
| `message_start` (assistant) | `message_start` (assistant) | `item.added` assistant (pi-durable: provisional `gen:N` id) |
| `message_update.assistantMessageEvent` `text_delta` / `thinking_delta` | `message_update.changes[]` `text_start`/`text_delta`/`thinking_*` | `item.delta` |
| `message_end` (assistant message) | `message_end` with a `pi.assistant` entry | `item.updated` (SDK) / `item.replaced` gen:N → entry id (pi-durable) |
| `tool_execution_start/update/end` (`partialResult`, `result`) | `tool_execution_start/update/end` (`output` trim/append, result `entry`) | `tool` item + `item.updated` |
| `queue_update {steering, followUp}` | `inbox_update {items}` | `state.queue` |
| `compaction_end` | `entry_appended` (`pi.compaction`), `compaction_end` (errors) | `compaction` / `system` item |
| `auto_retry_start/end` | `auto_retry_start`, `task_failed`, `submission` (`unanswered`) | `system` item |
| `session.messages` (snapshot) | `snapshot.entries` (+ `generation` partial) | `resnapshot` / initial snapshot |
| pi `extension_ui_request` (confirm), from the approvals extension | — | `approval.requested` (Phase 2) |

**Item ids.** pi-durable items use the committed entry id (stringified). pi SDK messages carry no ids, so items are numbered by transcript position (`m<index>`, counting system messages). Tests check that both stay stable across an engine restart.

**Usage** is summed from each assistant message's `usage` (identical for both runtimes) rather than read from `pi.usage`.

**System messages:** the pi SDK emits the system prompt as a `system` role message (with `sections`). It is not shown in the timeline.
