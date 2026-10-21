# 07 — Shared resources

Resources defined once and opted in per mode, project, space or agent (decision X6).

## 1. Models

### 1.1 Providers
- **v1: OpenRouter only**, through pi-ai's provider support. One API key, stored in Keychain.
- **Later:** direct Anthropic/OpenAI/Google, local (Ollama, LM Studio), subscription logins where pi supports them, Cloudflare AI Gateway routing for cloud agents.
- The engine's `models` module abstracts providers: `{providerId, modelId}`. OpenRouter IDs (`vendor/model`) are used as-is.

### 1.2 Catalog & picker
- **MO1** Fetch the OpenRouter `/models` list on start (cached 24 h, manual refresh). Store `{id, name, context, pricing in/out/cache, supports: tools, vision, reasoning, files, audio}`.
- **MO2** The picker (⌘M or click the model chip) offers fuzzy search, filters (tools, vision, reasoning, ≤$/Mtok), **favorites**, recents, and price + context shown inline. Models without tool support are dimmed where tools are needed (Build, Agents).
- **MO3** Thinking level control appears only for reasoning-capable models.

### 1.3 Defaults (Settings › Models)
| Slot | Used for | Suggested default |
|---|---|---|
| Build | coding sessions | a top coding model |
| Chat | threads, topics | a strong general model |
| Organizer | Space routing | a fast, cheap tool-capable model |
| Agents | agent default | a cheap capable model |
| Utility | titles, summaries, commit messages, topic summaries, routing hints, memory extraction | **Apple's on-device model** (Foundation Models, through the app) when available, else the cheapest fast OpenRouter model |

Defaults are overridable per project, space, agent and session.

### 1.4 Cost tracking
- **CO1** Every model call writes a ledger row (engine `catalog.db`; cloud: AgentDO, synced to the app when connected).
- **CO2** Shown per message (hover), per session header, per project/space/agent, and a global **Usage** page (by day, mode, model). CSV export.
- **CO3** Optional global monthly budget with alerts. Agents have their own hard caps (06-agents §9).

## 2. Skills
- Pi's skills format (`SKILL.md` folders). Discovered from pi's standard locations (so CLI skills just work) plus `~/Library/Application Support/Piopio/skills/`.
- Settings › Skills: list, enable per mode/project/space/agent, install from git/npm (pi packages), and create new (opens a Build session with a skill-authoring prompt).
- Agents bundle their enabled skills on deploy (copied into the definition bundle).

## 3. Prompt templates
- Pi prompt templates are surfaced as `/commands` in every composer. Piopio adds a small built-in set (e.g. `/summarize`, `/explain`, `/review`).

## 4. MCP servers
- **MCP1** Registry in Settings › MCP: name, transport (stdio for local only; streamable HTTP for local + cloud), command/URL, auth (header token or OAuth), enabled scopes (Build / Chat / Spaces / Agents / specific projects).
- **MCP2** Local: in Build via `createMcpExtension()`. For pi-durable runtimes (Threads/Spaces/Agents), via a Piopio MCP extension that maps MCP tools to `defineTool` (with `deferred: true` + tool-search when there are many tools).
- **MCP3** Cloud agents can only use **remote (HTTP) MCP servers**. stdio servers are flagged "local only".
- **MCP4** Tool calls from MCP servers go through the same approval policies (write-like tools ask by default in Chat/Agents).

## 5. Memory (global, Chat)
- **GM1** Opt-in "About me" memory: a user-editable markdown doc plus auto-captured facts (only when enabled, and every write is shown).
- **GM2** Injected as a system section in Threads and Spaces (configurable), never in Build unless enabled per project.
- **GM3** Agents have their own memory (06-agents §8). They can be granted read access to global memory, but it's off by default.
- **GM4** Long-term memory goes through a **memory provider** (§5.1), so a stronger engine such as Hindsight can replace the built-in one without changing Threads, Spaces or Agents.

### 5.1 Memory providers
A **memory provider** stores what conversations learn and finds it again later. `@piopio/runtime` defines one interface. The engine (local) and the Cloud Engine pick an implementation per **bank**. A bank is an isolated store: "About me", one Space, or one agent partition.

