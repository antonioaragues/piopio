# 14 · Memory (spike S8, 2026-10-24)

**Status (2026-10-25):** M1 (hybrid recall) and M2 (learned facts for agents) are built, and M0 has measured them; see §7. Decisions: Q2 save and show with Undo; Q4 OpenRouter embeddings by default, with Keep memory on this Mac as the opt-out. Q1 and Q3 wait for M4 and M5.

The question: how should Piopio's memory get better, where does a project like Hindsight fit, should memory have
its own Settings section, and which kinds of memory belong in which part of the product (Chat, notebooks, agents,
Build projects)? This spike reviews what we have, evaluates ten projects, measures one building block, and proposes
milestones. Nothing in the product changes yet.

**Short answer:**
- **Make the built-in provider better before adding systems.** Add semantic search (embeddings stored in SQLite,
  measured in [S8](../spikes/s8/README.md)) and **learned facts that can be replaced** (Valencia → Madrid), using the
  utility model. Both run on the Mac and in a Durable Object. Independent evaluations suggest this is most of the gain
  at a small fraction of the cost.
- **Hindsight stays the advanced, opt-in engine**, for agents that live for months. Remote URL first, then the local
  daemon (S6). It's the only project evaluated that fits Piopio's transparency rule as well as ours does.
- **Yes to Settings › Memory**, a top-level section. Memory now spans chats, notebooks, agents and projects, and its
  settings are spread over Settings › Chat, each agent's definition and each notebook.
- **Each area gets the kinds of memory it needs.** Chat: About me plus search of past chats. Notebooks: the curated
  memory doc plus semantic search over topics. Agents: learned facts per person. Build: lessons written to files in
  the repo, never a hidden store.

## 1. What Piopio has today

| Where | What it remembers | How | Gaps |
|---|---|---|---|
| **About me** (07-shared §5) | Facts about you, by section | Records in the `about-me` bank, tagged with the section. `remember_about_me` when learning is on. Shown to chats and notebooks, and to agents with `aboutMe.inAgents`. Settings › Chat. | Learned facts pile up: nothing notices that a new fact replaces an old one. |
| **Threads** | Nothing but About me | — | No recall across chats ("what did we decide last week about…"). |
| **Notebooks** (04-chat §3.2) | A shared memory doc | Markdown with sections, revisions and authors, proposals from topics, the first 4,000 characters in each prompt. `search_space` is a substring/FTS search over topic histories. | Search misses paraphrases. |
| **Agents** (06-agents §8) | Messages and facts per person | A bank per partition (`owner`, `shared`, `contacts/<id>`). Before each turn, `recall` puts up to 1,200 tokens in the system section. After it, the person's message and the answer are retained word for word. Tools: `remember`, `recall`, `forget`. The provider is chosen per agent (`memory.provider`). | Banks grow with raw messages. A fact that changed is found next to its old value. No semantic recall. |
| **Build** (05-build) | `AGENTS.md`/`CLAUDE.md`, read by pi | Files in the repo. Checkpoints and compaction are not memory. | The agent learns nothing from one session to the next. |
| **Providers** (07-shared §5.1) | — | **Built-in:** SQLite, FTS5 BM25 with a recency boost, pins, history. Stores what it's given; no extraction. **MCP memory:** any server's tools mapped to recall/retain/list/forget, with a Hindsight preset. The native Hindsight adapter (milestone 4.7) isn't built. | No semantics, no notion of time beyond recency. |

Spike S6 (2026-10-21) compared the built-in provider with Hindsight on 200 messages: 29/30 against 30/30. The one
miss is the gap that matters: "Which city does Alex live in now?" got Valencia, because "I live in Valencia" shares
the question's words and "we're moving to Madrid" doesn't.

## 2. Kinds of memory, and where each belongs

