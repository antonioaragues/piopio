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
| **Hindsight** (opt-in) | [vectorize-io/hindsight](https://github.com/vectorize-io/hindsight), MIT. Retain extracts facts, entities and time with an LLM. Recall merges four channels (vector, BM25, entity graph, time) and reranks them. Reflect answers over the bank. Mental models act as standing answers. One Hindsight bank per Piopio bank. | **Local:** a Hindsight daemon the engine starts and supervises (Python via `uv`, embedded Postgres with pgvector), only after the user turns it on (it downloads its runtime). **Remote:** a URL, either self-hosted or Hindsight Cloud (sends memories to Vectorize; explicit opt-in). |

- **Models:** the provider uses the user's OpenRouter key. Extraction runs on the utility model slot (07 §1.3); embeddings run locally or through OpenRouter. No other key is needed.
- **Settings › Chat › Memory:** provider (Built-in / Hindsight local / Hindsight remote URL), status, disk use, per-bank wipe and export.
- **Fallback:** if a provider is unreachable, conversations go on without memory and show a note. Nothing blocks on memory.
- **Fit, in order:** (1) **Agents** (06 §8): long-lived, many people, schedules; recall across months matters most there. (2) **About me** (GM1): facts captured across Threads. (3) **Spaces:** the curated memory doc (04-chat S8) stays the source of truth; a provider may index topic histories later, for semantic `search_space`. Build keeps AGENTS.md and pi's own conventions.
- Whether Hindsight becomes the default depends on spike **S6** (09-roadmap).

## 6. Extensions
- Pi packages installed via Settings › Extensions apply to **Build** (pi-coding-agent).
- pi-durable runtimes use pi-durable's own extension format (`defineExtension`). Piopio-provided ones only in v1. User-installable pi-durable extensions come later, once the upstream format stabilizes.

## 7. Settings map
| Section | Contents |
|---|---|
| General | Appearance, launch at login, background mode, Quick Chat hotkey, default mode |
| Models | OpenRouter key, defaults per slot, favorites, budget |
| Build | Default approval mode, rules, editors, worktree location, checkpoint retention, git identity |
| Chat | Default tools, web search provider, attachment limits, memory |
| Agents | Cloud connection, channels credentials, default policies |
| Skills / MCP / Extensions | As above |
| Cloud | Cloudflare account, deploy status, upgrade, rotate token, teardown |
| Advanced | Engine logs, custom engine path, data folder, export all, reset |

## 8. Onboarding (first launch)
1. Welcome → paste OpenRouter key (validated with a cheap call) → saved in Keychain.
2. Pick defaults (suggested models preselected).
3. "What do you want to do first?" → New thread / Add a project / Create an agent.
4. Cloud setup is **deferred** until the user deploys the first agent.
