# Card layout: what's built

The handoff ("Layout con chat en tarjeta", README.md and `Layout Final.dc.html` here) replaces the line between the
sidebar and the content with a **card** that floats over the window. Built on 2026-11-19.

## Built

- **Tokens** (`Sources/PiopioTranscript/DesignTokens.swift`): `side` (#F4F4F2) is now the window under the cards,
  `win` (#FCFCFB) the card. New: `cardEdge` (1pt ring, black 6%), `composerEdge` (black 9%), `field` (#E9E9E6, fields
  on the window), `cardField` (#F1F1EF, fields in a card), `Radius.contentCard` = 10. `bubble` is #EDEDEC and
  `Radius.composer` 14.
- **`.contentCard()`** (`Design.swift`): fill, radius 10, the ring and a hairline shadow. Pages that lay out their
  own cards say so with `.ownsContentCard()`; the root view wraps every other page in one.
- **Window** (`RootView`): the sidebar sits on the window with no line (and no line above its footer); the content
  card is 8pt from the top, right and bottom (and left when the sidebar is collapsed). Default sidebar width 236
  (a width you dragged is kept). Banners sit on the window above the card.
- **Toolbar**: page toolbars are in the card, 44pt tall, so their middle lines up with the traffic lights (the
  sidebar's top row is 60). Title 13 semibold, subtitle 13 in fg3.
- **Chat** (F1, F2, F4): the chat in a card; the Summary flat on the window (252, with a "Summary" title); the Browser
  in a card of its own (default 440, still resizable), 8pt apart, with a 48pt toolbar, a 30pt address field on
  `cardField`, a close button, and the page inset 8pt with radius 7 and a hairline.
- **Build session** (F3): the session in a card; Files (280) and the Inspector (300) flat on the window; the Browser
  in a card. The Files filter is 32pt on `field`, with no line.
- **Agents**: the agents' column sits on the window (no fill, no line) and the agent's page is in a card.
- **Settings window**: the same: the section list on the window, the pane in a card.
- **Reading column and composer**: 720 wide (`DS.column`; 560 until 2026-11-20, too narrow next to Claude's ~768), answers 14pt, 32pt sides; the composer is white with a 1pt ring and a
  soft shadow (0 4 14, 5%). Your bubble is #EDEDEC, radius 14, 14×10 padding.

## Deliberate differences

- Traffic lights stay where macOS draws them (centred on the toolbars), not 14pt from the top as in the mockup.
- Icons are the app's SF Symbols, not the mockup's placeholders.
- The Summary shows what Piopio has (Now, Context, Setup, then context and cost in the shared footer), not the
  mockup's exact rows.
- The Automation page's runs column and other in-page columns stay inside the card; the handoff only covers
  conversations.

## Captures

`captures/`: f1-chat, f2-summary, f3-files, f4-browser, dark (faux model, `PIOPIO_DEMO_PROMPT`,
`PIOPIO_DEMO_CHAT_SUMMARY=1`, `PIOPIO_DEMO_BROWSER=1`, `PIOPIO_DEMO_PROJECT` + `PIOPIO_DEMO_PANEL=files`,
`PIOPIO_DEMO_APPEARANCE=dark`).
