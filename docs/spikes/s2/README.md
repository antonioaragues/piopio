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

## Not covered (→ spike S2b, before Phase 1's transcript work)

1. Block chrome via layout fragments plus one attachment-view tool card. Re-measure: the budget is < 5 ms/s hitch in all scenarios.
2. Building the attributed string off the main thread, and progressive load (the newest 200 items first).
3. A 120 Hz ProMotion display (this Mac's display runs at 60 Hz).
4. Real model output instead of the synthetic corpus, and a long single answer (> 50 k chars) streamed into one message.
5. Tables: TextKit 2 has no `NSTextTable`, so a table is either an attachment view (a SwiftUI `Grid`) or a monospaced fragment.
