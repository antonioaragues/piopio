# Spike S2: native streaming transcript

**Question:** can a native transcript render streaming markdown + code smoothly with 2,000 items? If not, fall back to a WKWebView transcript?

**Answer:** yes, natively, but **not with SwiftUI stacks**. A single **TextKit 2** `NSTextView` met the frame budget in every scenario. SwiftUI `LazyVStack` streams perfectly but hitches while scrolling, and SwiftUI `List` is erratic. No WebView fallback is needed.

## Method

`apps/mac/Sources/TranscriptLab` (run with `swift run -c release TranscriptLab --renderer swiftui|swiftui-list|textkit`):

- **Corpus:** 2,000 deterministic timeline items (user → 0–2 tool calls → assistant), **2.24 M characters**. Assistant answers mix paragraphs with inline markup, nested lists, code blocks (4–40 lines, highlighted), tables and quotes.
- **Markdown:** `PiopioKit.MarkdownStream` splits streaming text into blocks. Closed blocks never change, so only the open tail block is re-rendered per delta. Inline markup goes through Foundation's `AttributedString(markdown:)`.
- **Scenarios** (window 860×1000 pt, 60 Hz display, release build):
  1. Load the 2,000 items and show the bottom.
  2. Scroll up at 3,000 pt/s for 6 s (trackpad-like), driven from the display link through the `NSClipView`.
  3. Fling at 14,000 pt/s for 4 s.
  4. Stream a ~7,000-char answer at 600 chars/s (~150 tok/s) in 30 Hz batches, following the bottom.
