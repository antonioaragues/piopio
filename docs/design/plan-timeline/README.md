# Handoff: the Inspector's Plan (timeline, option 1a)

Received 2026-11-18. The canvas is `Plan Redesign.dc.html` (open it in a browser, `support.js` alongside). Only
**1a** applies; 1b (numbered list) and 1c were set aside. It replaces the plan block of
[inspector 4a](../inspector/README.md) (a segmented bar over a checklist).

## What the handoff asks for

- **The plan as a vertical timeline** under Setup / Read / Changes. Done steps carry a check, the current step is
  open with its detail, the pending ones show only their title.
- **Header:** "Plan" on the left, "{done} of {total}" on the right in tabular figures. The segmented bar is gone:
  the timeline already shows progress.
- **Step row:** a 20pt rail column and the text, 10pt apart; the whole row is clickable.
  - Marker, a 16pt circle aligned with the first line: done is filled with a check, current is a 2pt ring with a
    halo, pending a 1.5pt light ring.
  - A connector under every step but the last (2pt wide, at least 12pt, 3pt clear of the markers), dark under a
    done step and light otherwise. 16pt under each step's text is the space between steps; the line runs through it.
  - Done titles are muted, pending ones secondary, the current one semibold with a "Now" tag on the right and its
    detail below (6pt gap).
- **Content:** every step becomes a **short title plus a detail** (it used to be one long sentence). If the data
  model only has one string, add the title (or derive it) and keep the full string as the detail.
- **Behavior:** in the prototype a click makes a step current; that's demo only. In the app the agent owns the state
  and a click at most opens or closes that step's detail (a tooltip is also fine). 200 ms ease-out on marker and line
  color when a step completes; 180 ms fade for the detail. A finished plan shows every step done, no "Now", "6 of 6".
  Long titles wrap. Never more than one current step.
- **Fidelity:** high, but "if the codebase has equivalent tokens, use them".

## In Piopio's grey ink

The handoff's palette is system blue (`#0B6CFF` fills, a tinted pill and halo). [Grey ink](../grey/README.md) keeps
blue for links, the caret and the needs-you dot, and has no pills, badges or decoration, so the layout and behavior
are the handoff's and the colors and sizes are the Inspector's:

| Handoff | As built |
|---|---|
| Header 15/600, counter 13 | 13 semibold and 12 `fg3`, like Setup, Read and Changes |
| Done marker: blue disc, white ✓ | `fg3` disc with a `checkmark` symbol in `win` |
| Current marker: blue 2pt ring + 4pt blue halo | `fg` (ink) 2pt ring, no halo |
| Pending marker: `#C7C7CC` 1.5pt ring | `fg3` at 60%, 1.5pt |
| Markers 16pt, line 2pt | 14pt and 1.5pt (the Inspector's text is 13, not 14) |
| Line under done: blue; else `#E3E3E0` | `fg3`; else `fg3` at 28% |
| Titles 14/20: done `#8A8A8E`, pending `#3A3A3C`, current 600 | 13: done `fg3`, pending `fg2`, current semibold `fg` |
| "Ahora" pill (blue on a blue tint) | "now", 12 `fg3`, plain text |
| Detail 13/18 `#6E6E73` | 12.5 `fg2`, 2pt line spacing |
| 16pt between steps | 14pt |
| Finished: every step done, "6 of 6" | The same; the time it took joins the counter ("6 of 6 · 34 min") once past a minute |

What else changed against the old block:

- The green "All N steps done" box and its Show steps / Hide steps link are gone: a finished plan is the same
  timeline with every marker done. Done titles are no longer struck through.
- **Clicking a step with a detail opens or closes it** (the current one starts open). Steps without a detail don't
  react. A closed step's detail is also its tooltip.
- **The data:** the agent's `todo` tool keeps `text` as the title ("in a few words", as before) and gains an
  optional `detail`, one sentence on what the step covers. Lists without details (older sessions, or a model that
  skips it) show titles only. The scripted model takes `todo: Title :: detail (in_progress) | …`.

## Checked

Captures in `app/` (Debug app, scratch data, scripted model): a plan in progress in light mode, with the current
step's detail open, and a finished plan in dark mode. Not seen yet: clicking a step to open or close its detail,
the tooltip, the transition when a step completes, and a real model filling in details.
