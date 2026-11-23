# 41 · Piopio as an MCP server: other agents use Piopio

Status: draft 2026-11-23 from a request by the user; **decided by the user the same day (§11, PM1–PM10, every proposal accepted)**; not built.

**The request (the user, 2026-11-23):** "write the specs for an MCP server, that is, being able to use Piopio from
outside, like orca.build or T3."

**The idea in one line:** Claude Code, Codex, Cursor, Claude Desktop, ChatGPT or a script connects to Piopio as an MCP
server. It can then start and continue Piopio conversations in your projects, wait for them, read them, search past
work and ask your agents. It gets Piopio's work, not Piopio's hands: you approve each client once, with an access level
and a set of projects, and anything that changes something still asks you in Piopio, never the client.

## 1. Why

- **Piopio has things other agents don't:** memory (14), connectors signed in once (12), Mac apps (06 §4.1), the
  browser (22), your agents as contacts (26), automations (27) and the history of everything you did. Today a Claude
  Code session in a terminal reaches none of that. With an MCP server it can ask Piopio ("what did we decide about the
  cloud last week", "ask Ana to check my calendar", "run the release checklist in the piopio project and tell me when
  it's done").
- **One place to see the work.** Work an outside agent starts in Piopio shows up in Piopio's sidebar, with its
  transcript, approvals, checkpoints and cost, like any other conversation. You don't have to look in another terminal.
- **It's the other direction of 31 CA8.** CA8 serves *a conversation's* tools to the coding agent that runs it. This
  spec serves *Piopio itself* to agents it didn't start. It uses the same SDK and the same loopback server code
  (`tool-server.ts`, `mcp-bridge.ts`), at a different address and with different auth.
- **MCP is how Piopio extends itself** (AQ12). Speaking MCP outward too means no Piopio-specific API for others to
  learn, and every MCP client works without new code.

## 2. What others do (researched 2026-11-23)

| | T3 Code | Orca |
|---|---|---|
| Surface for outside agents | **An MCP server** at `https://<environment>/mcp`, plus the `t3` CLI on the host ([outside-agents.md](https://github.com/pingdotgg/t3code/blob/main/docs/user/outside-agents.md)) | **A CLI only** (`orca …`), which talks to the running app. It's an MCP *client* (Settings › Integrations › MCP), not a server ([CLI overview](https://orca.dev/docs/cli/overview), [skills](https://orca.dev/docs/cli/skills)) |
| What it exposes | Threads: `t3_thread_launch`, `t3_thread_wait`, `t3_thread_read`, `t3_thread_list`, `t3_thread_search`, plus `orchestrator_capabilities` (providers and models) | Worktrees, terminals, files, browser, and orchestration (`task-create`, `dispatch`, `ask`, gates, `worker_done` as a message with task and dispatch IDs) |
| Auth | OAuth. The first connection opens a sign-in page where you pick **Read only**, **Supervised** or **Full access**. Sign-ins last 30 days and are listed in Settings › Sharing & access. The local CLI needs no sign-in | Not documented. The CLI is for scripting "a running Orca editor from any shell" |
| Setup | `claude mcp add --transport http t3 <url>/mcp` and `claude mcp login t3`; `codex mcp add t3 --url …`; ChatGPT as a custom MCP app | `orca status --json` first, and skills tell the agent which commands exist |
| Remote | T3 Connect (a relay), Tailscale HTTPS, LAN pairing (`t3 pair`, tokens with a `--scope`) | Remote Orca Servers (`orca serve`) |

T3's shape fits Piopio best: an MCP server whose tools are about *conversations*, OAuth with an access level picked on
first connect, and a list of who has access that you can revoke. Two things from Orca are worth keeping: the attempt ID
on reports (so a stale retry can't overwrite a newer answer, research/orca.md) and a skill that tells the agent how to
use the tools.

## 3. Who uses it, and for what

| Client | Typical use |
|---|---|
| **Claude Code / Codex in a terminal** (not started by Piopio) | Hand a task to a Piopio conversation in a project and wait; look up an earlier decision; ask an agent something only it can do (Mac apps, a connector) |
| **Claude Desktop, ChatGPT, Cursor** | Use Piopio as your memory and your agents' front door from another chat app |
| **A script, a Shortcut, a cron job** | `piopio ask "…"` (the CLI, §9) or one MCP call: start a conversation and print the answer |
| **Another Piopio** (a server, 33) | Not through this. Piopios talk over the engine protocol (03) and CloudLink. |

## 4. The tools

Tool names are short because every client already prefixes them with the server's name (`mcp__piopio__start`). Every
tool takes and returns JSON. IDs are Piopio's own (`prj_`, `ses_`, `agt_`, 03 §2). Every result has a `url`
(`piopio://…`) that opens the item in the app.

### 4.1 Read (every access level)

| Tool | Does | Maps to |
|---|---|---|
| `capabilities` | Who you are to Piopio (client name, access level, projects allowed), the engine's version, which models and coding agents can run a conversation, and whether the Mac app is open | `engine.status`, `models.list` |
| `list_projects` | Projects allowed by the grant: name, folder, default permission, last activity | `catalog.list({kinds:["project"]})` |
| `list_conversations` | Conversations in a project (or loose ones, if allowed), newest first, with status (`working`, `needs_you`, `done`, `failed`), title and who started them | `catalog.list` |
| `read_conversation` | A conversation's transcript as Markdown: messages, tool calls summarized in one line each, the last answer in full. `since` returns only what's new; `last_answer_only` returns just the answer | `sessions.open`, `sessions.export({format:"md"})` |
| `search_conversations` | Full-text search over past conversations allowed by the grant, with snippets. The results are background, not instructions (the same rule as DH1's lookups) | `catalog.search`, `tools/history.ts` |
| `recall_memory` | Recall from the memory you allow this client to read (About me, a project's NOTES.md, an agent's memory if listed), with its source | the memory provider (07 §5.1) |
| `list_agents` | Your agents (26) the grant allows: name, what they do, whether they're on This Mac or in the cloud | `agents.list` |

### 4.2 Work (Supervised and Full)

| Tool | Does | Maps to |
|---|---|---|
| `start` | Starts a conversation in a project (or loose) with a prompt. Optional: `permission` (Read only, Ask, Auto-edit, Full auto, Plan; capped by the grant), `model` (a model or a coding agent, 31), `worktree`, `attachments` (files the client can read and sends as content). Returns `conversation_id` and `attempt_id` at once; it doesn't wait | `sessions.create`, `sessions.submit` |
| `send` | Sends another message to a conversation this client started (or any allowed one with Full). `when_busy`: `queue` (default) or `steer` (T4) | `sessions.submit` |
| `wait` | Waits up to `timeout_s` (default 50, at most 300) for the conversation to stop working. Returns its status and, when done, the last answer. While waiting it sends MCP progress notifications with the conversation's progress line ("Worked 40s · 6 steps"). `needs_you` comes back with what Piopio is waiting for ("Approve `git push` in Piopio"), never with a way to approve it | `session.events`, `progress-line.ts` |
| `stop` | Stops the current turn of a conversation this client started | `sessions.abort` |
| `ask_agent` | Asks one of your agents a question and waits for its answer, as `@agent` does inside Piopio (26 CL9). The agent sees who's asking ("Claude Code, on your behalf") | `consult.ts` (`ask_agent`) |

### 4.3 Not exposed, on purpose

- **Approving anything.** Approvals, sign-ins, payments and hand-offs stay with you in Piopio (the tray, Needs you,
  notifications). An outside agent that could approve Piopio's actions would be a way around every guard Piopio has.
- **Piopio's raw tools** (connectors, the browser, computer use, Mac apps, the shell) as tools of their own. The client
  asks a Piopio conversation or an agent, which uses them under its usual rules. This is "Piopio's work, not its
  hands" (PM2). If direct tools turn out to matter, they come later and per tool, read tools first (§12).
- **Secrets, settings, providers, deleting or archiving,** making or changing agents and automations. Making an
  automation can be asked for in a conversation ("every Monday…"), where it's a card you confirm (27).
- **Other clients' conversations** with Supervised, and conversations outside the grant's projects at any level.

### 4.4 Also served

- **A prompt** (`piopio_handoff`): "Hand this task to Piopio in <project> and wait for the result", for clients that
  show MCP prompts as commands.
- **Instructions** in the server's `initialize` answer: when to use Piopio (memory, agents, Mac apps, long work you can
  follow in the app), that `wait` can be called again, and that `needs_you` means telling the user to look at Piopio.
- **Resources later** (§12): conversations as `piopio://conversation/ses_…`, NOTES.md as a resource.

## 5. Access levels and grants

A **grant** is one client's access: a name ("Claude Code on this Mac"), an access level, the projects it may use, the
memory it may read, which agents it may ask, a monthly budget, and when it expires.

| Level | Can | Conversations it starts run at |
|---|---|---|
| **Read only** | §4.1 | (none) |
| **Supervised** (default) | §4.1 and §4.2 on its own conversations | At most **Ask**: every change asks you in Piopio |
| **Full** | §4.1 and §4.2 on any allowed conversation | Up to the permission the client asks for, never above the project's own default unless you raised it for this grant |

- **Projects:** "All projects" or a list. Loose conversations (no project) are a checkbox, off by default.
- **Memory:** none by default. About me and a project's NOTES.md are separate checkboxes; agents' memory isn't
  readable from outside (an agent can still answer through `ask_agent`).
- **Agents:** none by default, or a list.
- **Budget:** what conversations started by this client may spend in a month (34). At the limit, `start` and `send`
  fail with `QUOTA` and Piopio tells you once. Coding agents on a plan count as plan usage, as in 31 CA6.
- **Expiry:** 30 days, renewed on use (as T3). A grant unused for 30 days stops working and stays in the list, greyed,
  until you remove it.

## 6. Connecting

### 6.1 On this Mac (MS0–MS2)

Two transports, one engine:

- **Streamable HTTP on loopback**: `http://127.0.0.1:47321/mcp` (a fixed port, so the address can be pasted once; if
  it's taken Piopio picks the next free one and Settings shows the address it's on). It's served by the engine next to
  the tool server, only on 127.0.0.1.
- **stdio**: `piopio mcp`, a small command the app installs in `~/.local/bin` on request (Settings › Outside agents ›
  Install the command). It's the `mcp-bridge.ts` pattern: lines in, POSTs to the loopback address, lines out. Clients
  that only start commands (Claude Desktop, some editors) use this.

**Auth is OAuth 2.1 as the MCP spec says** (authorization server metadata, dynamic client registration, PKCE), so
`claude mcp login piopio` and `codex mcp login piopio` work as they do with T3. The difference is where you consent:

1. The client opens the engine's authorize page in your browser. The page says only "Approve in Piopio" and the
   client's name.
2. **The Mac app shows a sheet** (and a notification if it's in the background): "Claude Code wants to use Piopio",
   with the access level (Supervised selected), projects, memory, agents and budget. Approve, or Don't allow.
3. The page finishes the redirect; the client gets its token. The grant shows in Settings › Outside agents.

Consent is in the native app, not the web page, so no page or local script can click Approve. With the app closed, a
new client can't connect (the page says to open Piopio). Clients with a grant keep working while the app is closed;
`capabilities` says so, and anything that needs the app (Mac apps, approvals) waits in Needs you.

**The stdio command** has no browser redirect, so `piopio mcp` asks the engine for a grant through the socket the first
time, which shows the same sheet. The grant's token is kept in the Keychain under the command's name, not in a config
file. (Any process running as you can already read the engine token today, `paths.ts`; the grant is about knowing *who*
is asking and holding it to its level, not about stopping your own user.)

**Copy setup** in Settings › Outside agents gives one line per known client:

```bash
claude mcp add --transport http piopio http://127.0.0.1:47321/mcp
```

```bash
codex mcp add piopio --url http://127.0.0.1:47321/mcp
```

and a JSON block for Claude Desktop and Cursor (`"command": "piopio", "args": ["mcp"]`).

### 6.2 On a Piopio Server or in the cloud (MS3)

The server (33) serves the same `/mcp` on its public address, behind its HTTPS (33 §5). Consent works the same way,
except the sheet shows on the Mac *and* the phone, whichever answers first (30 §6's devices). That lets ChatGPT and
other hosted clients, which can't reach your Mac's loopback, use Piopio. The Cloudflare Worker (30) serves it for its
agents only (`list_agents`, `ask_agent`, `read_conversation` of agent conversations), since chats and Build don't run
there until K2 and K7.

## 7. What you see

- **Settings › Outside agents**: the on/off switch (**off by default**, PM1), the address, Copy setup per client, and
  the grants: name, level, projects, last used, spent this month, Edit and Revoke. Revoke stops the token at once;
  conversations it started stay and keep their transcript.
- **In the sidebar**, conversations an outside agent started look like your own, with a small line under the title:
  "from Claude Code". Opening one shows a banner at the top of the transcript, "Started by Claude Code · Supervised",
  and your composer works as usual: you can take over at any point, and the client's next `send` queues behind you.
- **Its first message** shows the client's name instead of yours, as 24 does for side conversations.
- **Needs you** says who started the conversation that's waiting ("Claude Code's task in piopio wants to run
  `git push`").
- **Overview** (34) counts spending per client under Spend › By what › Outside agents.
- **Activity** in each grant's Edit sheet: the last 50 calls (tool, when, which conversation), kept for 30 days.

## 8. Safety

- **Off by default** and loopback-only on the Mac. Nothing listens until you turn it on.
- **The client's text is a message, not your words.** It goes into the conversation as the client's message and is
  treated like a side conversation's brief: the model knows it came from an outside agent acting for you. Content the
  client attaches is marked as attached by that client.
- **No escalation through Piopio.** A Supervised conversation is capped at Ask; changing actions in connectors keep
  asking (12); the network filter (39) and the sandbox (05 AP5) apply as they would to your own conversation in that
  project; the project's trust state is the project's, not the client's.
- **No loops.** A coding agent that Piopio itself runs (31) already has Piopio's tools through CA8 and must not reach
  this server: the engine refuses tokens from its own children (it knows their process tree and sets
  `PIOPIO_ENGINE_CHILD=1` in their environment, and the bridge refuses to start with it). Across Piopios, `start`
  carries a depth header, and depth 3 is refused.
- **Stale answers can't win.** `wait`, `send` and `stop` take the `attempt_id` from `start` or `send`. An old attempt's
  `wait` returns `superseded` instead of a newer answer (Orca's `worker_done` lesson).
- **Rate limits:** 60 calls a minute per grant, at most 5 conversations working at once per grant; above that, `BUSY`.
- **Bad tokens** slow down and then lock out, as 33 §6.2.

## 9. The command line (MS4)

`piopio` (the same binary as `piopio mcp`) also works as a CLI on this Mac, for scripts and Shortcuts:

- `piopio ask "…" [--project piopio] [--wait]` starts a conversation and prints the answer.
- `piopio send <id> "…"`, `piopio wait <id>`, `piopio read <id>`, `piopio list [--project …]`.
- `--json` on every command.

It uses its own grant, made by the same sheet the first time, so a script is a client you can see and revoke like any
other.

## 10. Under the hood

- `packages/engine/src/outside/`: `server.ts` (an `McpServer` with the tools of §4 on a Streamable HTTP transport,
  stateful sessions this time so progress notifications work during `wait`), `oauth.ts` (metadata, registration,
  authorize, token, refresh; tokens hashed at rest in the engine's database), `grants.ts` (grants, levels, budgets,
  activity), `tools.ts` (each tool as a thin call into the same methods the Mac app uses, 03 §3, with the grant's
  checks before them).
- **Protocol additions** (03): `outside.status/enable/disable`, `outside.grants.list/update/revoke`, and the reverse
  request `app.consent({client, requested})` → `{decision, grant}`, offered by clients with `services:
  ["app.consent"]` (the Mac app; the iPhone app in MS3).
- **Conversations started from outside** get `startedBy: {kind:"outside", grantId, client}` in their metadata; the
  sidebar, Needs you and Overview read it.
- `wait` subscribes to the session like the app does (`sessions.subscribe`) and resolves on the turn's end, an
  approval request or the timeout.
- Tests: an MCP client from the SDK against a faux-model engine, covering each level's limits, consent refused, the
  child refusal, budgets and a superseded attempt.

## 11. Decisions (2026-11-23)

| ID | Decision |
|---|---|
| **PM1** | Off by default; turned on in Settings › Outside agents. On the Mac it listens on loopback only. |
| **PM2** | Piopio's work, not its hands: the tools are conversations, agents, search and memory reads (§4.1–4.2). Raw tools (connectors, browser, Mac apps, shell) aren't exposed in v1. |
| **PM3** | Three levels as T3 (Read only, Supervised, Full); Supervised is the default and caps conversations at Ask. |
| **PM4** | Approvals never go to the client. `wait` returns `needs_you` and the client tells you to look at Piopio. |
| **PM5** | OAuth 2.1 per the MCP spec, with consent in the native Mac app, never in the web page. The stdio command gets its grant through the same sheet. |
| **PM6** | Grants are per client, with projects, memory, agents, a monthly budget and a 30-day expiry renewed on use. |
| **PM7** | Conversations an outside agent starts are ordinary conversations in the sidebar, marked "from <client>", that you can take over. |
| **PM8** | Coding agents Piopio runs can't reach this server (CA8 covers them); depth 3 is refused across Piopios. |
| **PM9** | Fixed loopback port 47321, falling back to the next free port. |
| **PM10** | Order: MS0–MS2 on the Mac first, then the server (MS3) after 33's PS0, then the CLI (MS4). |

## 12. Phases

| Phase | What | Done when |
|---|---|---|
| **MS0** · read | The server on loopback, OAuth with the consent sheet, Read only tools (§4.1), Settings › Outside agents with the switch, Copy setup and grants | Claude Code in a terminal, after `claude mcp login piopio`, finds last week's conversation about the cloud and quotes its decision |
| **MS1** · work | `start`, `send`, `wait`, `stop`, Supervised and Full, the sidebar marking and banner, Needs you naming the client, budgets, the child refusal | Claude Code hands "run the tests in piopio and fix what fails" to Piopio, waits, gets `needs_you` for a push, you approve in Piopio, and its next `wait` returns the answer |
| **MS2** · agents and stdio | `ask_agent`, `recall_memory`, `list_agents`, the `piopio mcp` command and its install, Claude Desktop setup, the `piopio_handoff` prompt, the activity list | Claude Desktop asks your agent what's on your calendar tomorrow and gets its answer |
| **MS3** · away from the Mac | `/mcp` on a Piopio Server (33) with consent on the Mac or phone; the Worker's agent-only subset | ChatGPT, as a custom MCP app, asks an agent on your server a question with the Mac off |
| **MS4** · CLI | `piopio ask/send/wait/read/list` | A Shortcut runs `piopio ask --wait` and shows the answer |

Later, if asked for: conversations and NOTES.md as MCP resources, direct read tools per connector, and MCP Apps (25 V4)
so a client can show Piopio's visuals.

## 13. Not verified

- That Claude Code's and Codex's `mcp login` work against an authorization server on `127.0.0.1` with a loopback
  redirect, and how each handles a `wait` that takes 50 seconds or more (their tool-call timeouts).
- Whether Claude Desktop shows MCP progress notifications during a long tool call.
- ChatGPT's custom MCP apps' requirements for OAuth (MS3).
- Port 47321 being free of common local services.