```ts
interface MemoryProvider {
  retain(bank, { content, source: { ref, itemId }, at, tags? }): Promise<{ ids }>   // learn from a message or a run
  recall(bank, query, { budgetTokens, types?, since? }): Promise<MemoryHit[]>         // ranked facts, packed to a budget
  reflect?(bank, question): Promise<{ answer, used: MemoryHit[] }>                    // an answer reasoned over the bank
  list(bank, { cursor, kind? }): Promise<Page<MemoryRecord>>                          // the memory view: every stored fact
  forget(bank, id): Promise<void>
  standing?(bank): Promise<{ question, answer, updatedAt }[]>                         // pre-computed answers (cheap system section)
}
type MemoryRecord = { id, text, kind: "fact" | "experience" | "observation" | "opinion", source?, createdBy: "agent" | "user" | "extraction", at, confidence? }
```

Every record keeps its source, and the app's memory views list it (01-product, principle 4: every memory write is visible). A provider that writes on its own, in the background (extracted facts, consolidated observations), must report those writes, through `list` or by pushing them, so the views and an Undo can show them.

| Provider | What it is | Where |
|---|---|---|
| **Built-in** (default) | Markdown doc plus records in the engine's SQLite. Retrieval is recency + keyword (FTS) with a token budget. `reflect` and `standing` are absent. | Local and cloud (Durable Object SQLite) |
| **MCP memory** (opt-in, §6.2) | Any memory system with an MCP server: its tools mapped to recall/retain/list/forget. | Wherever the server runs (local process or URL) |
| **Hindsight** (opt-in) | [vectorize-io/hindsight](https://github.com/vectorize-io/hindsight), MIT. Retain extracts facts, entities and time with an LLM. Recall merges four channels (vector, BM25, entity graph, time) and reranks them. Reflect answers over the bank. Mental models act as standing answers. One Hindsight bank per Piopio bank. | **Local:** a Hindsight daemon the engine starts and supervises (Python via `uv`, embedded Postgres with pgvector), only after the user turns it on (it downloads its runtime). **Remote:** a URL, either self-hosted or Hindsight Cloud (sends memories to Vectorize; explicit opt-in). |

- **Models:** the provider uses the user's OpenRouter key. Extraction runs on the utility model slot (07 §1.3); embeddings run locally or through OpenRouter. No other key is needed.
- **Settings › Chat › Memory:** provider (Built-in / Hindsight local / Hindsight remote URL), status, disk use, per-bank wipe and export.
- **Fallback:** if a provider is unreachable, conversations go on without memory and show a note. Nothing blocks on memory.
- **Fit, in order:** (1) **Agents** (06 §8): long-lived, many people, schedules; recall across months matters most there. (2) **About me** (GM1): facts captured across Threads. (3) **Spaces:** the curated memory doc (04-chat S8) stays the source of truth; a provider may index topic histories later, for semantic `search_space`. Build keeps AGENTS.md and pi's own conventions.
- Spike **S6** (2026-10-21, [docs/spikes/s6](../spikes/s6/README.md)) kept the built-in provider as the default. Hindsight locally: about 2 GB of opt-in download (uv, Python, wheels, models, Postgres, none of it in the signed bundle); about 300 ms recall; about $0.07 per 100 messages retained; `HINDSIGHT_API_LLM_OPENAI_COMPATIBLE_JSON_MODE=false` with OpenRouter. Each turn uses recall; reflect (about 7 s) is a tool.

## 6. Extensions
Piopio has **no plugin format of its own**. You extend it with what pi and the wider ecosystem already use, and the app makes those visible and manageable (decision AQ12):

| Kind | What it adds | Where it runs | Managed in |
|---|---|---|---|
| **MCP servers** (§4) | Tools: an API, a database, an app, a memory system | Build (through pi's MCP extension); Threads, Spaces and Agents (through the engine's MCP bridge, 04-chat 3.4) | Settings › MCP servers |
| **pi packages** (§6.1) | pi extensions (tools, hooks, commands), skills, prompt templates, themes | Extensions: Build only. Skills and prompt templates: everywhere | Settings › Extensions |
| **Memory providers** (§5.1, §6.2) | Long-term memory: the built-in one, Hindsight, or any memory system that has an MCP server | Agents, About me, later Spaces | Settings › Chat › Memory, and per agent |

Why not a Piopio plugin API: in-process plugins would run third-party code inside the engine, with access to every conversation and key. They would need a stable API we'd have to keep, and they would split the ecosystem. MCP servers run in their own processes with only what they're given, and pi packages are pi's to define. Piopio's own extensions (approvals, checkpoints, plan, todos, subagents, the Space organizer…) stay bundled, written in the runtimes' own formats.

### 6.1 pi packages (Settings › Extensions)
- **EX1** The list shows the user's packages (`~/.pi/agent/settings.json`, shared with the pi CLI) and, per project, the project's (`.pi/settings.json`, loaded only for trusted projects, 05-build). Each package shows its source (npm, git, local), pinned version, and what it brings: extensions, skills, prompt templates, themes.
- **EX2** **Install** from an npm name, a git URL or a local folder, with pi's own package manager (`DefaultPackageManager`, the code behind `pi install`), so the CLI and the app see the same packages. **Update** and **Remove** too. Before installing, a sheet says what the package contains and that extension code runs with the user's permissions. It links the source, and nothing installs without a click.
- **EX3** **Per package, on or off**, and per resource where pi allows it. Changes reach new Build sessions; open ones offer to reload.
- **EX4** Where each resource works: **pi extensions run in Build only.** Threads, Spaces and Agents run on pi-durable, which can't load pi extensions, and stay on Piopio's own extensions (user-installable pi-durable extensions wait until that format is stable upstream). **Skills and prompt templates work everywhere**, because they are text: Chat and Agents list a package's skills (name and description in the prompt, the body read on demand) and its templates as `/commands`. Themes are ignored (Piopio has its own look).
- **EX5** Extensions with a terminal UI show "This extension has a terminal UI that Piopio can't display" (05-build). Their tools, hooks and commands still work.
- **EX6** A small catalog of recommended packages, including Piopio's own `@piopio/pi-extensions` for the CLI, links to the pi package gallery (pi.dev/packages).

### 6.2 Memory over MCP
Many memory systems already ship an MCP server (Hindsight serves one per bank). The **MCP memory provider** turns such a server into a memory provider without code for each system:
- **MM1** Settings › Chat › Memory › Add provider › "MCP server": pick a server from §4, then map its tools to the provider's operations. `recall` is required; `retain`, `list`, `forget` and `reflect` are optional. Each mapping is a tool name and an argument template, with `{bank}`, `{query}`, `{content}`, `{source}` and `{at}` placeholders. Presets fill in the mapping for servers we have tested; the first is Hindsight's (`/mcp/{bank_id}/`).
- **MM2** Banks map to whatever the server uses (a bank id, a user id, a namespace), through the `{bank}` placeholder or one server URL per bank.
- **MM3** **Transparency depends on the server.** Without a `list` tool, Piopio can't show what the server stored. The provider is then marked "limited visibility" in Settings and in the memory view, which shows the turn's retain calls instead. Without `forget`, deleting is done in the memory system itself.
- **MM4** Native adapters (Hindsight's REST API, the built-in provider) stay preferred where they exist: they have listing, editing, history and webhooks. MCP memory is the way in for everything else.

## 7. Settings map
| Section | Contents |
|---|---|
| General | Appearance, launch at login, background mode, Quick Chat hotkey, default mode |
| Models | OpenRouter key, defaults per slot, favorites, budget |
| Build | Default approval mode, rules, editors, worktree location, checkpoint retention, git identity |
| Chat | Default tools, web search provider, attachment limits, memory |
| Agents | Cloud connection, channels credentials, default policies |
| Skills / MCP / Extensions | MCP servers (§4, with "In Chat"), pi packages (§6.1) |
| Cloud | Cloudflare account, deploy status, upgrade, rotate token, teardown |
| Advanced | Engine logs, custom engine path, data folder, export all, reset |

## 8. Onboarding (first launch)
1. Welcome → paste OpenRouter key (validated with a cheap call) → saved in Keychain.
2. Pick defaults (suggested models preselected).
3. "What do you want to do first?" → New thread / Add a project / Create an agent.
4. Cloud setup is **deferred** until the user deploys the first agent.
