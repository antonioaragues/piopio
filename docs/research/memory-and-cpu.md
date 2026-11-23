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

**Fixed the same day:** a coding agent's process now ends after 15 minutes idle (`AGENT_IDLE_MS` in
`runtimes/runtime.ts`), and the next message resumes its session: Claude Code by `resume`, Codex and Antigravity CLI by
`session/load`. An ACP agent that can't load a session keeps its process, since ending it would lose the conversation.

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

**Fixed the same day:** the folded subscription's `StepsView` now keeps its own list of the items from the snapshot
and the events, never changing an item it holds, so an unchanged item is the same object and only new ones are
compared; nothing copies the conversation. One update, a command's output growing in a conversation of N items:

| Items | 3 KB tool outputs | 18 KB tool outputs |
|---|---|---|
| 100 | 0.03 ms | |
| 250 | | 0.02 ms |
| 500 | 0.05 ms | 0.04 ms |
| 1,000 | 0.11 ms | |
| 4,000 | 0.40 ms | |

Under 1% of a core even at 4,000 items. What's left per update is sending the steps line that changed, whole: a turn
with many large tool outputs re-sends them all while one of its commands streams. `test/steps-view.test.ts` checks
that what a client builds from the folded events is the fold of the conversation, after every batch.

## 4. At rest

With the window not in front: 0.0% CPU for the app, the engine and the web content, and 6 idle wakeups in 5 seconds
for the app, 1 for the engine. The review's battery items (the mascot at 30 fps on Home, the browser panel's 1 Hz
timer, the project page reading its file every second) cost only while those views are on screen, and weren't
measured: that needs the app in front, on each of them, for a minute.

## 4b. The views on screen

Measured the same day: a copy of the Debug app (its own bundle id and data, the faux model) opened on each view with
`PIOPIO_DEMO_*`, 20 s to settle, then 60 s of `top` for the app, its engine and any new WebKit process. A snapshot of
each run confirmed the view.

**Caveat, found afterwards:** macOS doesn't redraw a window that's covered, and these runs didn't check that the test
window was the one in front. Later runs listed the on-screen windows and found it behind a full-size window every time
(macOS no longer lets a script bring an app forward), and the old build then measured 0 to 1.2% on Home. So only the
first number below, from the first run, is likely to be from a window on screen; the others are lower bounds until
measured again with the window in front.

| View | App | Engine | WebKit |
|---|---|---|---|
| **Home, with the mascot** (asleep, in the evening) | **9.6%** | 0.0% | — |
| A chat with one answer | 0.1% | 0.0% | — |
| The same chat with the browser panel open (no page loaded) | 0.3% | 0.0% | — |
| A project's memory editor (NOTES.md, read every second) | 0.0–0.2% | 0.0% | — |
| The file viewer on an HTML page (watched every second) | 0.0–0.1% | 0.0% | 0.0% |

Home is the one that clearly costs: the mascot's `TimelineView(.animation(minimumInterval: 1 / 30))` in `PiopioPerch` redraws
30 times a second for as long as Home is on screen, whether the app is in front or not and even while the mascot
sleeps. Ten percent of a core is what a laptop notices over a day with Home left open. The one-second timers the review
named (the browser panel's clock, the notes editor's and the file viewer's file checks) do little work per tick, but
their numbers above carry the caveat.

Not measured: the browser panel with a real site in it (the cost is the site's), and tabs parked in a hidden window.

## 5. What to fix, in order

| # | What | Why | Size |
|---|---|---|---|
| 1 | ~~Close a coding-agent runtime after it's been idle a while~~ Done: its process ends after 15 minutes idle, the conversation stays open, and the next message resumes the session (`test/idle-agents.test.ts`) | 40 to 300 MB per conversation, for days | Small |
| 2 | ~~Streaming without copying the conversation~~ Done: `StepsView` follows the events and compares only the items that are new objects (§3) | 10 to 20% of a core during long turns, growing with the square of the turn | Medium |
| 3 | ~~Measure the visible views~~ Measured (§4b, with a caveat): Home's mascot, 9.6% of a core while Home is on screen. Fix: draw it at 30 fps only while something moves quickly (a hop, a glance, flapping), 10 fps otherwise, and hold still while another app is in front; the other views to measure again with the window confirmed in front | A laptop's battery, with Home left open | Small |
| 4 | Measure the web views with tabs, visuals and an app open: the review says parked browser tabs keep running at full speed in a hidden window | Each one is a WebKit process | After 3 |
| 5 | An idle cap on the engine's own runtimes | Only for engines left running for weeks | Later |