| Kind | What it is | Example | Best form | Where in Piopio |
|---|---|---|---|---|
| **Profile** | Stable facts and preferences about you | "Vegetarian", "Works at Acme", "Prefers short answers" | A small curated list, always in the prompt | About me: chats and notebooks; agents if you allow it. Build only per project, opt-in (GM2). |
| **Episodic** | What was said, when, by whom | "Last Tuesday we compared three flights" | Raw messages, searched on demand | Past chats in Threads; each person's conversation with an agent; topic histories in notebooks. |
| **Learned facts** | Atomic facts that change over time | "Alex lives in Madrid (since March; before: Valencia)" | Records with a time and what they replace | Agents (most), About me when learning is on. |
| **Shared knowledge** | What a group of conversations agrees on | Decisions, budget, contacts of a renovation | A document people edit, with history | The notebook memory doc (exists). For projects, `AGENTS.md`. |
| **Procedural** | How to do things; lessons | "Run `pnpm test:swift` after changing PiopioKit", "Ledger: invoices go to the accountant on the 1st" | Files, versioned | Build project lessons; agent instructions and skills. |
| **Working** | The current conversation | — | The context window and compaction | pi handles it. Out of scope here. |

**One rule follows from 01-product principle 4 (every memory write is visible):** memory that **people curate** is a
document (markdown, versioned, edited in place: About me, the notebook doc, `AGENTS.md`); memory that **machines
accumulate** is a store of records with sources, where each write shows in the conversation with Undo and can be
browsed, edited and deleted later.

## 3. Projects evaluated

Benchmark numbers below are the vendors' own unless marked otherwise. See §3.1 before reading anything into them.

