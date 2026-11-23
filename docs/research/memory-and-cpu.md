# Memory and CPU, measured

23 November 2026, on the operational review's fourth group ("memory and battery"), measured before changing anything.
The live numbers come from the Debug build that had been running for 16 hours on the author's Mac; the rest from
scripts against the engine on `bbc5605`
(scratchpad scripts: an in-process engine on the faux model, and the server's own streaming path).

**In short:** today Piopio is small (about 260 MB in all) and quiet at rest. Two of the review's claims hold and are
worth fixing: a coding-agent conversation keeps its `claude` or Codex process alive for as long as the engine runs,
40 to 300 MB each; and every streamed update costs time in proportion to the conversation, which a long Build turn
pays at 10 to 20% of a core. The engine's own memory per open conversation is too small to matter yet.

## 1. The running app

| Process | Footprint now | Peak |
|---|---|---|
| Piopio (the app) | 103 MB | 181 MB |
| Engine (node) | 137 MB | 297 MB |
| Its WebKit web content process (one) | 22 MB | — |
| **In all** | **about 260 MB** | |

`footprint` (phys_footprint, which counts compressed memory; `ps` showed the engine at 12 MB). One web content process
means no browser tab, visual or app was alive at the time; each one opened adds a process of its own.

For scale, the `claude` processes the Claude app had running on the same Mac took **42, 120 and 294 MB** each.
Piopio starts the same program for each conversation on Claude Code, and `codex` (38 MB idle here) for Codex.

## 2. The engine, per open conversation

Nothing closes a conversation's runtime once it's open (`Sessions.open`): they stay until the engine stops.

| Open (5 short turns each) | Heap after GC |
|---|---|
| none | 54 MB |
| 35 Build conversations | 69 MB |
| 20 chats | 64 MB |

About **0.4 to 0.5 MB each**, plus what their history holds. Not worth evicting yet; a cap would matter only for an
engine left running for weeks with hundreds opened.

The exception is a conversation on a coding agent: its runtime keeps the agent's process, so each one opened costs the
40 to 300 MB above, for as long as the engine runs (in background mode, until the Mac restarts).

## 3. Streaming in a long conversation

The app subscribes with `fold: true`, so for every batch of updates the server copies the whole conversation
(`TimelineBuilder.snapshot()`, a `structuredClone`) and `StepsView.events` groups it again and serializes every item
twice to find what changed. One update, as the conversation grows:

| Items | 3 KB tool outputs | 18 KB tool outputs |
|---|---|---|
| 100 | 0.7 ms | |
| 250 | | 5.1 ms |
| 500 | 2.2 ms | 9.4 ms |
| 1,000 | 4.8 ms | |
| 4,000 | 19 ms | |

At 20 updates a second that is **10% of a core for a 250-item conversation with large outputs, 19% at 500**, in the
engine alone, for as long as the turn streams, and the whole turn grows with the square of its length. The largest
conversation on this Mac has 326 entries, and one has entries of 18 KB on average (4.3 MB for 234), so this is real use.
The app redraws on top of that (`TranscriptDocument` walks all its items per batch, per the review), which isn't
timed here.

## 4. At rest

With the window not in front: 0.0% CPU for the app, the engine and the web content, and 6 idle wakeups in 5 seconds
for the app, 1 for the engine. The review's battery items (the mascot at 30 fps on Home, the browser panel's 1 Hz
timer, the project page reading its file every second) cost only while those views are on screen, and weren't
measured: that needs the app in front, on each of them, for a minute.

## 5. What to fix, in order

| # | What | Why | Size |
|---|---|---|---|
| 1 | Close a coding-agent runtime after it's been idle a while (say 15 minutes): its process goes, and the next message resumes Claude Code's or Codex's session by id, as a restart already does | 40 to 300 MB per conversation, for days | Small |
| 2 | Streaming without copying the conversation: `StepsView` regroups only the steps group an update touches, from the builder's items read in place, and remembers each item's serialized form instead of making it twice | 10 to 20% of a core during long turns, growing with the square of the turn | Medium |
| 3 | Measure the visible views (Home's mascot, the browser panel, a project page, a file view) with the app in front | Before touching any of the review's battery items | A minute each |
| 4 | Measure the web views with tabs, visuals and an app open: the review says parked browser tabs keep running at full speed in a hidden window | Each one is a WebKit process | After 3 |
| 5 | An idle cap on the engine's own runtimes | Only for engines left running for weeks | Later |