- **Metric:** display-link intervals → hitch time ratio (ms of hitch per second; Apple's guidance is < 5 good, 5–10 warning, > 10 bad), p95/p99, dropped frames. Memory is `phys_footprint` after load.

## Results (two runs each)

| | SwiftUI `LazyVStack` | SwiftUI `List` | **TextKit 2 `NSTextView`** |
|---|---|---|---|
| Load → first frame | 406–421 ms | 655–690 ms | 570–600 ms |
| Memory after load | 65 MB | 203 MB | 125–127 MB |
| Scroll hitch (ms/s) | 22–34 ❌ | 13–392 ❌ (one 3.7 s stall) | **0** ✅ |
| Fling hitch (ms/s) | 23–25 ❌ | 18–237 ❌ | **0** ✅ |
| Stream hitch (ms/s) | 0 ✅ | 5–7 ⚠️ | **0–0.4** ✅ |
| Main-thread cost per delta batch (avg / max) | 0.4 / 1.5 ms | 0.25 / 0.6 ms | 1.0 / 2.4 ms |

Notes:
- The SwiftUI numbers are *after* moving inline parsing and highlighting out of `body` (pre-rendered `AttributedString`s). Before that, `LazyVStack` was similar (22–32 ms/s).
- The very first TextKit run (cold caches) showed 22–27 ms/s with one 417 ms spike. Two later runs were clean. Worth watching. The candidate fix is building the attributed string off the main thread (below).
- `List` logs "reentrant operation in its NSTableView delegate" warnings from AppKit.

Snapshots: [SwiftUI](swiftui-3-streamed.png) · [TextKit 2](textkit-3-streamed.png). Raw results are in `results-*.json`.

## Decision

**The transcript is a TextKit 2 document** (one `NSTextView` per open session, wrapped for SwiftUI with `NSViewRepresentable`). Everything around it (sidebar, composer, inspector, settings, sheets) stays SwiftUI.

- Blocks render to `NSAttributedString` through a renderer shared by every timeline item kind, built **off the main thread** at load. The newest items are shown first and older history fills in.
- Card chrome is drawn by **custom `NSTextLayoutFragment`s**: rounded backgrounds for code blocks, quotes and tables, user bubbles.
- Interactive pieces (tool cards that expand, routing cards, approval buttons, copy buttons) are **`NSTextAttachmentViewProvider`** views, which can host small SwiftUI views.
- Bonus we get for free: selection and copy across messages (spec TR5), find (⌘F), and VoiceOver reading of the text.
- **iOS:** TextKit 2 exists in UIKit (`UITextView` + `NSTextLayoutManager`), so the attributed-string builder and the layout fragments are shared and only the view wrapper differs.

---

# Spike S2b: card chrome, attachment views, progressive load

Renderer: `TextKitChrome.swift` (`--renderer textkit-cards` with AppKit tool cards, `textkit-cards-swiftui` with SwiftUI tool cards in `NSHostingView`s).

## What was built
- **Card chrome:** code blocks, quotes, tables and user bubbles are each **one paragraph**, with lines joined by U+2028 and the paragraph tagged with `.piopioCard`. A `NSTextLayoutManagerDelegate` returns a `CardLayoutFragment` for these, which draws the rounded background (or the quote bar) and then the text. Note that a fragment's frame starts at the paragraph indent and only spans the used width, so the card rect is computed from the text container.
- **Tool cards:** an `NSTextAttachment` with `viewProvider(...)`. Its bounds come from the card model (28 pt collapsed, measured output height expanded). Toggling invalidates layout for that one character's range. Set a blank `image`, otherwise TextKit *also* draws its generic document placeholder.
- **Off-main-thread building:** `TranscriptBuilder` is `nonisolated` and only uses thread-safe font APIs (`NSFontDescriptor` traits, not `NSFontManager`). Built strings cross isolation through an `@unchecked Sendable` box.
- **Progressive load:** see below.

## Finding: never prepend into a big document

Inserting text costs time **proportional to everything after the insertion point** (NSTextContentStorage re-indexes the paragraphs that follow). Appending at the end (streaming) stays at ~1 ms. Measured strategies for showing 2,000 items:

| Strategy | Tail visible | Everything loaded | Main thread while loading |
|---|---|---|---|
| Prepend history in 250-item chunks | 144 ms | 1.4 s | up to 198 ms per chunk, 578 ms/s hitches |
| Prepend in 50-item chunks | 109 ms | 1.6 s | 7 → 60 ms per chunk (grows with the document), 392–436 ms/s |
| Prepend in 10-item chunks | 104 ms | 3.6 s | up to 27 ms + follow-on layout, 442 ms/s |
| Build everything off-main, swap once | 121 ms | 0.9 s | one 231 ms freeze |
| **Windowed document: newest 300 items, older pages on demand** | **135–157 ms** | on demand | **8.7 ms avg / 13 ms max per 10-item page** |

**Windowed document.** The text view holds the newest *N* items (300 by default). When the viewport gets within 4,000 pt of the top, the next older page is inserted. Each page is prefetched (built off the main thread) as soon as the previous one lands. After inserting, the page is laid out (`ensureLayout`), and the clip view is shifted by the height delta. The **visible text did not move: 0 characters of anchor drift** across all page loads. Page size matters, because `ensureLayout` dominates: 50 items cost ~36 ms, 20 items ~22 ms, and **10 items ~9 ms**.

## Results (two runs per card variant, default window 300 / page 10)

| | TextKit cards, AppKit tool cards | TextKit cards, SwiftUI tool cards |
|---|---|---|
| Tail on screen | 135–137 ms | 138–157 ms |
| Memory | 98–100 MB | 99–100 MB |
| Scroll hitch (ms/s) | 0 – 5.6 | 0 – 8.3 |
| Fling | 0 | 0 |
| Expand/collapse 8 tool cards | 0 (relayout 1.7–2.6 ms avg, ≤ 4.1 ms) | 0 (2.5–2.6 ms avg, ≤ 3.9 ms) |
| Stream ~7k chars at 600 chars/s | 0 | 0 |
| Stream **122k chars** into one message at 3,000 chars/s | 0.2–0.4 (append ≤ 2.5 ms) | 0–0.2 (≤ 2.4 ms) |

The scroll "hitch" in some runs is a single ~50 ms frame, likely the first realization of a region with several attachment views. It's worth profiling in Phase 1, but it's inside the warning band, not the bad one.

A paging stress test (100-item window, fling at 14,000 pt/s through on-demand pages) scored 9.5–12.7 ms/s with 20–50-item pages and **10.4 ms/s with 10-item pages**. At that speed the fling outruns the prefetch and reaches the loaded top. The 300-item default makes this rare, and a "loading older…" row covers it.

Snapshots: [card chrome](textkit-cards-scrolled.png) · [expanded tool card](textkit-cards-expanded.png).

## Decisions
1. **Transcript = windowed TextKit 2 document.** It holds the newest 300 items, prefetches older history in 10-item pages off the main thread, and keeps the scroll anchor stable. Jumping to an old message (search result, fork point) **replaces** the window around that item instead of loading everything above it.
2. **Card chrome = layout fragments.** Code, quote, table and bubble cards are single U+2028 paragraphs.
3. **Interactive cards may be SwiftUI**, hosted in attachment views (same cost as AppKit in this test). That lets tool cards, routing cards and approval cards share SwiftUI code with the rest of the app, and later iOS.
4. **Streaming appends only at the end** of the document. Never edit or insert above the tail while streaming, except for an on-demand page load.

## Still not covered
- A 120 Hz ProMotion display (this Mac's display runs at 60 Hz).
- Real model output (the corpus is synthetic).
- Code blocks wrap instead of scrolling horizontally. If horizontal scroll is wanted, wide code blocks need an attachment view.
- Tables are monospaced cards. Rich tables (wrapping cells) would be an attachment view with a SwiftUI `Grid`.
- Window eviction (dropping the bottom when scrolled far up), and "jump to item" re-windowing.