| Project | What it is | License, runtime | Transparency | Fit for Piopio | Verdict |
|---|---|---|---|---|---|
| [Hindsight](https://github.com/vectorize-io/hindsight) (Vectorize) | Retain extracts facts, entities and time; recall fuses vector, BM25, entity graph and time with a reranker; reflect answers over a bank; observations and mental models consolidate. LongMemEval 91.4% with Gemini 3 Pro, 83.6% with a 20B open model ([paper](https://arxiv.org/abs/2512.12818)). | MIT. Python + embedded Postgres, about 2 GB locally (S6). MCP server, HTTP API, Hindsight Cloud. | **Best of the set:** list, edit, invalidate (kept for audit), history of observations, webhooks, dry-run extraction. | Good for agents with long histories. Too heavy as a default (S6: 2 GB outside the signed bundle, 17 s warm start). Can't run in a Durable Object; cloud agents need a URL. | **Keep as the advanced opt-in engine** (milestone 4.7, unchanged). |
| [Mem0](https://github.com/mem0ai/mem0) | Extracts facts per message and decides ADD / UPDATE / DELETE / NONE against similar existing ones. Optional graph memory. Reports 94.4% LongMemEval, 92.5% LoCoMo; an independent blog got 32.4% from the open-source edition ([dev.to](https://dev.to/everest_an/-i-benchmarked-ai-agent-memory-in-2026-and-the-numbers-tell-a-different-story-than-the-marketing-2ae4)). | Apache-2.0. Python and a TypeScript SDK (`mem0ai/oss`, runs in Node) with pluggable vector stores. OpenMemory MCP. | History in the cloud product; the open-source edition is thinner. | The TS SDK could run in the engine, but it brings its own vector store and prompts, and wouldn't run on DO SQLite as is. | **Borrow the update decision** (ADD/UPDATE/DELETE/NONE) for learned facts; don't depend on it. |
| [Graphiti](https://github.com/getzep/graphiti) / [Zep](https://www.getzep.com) | A temporal knowledge graph: every edge has when it became true and when it stopped (bi-temporal). Hybrid search. Zep 71.2% LongMemEval with GPT-4o in independent comparisons. | Graphiti Apache-2.0, Python, needs Neo4j or FalkorDB (Kuzu deprecated). Zep's service runs on a proprietary graph engine. | Good (episodes keep their sources). | A graph database on a Mac, or in a Worker, is too much for what we gain. | **Borrow the time model** (`validFrom`, replaced by) for learned facts. |
| [Letta](https://www.letta.com) (MemGPT) | A full agent framework. Memory moved from memory blocks to **context repositories**: git-backed markdown files, edited by the agent and by background "sleep-time" subagents that review recent conversations and write lessons ([blog](https://www.letta.com/blog/context-repositories)). | Apache-2.0. Python server, or Letta Cloud. | Very good: every change is a commit. | As a runtime it would replace pi-durable, which we won't do. The design fits Build exactly. | **Borrow for Build:** project lessons as files, written after the turn, reviewed as a diff. |
| [Cognee](https://www.cognee.ai) | A memory platform that builds a knowledge graph from documents, code and records. 1.0 in June 2026 (`remember`, `recall`, `improve`, `forget`). | Apache-2.0. Python, several stores. | Medium. | Strongest on documents, not conversations. Possibly notebook files later. | **Not now.** Reachable through MCP for anyone who wants it. |
| [Supermemory](https://supermemory.ai) | A hosted memory and RAG API with user profiles and connectors. | MCP and SDKs MIT/Apache; whether the self-hosted server is open source is disputed ([review](https://www.developersdigest.tech/agent-memory/supermemory)). | Through its API. | Sends your memory to a third party by default. | **An MCP preset at most.** |
| [Basic Memory](https://github.com/basicmachines-co/basic-memory) | Markdown files are the memory (entities, observations, wiki links), indexed in local SQLite with semantic search; read and written over MCP. | AGPL-3.0. Python. | Excellent: they're your files. | Same philosophy as our notebook doc and Build lessons. AGPL rules out embedding it. | **Inspiration, plus an MCP preset.** |
| [Cloudflare Agent Memory](https://developers.cloudflare.com/agents) | Managed memory on Durable Objects, Vectorize and Workers AI: facts, events, instructions, tasks; full-text, vector and HyDE fused with RRF. Announced April 2026, private beta. | Proprietary, Cloudflare only. | Has list and forget. | Interesting for cloud agents (Phase 5), but beta and Cloudflare-only, and our provider must work on the Mac too. | **Watch.** Our built-in provider on DO plus Workers AI or OpenRouter embeddings covers the same ground. |
| Claude's [memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) | A client-side tool: the model reads and writes files under `/memories`; the app decides where they live. | API feature (Anthropic models). | Files you can read. | A pattern, not a dependency. pi-ai doesn't expose provider tool types (see 11-computer-use §2), and the same idea works as ordinary tools with any model. | **Same shape as Build lessons**, through our own tools. |
| ChatGPT memory | **Saved memories** (always in context, listed and deletable) and **Reference chat history** (looks things up in past chats, not listed). Separate toggles; Temporary Chat uses and creates none ([FAQ](https://help.openai.com/en/articles/8590148-memory-faq)). | Product reference. | Saved memories visible; chat history opaque. | The UX model people know. | **Copy the split** (About me vs past chats, toggles, temporary chat). Don't copy the opacity: past-chat recall shows what it used. |

### 3.1 What the independent evidence says
- **Almost every LongMemEval and LoCoMo score is self-reported**, and the same system's scores differ a lot between
  sources (Mem0 94.4% vs 32.4% for the open-source edition; Zep 90.2% vs 71.2%).
- **MemDelta** ([arXiv 2606.29914](https://arxiv.org/abs/2606.29914), June 2026) controls one variable at a time.
  Swapping only the **embedding model** moved accuracy by 6.2 points, enough to flip rankings. Mem0 matched plain
  retrieval with a good cloud embedding on 2 of 6 question types, at about **50× the write cost**. An agent writing
  its own memory scored 42%, against 47% for basic retrieval of the raw messages.
- **Ground Truth First** ([arXiv 2607.21962](https://arxiv.org/abs/2607.21962), July 2026) follows simulated users
  for nine weeks. At short horizons, the full history in the prompt ties or beats memory systems. Over weeks, a
  budgeted summary loses what it evicts (96% → 72% recall), while a store that keeps sources and types gains
  (90%). A hybrid led overall (86.4%). One preprint on synthetic data, not replicated.
- **Our own S6** agrees: at 200 messages, keyword search over raw messages nearly matched Hindsight.

**So:** the cheap, general win is **hybrid retrieval with a good embedding** over what we already store. Extraction
and consolidation pay off over long horizons and changing facts, which is the agents' case, and should be spent
there. And memory systems should be compared on our data, with the embedding held fixed (milestone M0).

### 3.2 Local models
- **Embeddings on the Mac:** possible with ONNX models through `onnxruntime-node` or transformers.js, or Apple's
  Natural Language embeddings through the app. Costs a download (tens to hundreds of MB), and small local models are
  the ones that lost in MemDelta. **An option for privacy, not the default.**
- **Extraction on the Mac:** the utility model slot already prefers Apple's on-device model (07-shared §1.3). It's
  free and private, with an 8k-token window. macOS 27 reportedly adds an `fm` command-line tool, which the engine
  could call without the app open (third-party report; to verify). Fine for "is there a new fact in this turn?",
  to be checked against the cloud utility model in M0.

## 4. Measurement: semantic search in the built-in provider

[S8](../spikes/s8/README.md) stored vectors as BLOBs in SQLite and scanned them in JavaScript, with no extension, so
the same code runs on `node:sqlite` and on a Durable Object's storage. With **256 dimensions in int8**, a bank of
**10k records** is 2.7 MB and **9 ms** per query, and **50k records** is 13 MB and **44 ms**, on a 2.1 GHz Xeon. The
nearest vector came back first in every query. On an Apple M4 the same scan takes 1.9 ms and 9.7 ms. That's enough for every bank we have (a person's bank or About me
stays under 10k records; a busy agent's whole history may reach 50k over years). Beyond that, an approximate index or
Hindsight.

## 5. Proposal

### 5.1 Three engines, one interface
`MemoryProvider` (07-shared §5.1) stays. What changes is what the built-in provider can do, and how you choose.

| Engine | What it does | Cost | Where it runs |
|---|---|---|---|
| **Basic** (today) | Keyword (FTS5 BM25) + recency. Stores what it's given. | Free, offline | Mac, Durable Object |
| **Standard** (new default when an embedding model is set) | **Hybrid recall:** BM25 and vector results fused with reciprocal rank fusion, plus recency and pins. **Learned facts:** after a turn (batched, off the reply path), the utility model extracts atomic facts and compares each with the most similar existing ones: add, replace, forget or nothing (Mem0's decision). A replaced fact is kept, marked with what replaced it and when (Graphiti's time model), so the history and Undo can show it. | Embeddings about $0.02 per million tokens (`text-embedding-3-small` at 256 dimensions), well under a cent per 100 messages. Extraction an estimated $0.01 per 100 messages on a cheap utility model, against S6's $0.07 for Hindsight (estimate; M0 measures it). Free with the on-device model. | Mac, Durable Object |
| **Hindsight** (advanced, opt-in) | Everything above plus entity graph, observations, mental models (as `standing` answers) and `reflect` as a tool. | S6: ~$0.07 per 100 messages; 2 GB locally | A URL (self-hosted or Hindsight Cloud), or the local daemon (local agents only) |
| **Other MCP memory** (exists) | Any server, mapped. Presets for Hindsight (exists), Basic Memory, Mem0 OpenMemory. | Theirs | Theirs |

Standard needs an embedding model. With OpenRouter or OpenAI connected it defaults to a small cloud model; without
one, or with "Keep memory on this Mac" on, it uses a downloaded local model, or stays Basic. Embeddings are computed
when a record is written, and a "Rebuild index" re-embeds a bank when the model changes.

### 5.2 By area

| Area | Remember | Kinds | Engine | Default |
|---|---|---|---|---|
| **Chats (Threads)** | About me (exists). **Past chats (new):** messages indexed in a `chats` bank; a `search_chats` tool the model calls when you refer to earlier conversations; its results show as a card ("Looked in 3 past chats") with links. A **temporary chat** neither reads nor writes memory. | Profile, episodic | Standard | About me as today. Past chats off until you turn it on (a question for you, §6). |
| **Notebooks** | The memory doc stays the source of truth (proposals, revisions). **`search_space` becomes semantic** over topic replies (already planned in 04-chat §3.2). | Shared knowledge, episodic | Standard for search; the doc needs no engine | On |
| **Agents** | Per-person banks (exists). **Learned facts** per person with replacement, instead of only raw messages; raw messages stay searchable for `recall`. Per agent: Standard or Hindsight. | Learned facts, episodic, procedural (instructions) | Standard; Hindsight for long-lived agents | Standard |
| **Build projects** | **Project lessons:** at the end of a session (or with `/remember`), the agent proposes lines for the project's instructions: commands, conventions, pitfalls. They show as a diff you accept, edit or dismiss, then go into `AGENTS.md` or a local file (§6). Plus About me's coding preferences, only when a project turns it on (GM2). | Procedural | No provider: files and git | Proposals on, writes always ask |
| **Cloud agents** (Phase 5) | The same banks on DO SQLite. Embeddings through OpenRouter, or Workers AI inside Cloudflare. Hindsight only as a URL (06-agents ME2b). | As agents | Standard on DO; Hindsight URL | Standard |

### 5.3 Settings › Memory
**Yes: a top-level section**, right after Chat (General, Models, Connectors, Chat, **Memory**, Approvals, …). Memory spans four areas, it's where trust is decided, and
today its settings are split across Settings › Chat (About me, providers), each agent's definition and each
notebook. The places keep their own switches (an agent's Setup › Memory, a notebook's settings, a project's
settings) with a link here.

1. **What Piopio remembers:** counts per area (About me facts, past chats indexed, notebooks, agents, projects),
   disk use, and **Browse…**, one view over every bank with search, source, edit, forget and history.
2. **About me** (moved from Chat): the fact list, Share with, Learn from conversations.
3. **Past chats:** Search past chats, Include notebooks.
4. **Engine:** Basic / Standard / Hindsight / other MCP memory, with a status line ("Standard · 4,210 records ·
   embeddings: OpenAI small via OpenRouter"). Embedding model (cloud models, or On this Mac with its download size).
   The learning model is the utility model (link to Models). Advanced: an engine per area.
5. **Learning:** per area, Learn automatically or Only when asked. Learned facts always show in the conversation with
   Undo (as today).
6. **Privacy:** Keep memory on this Mac (local embeddings and extraction only), never remember (topics or words),
   and a plain list of what goes where (OpenRouter for embeddings, Hindsight Cloud if chosen).
7. **Data:** export everything (JSON and Markdown), wipe per area or bank, rebuild index.

Each turn's inspector also shows **what was recalled** for that turn, in chats, notebooks and agents (agents already
put it in their `agent-memory` system section, but the app doesn't show it): nothing gets into a prompt without a
way to see it.

### 5.4 Interface changes
- `MemoryRecord` gains `validFrom?`, `replacedBy?` / `replaces?` and `about?` (the person or thing the fact is
  about). `MemoryCapabilities` gains `semantic` and `learns`.
- `RetainInput` gains `learn?: boolean` (extract facts from this content, or store it as it is).
- The built-in provider stores vectors in a `memory_vectors` table (record id, model, int8 BLOB) and keeps one typed
  array per bank in memory (S8).
- Settings: `memory.engine`, `memory.embeddings`, `memory.areas.{chats,notebooks,agents,projects}`,
  `memory.localOnly`. Protocol: `memory.banks`, `memory.browse`, `memory.export`, `memory.wipe`, `memory.reindex`.

### 5.5 Milestones
| | Scope | Needs |
|---|---|---|
| **M0** Our own test set | The harder set already planned in 4.7: 2,000+ messages over months, paraphrased questions, facts that change several times, questions across past chats. Basic, Standard with two embedding models, Standard with the on-device utility model, and Hindsight, all answered by the same model. Reports accuracy, write cost and latency. | Your OpenRouter key (about $2 in total) |
| **M1** Hybrid recall | Embeddings in the built-in provider, the vector table, RRF fusion, backfill of existing banks, the same code on DO SQLite. | — |
| **M2** Learned facts | Extraction and the add/replace/forget/nothing decision on the utility model, batched after turns; replaced facts in the history; cards with Undo. For agents and About me. | — |
| **M3** Settings › Memory | The section above; About me and providers move there; Browse; export, wipe, rebuild. | — |
| **M4** Past chats and notebooks | The `chats` bank, `search_chats` with its card, temporary chat; semantic `search_space`. | — |
| **M5** Project lessons | Proposed lessons at the end of a Build session and `/remember`, as a diff into the project's instructions. | Your answer to §6 Q3 |
| **M6** Hindsight adapter | 4.7 as planned: remote URL first, then the local daemon. M0 says whether it earns more than opt-in. | — |

M1 and M2 come first because every area benefits, including cloud agents in Phase 5. M3 makes it all visible
before Past chats (M4) starts indexing more of your data.

### 5.6 What not to do
- **No graph database** (Graphiti, Neo4j, FalkorDB): heavy, Python, not on a Durable Object. Borrow its time model.
- **No Letta as a runtime:** it would replace pi-durable. Borrow its memory-as-files for Build.
- **Hindsight is not the default:** 2 GB outside the signed app, and no measured gain at our scale yet (S6). M0
  decides.
- **No hosted memory by default** (Supermemory, Hindsight Cloud): your memories would go to a third party. Opt-in only.
- **Not Cognee now:** document knowledge graphs are a notebook-files question for later.
- **No local embeddings by default:** download size, and small models lose on quality (MemDelta). An option.

## 6. Questions for you
- **Q1 · Past chats:** off until you turn it on (more private), or on like ChatGPT (more useful from day one)?
- **Q2 · Learning:** keep "save it and show it with Undo" (today), or offer "ask before saving" as well?
- **Q3 · Project lessons:** into `AGENTS.md` (committed, shared with whoever uses the repo), or a local file that
  isn't committed (`.pi/` or `AGENTS.local.md`, read only by Piopio)?
- **Q4 · Embeddings in the cloud:** is sending text to OpenRouter's embedding models acceptable as the default, with
  "Keep memory on this Mac" as the opt-out?

## 7. What's built (2026-10-25)

**M1 · Hybrid recall**
- **Vectors:** `BuiltinMemory` takes an embedder; every record gets an int8 vector in `memory_vectors`.
- **Recall:** BM25 and vector rankings fused with reciprocal rank fusion (k = 60), with a 0.3 similarity floor, then recency, pins and a 1.3× weight for current facts.
- **Where it runs:** the same code on the Mac and on a Durable Object (the cloud tests pass).
- **The embedder:** `openai/text-embedding-3-small` at 256 dimensions through OpenRouter, else the OpenAI API key, else keyword-only. A failure pauses semantic search for a minute.
- **Backfill:** records written offline or before M1 get their vectors in the background.
- **Settings:** `memory.localOnly` (Keep memory on this Mac), `memory.embeddings` (another endpoint); `memory.status`.

**M0 · Our own test set**
- **The set:** 2,018 messages over six months, 40 questions: [packages/engine/test/memory-eval](../../packages/engine/test/memory-eval/README.md).
- **Answers right:** keyword 25/40, hybrid 38/40, large embeddings 39/40, hybrid with learned facts 39/40.
- **Cost:** embeddings $0.004 for the whole set; learning $0.06 for six months.
- **Not run:** Hindsight (not installed; S6's numbers stand) and the on-device utility model.

**M2 · Learned facts (agents)**
- **When:** after a person's conversation is quiet for 90 s (or after 6 exchanges), the utility model extracts facts.
- **How it decides:** each fact is compared with the closest current facts: add, replace, end or nothing.
- **History:** replaced facts keep `replacedBy` and `endedAt`, and recall leaves them out.
- **Visible:** each step writes a `piopio.learned` entry, shown as a memory card ("Learned", "Updated memory: … (was: …)") with Undo, which restores what it replaced.
- **Per agent:** `memory.learn` (default on).
- **About me** keeps `remember_about_me` with add and remove; automatic extraction there is not built.

**M3 · Settings › Memory**
- **The section:** after Chat ([screenshots](../design/memory/screenshots)).
  - **What Piopio remembers:** About me (its editor moved here from Settings › Chat), each agent with facts and messages, notebooks.
  - **Memory search:** M1's status and Keep memory on this Mac.
  - **Learning:** Chats add to About me, and a switch per agent (`memory.setLearning`, saved in the definition's history).
  - **Your data:** Export everything (memory.json and memory.md), Rebuild search index, and Erase one part or everything (with confirmation).
- **Browse:** every bank in one window.
  - Search by meaning or words.
  - Facts / Messages / All, and Replaced with what replaced what.
  - The history.
  - Pin, correct (kept as a replacement), forget, and add.
- **Protocol:** `memory.banks`, `memory.history`, `memory.export`, `memory.wipe`, `memory.reindex`, `memory.setLearning`; `memory.list` gained `query` and `includeEnded`; `memory.add` gained `replaces`.
- **Not built yet:**
  - the "what was recalled" line in each turn's inspector;
  - per-area engines;
  - "never remember" topics;
  - local embeddings.

**Follow-ups:**
- a periodic tidy-up pass over an agent's facts (stale facts M0 found);
- M4 (past chats, semantic `search_space`);
- M5 (project lessons, after Q3);
- M6 (Hindsight).

## Sources
- Hindsight: [repository](https://github.com/vectorize-io/hindsight), [announcement](https://vectorize.io/blog/introducing-hindsight-agent-memory-that-works-like-human-memory), [paper](https://arxiv.org/abs/2512.12818); our [S6](../spikes/s6/README.md).
- Mem0: [open-source docs](https://docs.mem0.ai/open-source/overview), [TS SDK release](https://newreleases.io/project/github/mem0ai/mem0/release/ts-v3.1.0), [their benchmark overview](https://mem0.ai/blog/state-of-ai-agent-memory-2026), [independent test](https://dev.to/everest_an/-i-benchmarked-ai-agent-memory-in-2026-and-the-numbers-tell-a-different-story-than-the-marketing-2ae4).
- Graphiti: [PyPI](https://pypi.org/project/graphiti-core/0.29.3/), [review](https://codex.danielvaughan.com/2026/03/30/graphiti-agent-memory-store/).
- Letta: [context repositories](https://www.letta.com/blog/context-repositories), [MemFS docs](https://docs.letta.com/letta-code/memfs).
- Cognee: [1.0 announcement](https://www.cognee.ai/blog/cognee-news/cognee-1-0-announcement).
- Supermemory: [self-hosting](https://supermemory.ai/docs/self-hosting), [review](https://www.developersdigest.tech/agent-memory/supermemory).
- Basic Memory: [docs](https://docs.basicmemory.com/reference/technical-information), [repository](https://github.com/basicmachines-co/basic-memory).
- Cloudflare Agent Memory: [Agents docs](https://developers.cloudflare.com/agents), [release note](https://ai-tldr.dev/releases/cloudflare-agent-memory/).
- Claude memory tool: [docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool).
- ChatGPT memory: [FAQ](https://help.openai.com/en/articles/8590148-memory-faq), [saved memories](https://help.openai.com/en/articles/11146739-how-does-reference-saved-memories-work).
- Evaluations: [MemDelta](https://arxiv.org/abs/2606.29914), [Ground Truth First](https://arxiv.org/abs/2607.21962), [benchmarks overview](https://mem0.ai/library/agent-memory/ai-memory-benchmarks-in-2026) (vendor).
- Embeddings: [OpenRouter, best embedding models 2026](https://openrouter.ai/blog/insights/best-embedding-models-2026/).
- Apple: [Foundation Models](https://developer.apple.com/foundation-models-framework/), [`fm` in macOS 27](https://rits.shanghai.nyu.edu/ai/apple-foundation-models-macos-27/) (third party).
