# 04 — Chat mode

> The app calls Spaces **Notebooks** (README AQ13); this spec, the protocol and the code keep "Space".

Chat has three kinds of container, shown in one sidebar:

```
CHAT
├─ ⭑ Pinned
├─ Spaces
│   ├─ 🏠 Home renovation        (Main + 6 topics)
│   └─ 📚 Learning Rust          (Main + 3 topics)
├─ Projects (chat lens)
│   └─ ~/Notes/research          (4 sessions)
└─ Threads
    ├─ Today: "Explain CRDTs…"
    └─ Yesterday: …
```

---

## 1. Threads

### 1.1 Definition
A free-standing conversation. Backed by **one pi-durable session** (`threads/<id>.sqlite`) whose root conversation is the thread. Forks become extra conversations in the same session.

### 1.2 Requirements
- **T1** New thread: ⌘N in Chat, or Quick Chat (§4). It opens instantly with the per-mode default model.
- **T2** Streaming responses with markdown, code blocks (copy, language label), tables, LaTeX (inline/block), images.
- **T3** Thinking/reasoning shown collapsed by default, with a per-session level picker (off/low/medium/high; mapped to pi `thinkingLevel`).
- **T4** While the assistant is running: **Enter** queues a follow-up, **⌥Enter** steers, **Esc** aborts. The queue is shown above the composer and can be edited or cleared.
- **T5** **Edit & resend** a user message → forks from the previous entry (pi-durable `fork`). **Regenerate** an assistant message → forks and resubmits. A branch switcher (`‹ 2/3 ›`) appears on forked messages.
  *Implementation (1.2):* a thread is one pi-durable session; each version is a conversation forked just before the edited user message (`parent.at`), and the engine computes the switcher from pi-durable's conversation records (`packages/engine/src/runtimes/branches.ts`). The catalog remembers the active branch and when each branch was last used.
- **T6** Switch model mid-thread (`sessions.configure`). The model used is shown per assistant message.
- **T7** Auto-title after the first exchange, using the cheap "utility" model (07-shared §1.3). Can be renamed.
- **T8** Attachments: drag & drop, paste, or 📎. Images go to vision models. PDFs are passed as files when the model supports it, otherwise text is extracted in the engine. Text/code files are inlined. Max size is configurable.
- **T9** Tools available by default (toggle per thread from the composer's ⚙︎ menu):
  - `web_search`: OpenRouter web plugin by default. Optional Brave/Tavily/Exa key for a dedicated provider.
  - `web_fetch`: engine fetch + readability → markdown, size-capped.
  - MCP tools from servers enabled for Chat (07-shared §4).
  - `memory`: read/write global memory (if enabled, 07-shared §5).
- **T10** Cost/usage per message (hover) and per thread (header).
- **T11** Export: Markdown, HTML, JSONL. Copy the conversation as Markdown.
- **T12** Archive/delete. Deleting removes the SQLite file and the catalog entry.
- **T13** "Move to Space": attach the thread as a new topic of a Space (copies history, then archives the original).

### 1.3 Later
- "Move to cloud" (the thread runs on the Cloud Engine, reachable from iOS).
- Artifacts/canvas side panel (HTML/markdown documents the model writes and edits).
- Sandboxed code execution tool (codemode/QuickJS locally).
- Voice input (on-device dictation) and TTS.

---

## 2. Projects in the Chat lens

Same **Project** entity as Build (decision C2). The lens only changes defaults and UI:

| | Build lens | Chat lens |
|---|---|---|
| Runtime | pi-coding-agent | pi-coding-agent |
| Tool profile | `build`: read, write, edit, bash + extensions | `chat`: read, write, edit, grep/find/ls, web_search, web_fetch. **No bash** by default. |
| System prompt | pi default + project AGENTS.md | pi default + a "knowledge assistant" section + AGENTS.md |
| UI | file tree, diffs, terminal, git | file browser, document preview (md/pdf/images), "changed files" list |
| Approval default | Auto-edit | Auto-edit |

- **P1** A Project has a `lens` (default by detection: a `.git` folder or code files → build, otherwise chat) and appears in that mode's sidebar. "Open in Build/Chat" moves it. A project can be pinned in both.
- **P2** Sessions created in either lens appear in both. Each is tagged with the profile it was created with.
- **P3** Chat lens shows a preview pane for the selected file and lets you @-mention files and folders in the composer.

---

## 3. Spaces

### 3.1 Concept
A Space is a long-lived area of your life or work. **You always write in Main** (the front door). The **Organizer** (the agent in Main) decides, for each message, whether to:

1. **Answer** directly: meta questions, quick things, cross-topic questions.
2. **Route** to an existing **Topic**: the message goes to that topic's conversation and the topic agent answers there.
3. **Create** a new Topic: seeded with a brief, then routed.

You can still open any topic and talk to it directly (that bypasses the organizer).

### 3.2 Data model (one pi-durable session per Space)
| pi-durable element | Use |
|---|---|
| Root conversation | **Main** (organizer) |
| Conversations (ownerless) | **Topics**, one per subject |
| Custom doc `piopio.space` (session scope) | `{name, icon, instructions, topics: [{id, title, brief, status, lastActiveAt, summary}]}` |
| Custom doc `piopio.space-memory` (session scope, `history:"rewindable"`) | Shared knowledge: decisions, facts, preferences. Markdown with sections. |
| Custom entries `piopio.routing` (in Main) | Routing decisions, rendered as routing cards |
| Space files (`spaces/<id>/files/`) | Knowledge files, exposed through `space_files_*` tools |

### 3.3 Organizer
- **Model:** the Space's "organizer model" (default: a fast, cheap model with tool use). Topics use the Space's "topic model" (default: the Chat default).
- **Context each turn:** Space instructions + topic index (titles, briefs, 1–2 line summaries, recency) + Space memory (truncated with a pointer) + recent Main history.
- **Tools** (extension `piopio-space-organizer`):
  | Tool | Behavior |
  |---|---|
  | `route_to_topic(topicId, message?, note?)` | Submits the user's message (or a rewritten version) to the topic conversation (`whenBusy:"followUp"`). Writes a `piopio.routing` entry. |
  | `create_topic(title, brief, seed?)` | Creates a conversation with an initial system section (brief). Optionally seeds it with context from Main. Then routes. |
  | `ask_topic(topicId, question)` | Runs a **read-only side query** against the topic's history (child task conversation, `ownership: task`) and returns the answer to the organizer without polluting the topic. |
  | `update_memory(patch)` | Edits `piopio.space-memory`. Every change is shown as a `system` item ("Memory updated: …"), with undo. |
  | `rename_topic`, `archive_topic`, `merge_topics(a, b)` | Housekeeping. Merging summarizes B into A and archives B. These suggest; they need confirmation unless "auto-tidy" is on. |
  | `search_space(query)` | Substring/FTS across all topic histories. Later: semantic, through the memory provider (07-shared §5.1) indexing topic replies into a bank per Space. |
- **Policy (system section):** prefer routing when a message clearly continues a topic. Create a topic only when a new subject is likely to recur or needs depth. Answer in Main for one-offs. Always explain the decision in one short line.

### 3.4 What the user sees in Main
```
You:        Can we fit a dishwasher if we move the sink 40cm left?
↳ Routed to 🔧 Kitchen layout · replied   (“continues the sink placement discussion”)
   "Yes, if the base cabinet run is at least 60cm…"          [Open →]  [Wrong topic ▾]
```
- **S1** Main shows a **link card only**, never the full reply. The card has the topic, the routing reason, a live status (`thinking…` → `replying…` → `replied` / `needs you`), and a one-line preview of the reply. **[Open →]** (or ⌘↩ on the card) jumps to the topic, scrolled to that reply. Main stays a short switchboard. The reply itself lives only in the topic.
- **S1a** The topic gets an unread dot in the sidebar until its reply is viewed. If the topic asks you a question, the card shows `needs you` and a notification fires (when not focused).
- **S2** **[Wrong topic ▾]** → pick another topic or "New topic" → `spaces.reroute`. The organizer gets a correction note and records a routing hint in the `piopio.space` doc, so it learns.
- **S3** Explicit control: `@Kitchen layout …` forces a route. `/new <title>` forces a new topic. `/main …` forces answering in Main.
- **S4** Messages typed directly in a topic show a subtle "direct" badge. The organizer is told about them (via the topic summary refresh) but doesn't intervene.

### 3.5 Topic agents
- Context: Space instructions + topic brief + Space memory + topic history + Space files (tool access).
- Tools: Chat defaults (T9) + `space_files_read/search` + `ask_topic` (ask *another* topic) + `propose_memory(patch)` (the organizer or user approves).
- After each settled turn, a background task refreshes the topic's 1–2 line `summary` in `piopio.space`, using the utility model.

### 3.6 Space settings
Name, icon, instructions, organizer model, topic model, enabled tools/MCP, memory on/off, auto-tidy on/off, files.

### 3.7 Requirements summary
- **S5** Create a Space from scratch, or "Convert threads to Space" (select threads → each becomes a topic).
- **S6** The sidebar shows the Space with its topics nested, sorted by recency, each with an unread dot.
- **S7** The Space header shows: topics count, memory (opens the editor), files, cost to date.
- **S8** The memory editor is a markdown editor with history (rewindable doc), and it shows who changed what (organizer/topic/user).
- **S9** Topic actions: rename, archive, merge, export, "Promote to Thread" (copy out).
- **S10** Routing latency budget: the organizer decision (link card) should be visible within ~1.5 s with the default organizer model.
- **S11** **Thread → Space suggestion:** after a Thread's first exchange (and again if its subject drifts), the utility model compares it against the topic index of every Space. If the match confidence is above the threshold, a dismissible banner appears: "This looks like it belongs in 🏠 Home renovation → *Kitchen layout*" with **[Move to topic] [Move as new topic] [Dismiss]**. Dismissals are remembered per thread. Can be turned off in Settings › Chat. Ships with Spaces (Phase 3), because it needs Spaces to exist.

### 3.8 Later
- Space runs in the cloud (reachable from the future iOS app).
- Semantic search and auto-linking across topics.

**Spaces and Agents stay separate products** (decision AQ4): Spaces are for thinking, Agents are for acting. They share runtime code in `@piopio/runtime`, but Spaces get no channels, schedules or proactivity. Anything that needs those is an Agent.

---

## 4. Quick Chat
- **Q1** Global hotkey (default ⌥Space, configurable) opens a floating panel (NSPanel) over any app.
- **Q2** Typing + Enter creates a new Thread (or sends to the last Quick Chat thread if it's less than 10 min old). ⌘Enter opens the full window.
- **Q3** The target can be switched from a picker: New thread / a Space's Main / an Agent's in-app channel.
- **Q4** Clipboard and selected text can be attached (`⌘⇧V` attaches clipboard). A screenshot attachment needs Screen Recording permission, so it's off by default.

## 5. Resolved questions (Chat)
- **CQ1** Routed replies in Main → **link card only** (S1).
- **CQ2** Thread → Space suggestion → **yes, in v1 of Spaces** (S11).
- **CQ3** Web search → **OpenRouter web plugin by default**, with an optional Brave/Tavily/Exa key (T9).
