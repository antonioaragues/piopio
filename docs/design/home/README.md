# Handoff: Home redesign + animated piopio

## Overview
This is a redesign of the macOS app's **Home** page (`HomeView.swift`, `NeedsYou.swift`; data from `agenda.ts`). The chosen direction is turn 3 in the design file:
- **3a (normal):** the top of option 1a, which is the greeting plus the AskBox with piopio perched on it. Below it sits the tabbed panel from option 1c: *Waiting on you / While you were away / Today*.
- **3b (empty):** shown when nothing is waiting, nothing happened while away, and nothing is scheduled. The prompt is vertically centred, piopio naps on the box, and there is one status line.
- **piopio moods (turn 4):** the mascot changes with time of day and special dates.

Turns 1 and 2 hold explorations that were not picked. Use them for context only.

## About the design files
The files in this bundle are **design references built in HTML**. They are prototypes that show the intended look and behaviour, not production code. Recreate them in the existing SwiftUI codebase using its established patterns. Keep the current data sources, AskBox popover, permissions, and notification deep-links exactly as they work today. This redesign changes presentation only.

To view the prototype, open `Home Redesign.dc.html` in a browser; it needs `support.js` next to it. Use the Tweaks props `emptyState` and `piopioMoment` to switch states.

## Fidelity
**High-fidelity.** Colours, type, spacing and motion are final. Use the system font (SF Pro). Values below are in pt, matching CSS px 1:1.

## Screen: Home (normal, 3a)
**Layout:** one centred column, max-width 660, padding 72 top / 32 sides / 48 bottom. Vertical gap between blocks is 36.

1. **Greeting block** (gap 4)
   - Date: 13 regular, `#8C8A85`, e.g. "Wednesday, 18 November".
   - Greeting: 32 semibold, tracking −0.025em, `#1F1E1C`. "Good morning/afternoon/evening, {first name}".
2. **AskBox** (22 below the greeting)
   - Card: white, 1pt border `#E6E4DF`, radius 16, padding 16/16/12.
   - Shadow: `0 1 2 rgba(0,0,0,.04)` + `0 8 24 −12 rgba(0,0,0,.12)`.
   - Placeholder: 15, `#A8A6A0`, "Ask anything, or @ a project or an agent…".
   - Toolbar row (gap 8, 13pt):
     - "+" button, 28×28.
     - Target chip: pill, bg `#F4F3F0`, padding 5/10, text `#3A3936`.
     - Spacer.
     - Model name in `#8C8A85`.
     - Send button: 30pt circle, bg `#1F1E1C`, white arrow.
   - **piopio** is absolutely positioned on the card's top edge: right 28, top −40, rendered at ~47pt (52 × 0.9). It sits *on* the box.
   - Hint line below the card: 12, `#9A9893`, padding-top 10. E.g. "Not in a project · it can't see or change your files".
3. **Tabbed panel** (gap 12)
   - Segmented control, left-aligned:
     - Track: bg `#F1EFEB`, radius 11, padding 4, gap 4.
     - Tab: padding 6/14, radius 8, 13pt.
     - Selected tab: white bg, shadow `0 1 2 rgba(0,0,0,.08)`.
     - The "Waiting on you" tab carries a count badge: 11 semibold, white on `#EE8A3C`, pill, padding 1/6.
   - Panel: white, 1pt border `#ECEAE5`, radius 16, padding 6.
   - **Waiting on you row** (padding 11/12, radius 10, hover bg `#FBFAF8`):
     - Icon tile: 28×28, radius 8, tinted bg with an 8pt dot.
       - Approval: tint `oklch(.95 .04 55)`, dot `oklch(.70 .16 55)` (orange).
       - Failed: tint `oklch(.95 .03 25)`, dot `oklch(.62 .17 25)`.
       - Everything else: tint `oklch(.95 .03 255)`, dot accent `oklch(.56 .15 255)`.
     - Title: 13.5, single line, ellipsis.
     - Meta: 12, `#9A9893`, "origin · age".
     - Actions are pill buttons, 12.5pt, padding 5/11:
       - Secondary: 1pt border `#E6E4DF`.
       - Primary: bg `#1F1E1C`, white text.
       - Agent messages show an inline pill field "Answer here…" (width 170) instead of buttons.
       - Action labels per kind are unchanged from today (Not now/Allow, Dismiss/Run again, Keep paused/Raise to $X, Dismiss/Open…).
     - Clicking a row expands its full card:
       - Indent 52.
       - Body box: bg `#F6F5F2`, radius 10, padding 10/12, 13pt, line-height 1.5. Commands and logs use SF Mono.
       - Then an "Open … →" link in the accent colour, 12pt.
     - Ready-to-merge rows come last, after a 1pt `#F1EFEB` divider: green tile `oklch(.95 .04 150)` / dot `oklch(.66 .13 150)`, "{project} · N tasks ready for main", Review button.
     - Keep "Show N more" after 5 rows, plus the deep-link-and-expand behaviour.
   - **While you were away row** (padding 11/12, 13.5pt):
     - 28pt circle avatar: bg `#F4F3F0`, initial in 12 semibold `#6E6C67`.
     - "**Name** summary" text. "had nothing new" rows use `#A8A6A0`.
     - 6pt status dot: green `oklch(.66 .13 150)`, grey `#C9C7C1`, or warning `oklch(.70 .16 55)`.
     - Time: 12, `#A8A6A0`, tabular figures, right-aligned, width 38.
   - **Today row** (padding 10/12, radius 10):
     - Time column: width 48, 12.5, tabular figures.
     - Label: 13.5.
     - Origin on the right: 12, `#A8A6A0`.
     - Past items: time `#B4B2AC`, label `#A8A6A0`, with ✓ or ⚠.
     - "now" item: bg `oklch(.97 .02 255)`, time in accent colour, label semibold.
     - Event-triggered items show "any" as the time.
     - Keep the "Tomorrow" divider.
     - Footer: "N messages held until quiet hours end", 12, `#9A9893`.
   - Default tab is the first one that has content: Waiting, then Away, then Today. Hide tabs that are empty.

## Screen: Home (empty, 3b)
- The content block (max-width 620, gap 22) is centred vertically, nudged up 60.
- Greeting and AskBox are the same as 3a. Sleeping piopio (56pt) sits on the box at right 26, top −44.
- After the hint line comes a status row (padding-top 18): a 6pt green dot plus "All quiet. When something needs you, it'll show up here." in 13, `#A8A6A0`.

## Sidebar
Unchanged from the current app. It is mocked in the prototype for context only.

## piopio, the mascot (see `assets/piopio.svg`, `assets/piopio-sleep.svg`)
Built in a 120×120 viewBox. It is derived from the app icon: round yellow body, three-feather tuft, glossy black eyes, coral cheeks, orange diamond beak, small wings, orange feet.

Palette:
- Body: radial gradient `#FFEA5C` → `#FBCB22` → `#EFA80E`, centre at 40%/32%.
- Wings: `#F2B415`.
- Eyes: `#2B1D14`, with a white highlight.
- Cheeks: `#FF8466`, 75% opacity.
- Beak: gradient `#FFA857` → `#EE6F2B`, top facet `#FFB86B`.
- Feet: `#EE7A30`.

Implement it as a vector drawing (SwiftUI `Canvas`/`Shape`, or a Rive/Lottie file). The face must move independently.

### Behaviour (all states)
- **Idle bob:** translateY 0 → −2.5 → 0 over 3.4s, ease-in-out, looping. Night uses 4.6s.
- **Blink:** eyes scaleY to 0.08 at 96% of a 4.6s loop (3.2s at night). Stagger each instance by about 0.7s.
- **Tuft sway:** rotate −4° ↔ 5° over 3.2s.
- **Eyes follow the cursor:**
  - Take the vector from the chick's centre to the mouse.
  - Magnitude is `min(1, distance/260) × 3.4` viewBox units; the y component is scaled by 0.8.
  - Move the face group by 0.5× that vector, the eyes by a further 0.5×, and the beak by 0.3×.
  - Transition 0.18s ease-out. Throttle updates to about 50ms.
- **Tap:**
  - Hop: 0.6s ease-out, origin at the bottom centre. Squash 1.1/0.86, then rise −16 with stretch 0.94/1.07, then land 1.08/0.92, then rest.
  - A speech bubble pops in (scale 0.6 → 1 over 0.22s) for about 1.4s.
    - Bubble style: `#1F1E1C`, white 12 semibold, pill, padding 4/10.
  - Wings flap ±28° every 0.22s while the bubble is showing.
- **While typing in the AskBox:** look down at the box (offset 0, 3.6) and flap.
- **On send:** hop and say "¡voy!".

### Moods (`moodNow()`)
Special dates take priority over time of day.

| Mood | When | Look | Tap |
|---|---|---|---|
| morning | 05–12 | Sleeping pose: squat body (rx46 ry34), closed arc eyes, breathing scale 1.025/0.965 over 3.6s, two "z" floating up and fading over 2.8s, staggered 1.4s | Wakes up and stays awake for the session: hop + "¡buenos días!" |
| afternoon | 12–20 | Default awake | Random: "¡pío!", "pío pío", "¿qué hacemos?", "¡hola, Antonio!" |
| night | 20–05 | Floppy nightcap `#7E95DA` with brim and pompom `#EEF1FB` (hides the tuft). Half-closed eyes (lower semicircle plus lid line). Slower bob | "zzz… ¿aún aquí?", "mañana más", "*bostezo*" |
| christmas | 24–26 Dec | Same cap shape in `#E0453A` with white brim/pompom, green scarf `#2F8F5B` | "¡Feliz Navidad!", "jo jo pío" |
| halloween | 31 Oct | Witch hat: cone `#4A3763`, brim `#3B2B4F`, band `#F08A2E` | "¡Buu!", "¿truco o pío?" |
| newyear | 31 Dec – 1 Jan | Gold party cone `#F4B63F` with pink stripes/pompom `#FF6B81`. Looping confetti (`#F4B63F`, `#FF6B81`, `#5BB6F0`, `#7AD39A`): fall 22, rotate 220°, 2.2–4s | "¡Feliz 2027!" (use the current year), "¡pío nuevo!" |
| valentine | 14 Feb | Heart cheeks `#FF6B81`, hearts floating up | "♥ pío ♥", "te quiero, {name}" |

On the empty state, the mood applies too: morning means napping, other moods are awake. The greeting copy should follow the time of day.

## State
- `selectedTab`: `waiting | away | today`.
- `expandedRowIDs`.
- `piopio`: `mood` (derived from clock/date; re-evaluate on timer and app activation), `isAwake` (morning only, per session), `bubbleText?`, `hopTrigger`, `lookOffset`, `isTyping` (from the AskBox draft, debounced 900ms).
- Everything else comes from the existing `agenda.ts`/NeedsYou models.

## Design tokens
- **Backgrounds:** page `#FBFAF8`, sidebar `#F4F3F0`, segmented track `#F1EFEB`, inset `#F6F5F2`.
- **Lines:** `#E8E6E1`, `#E6E4DF`, `#ECEAE5`, `#EEECE8`.
- **Ink:** `#1F1E1C`. Secondary `#3A3936`, `#6E6C67`. Muted `#8C8A85`, `#9A9893`, `#A8A6A0`. Faint `#B4B2AC`.
- **Accent:** `oklch(.56 .15 255)`. **Warning/approval:** `oklch(.70 .16 55)`. **Error:** `oklch(.62 .17 25)`. **Success:** `oklch(.66 .13 150)`.
- **Radii:** 7–8 (buttons, tiles), 10 (rows), 11 (segmented), 16 (AskBox, panel), 999 (pills).
- **Type:** 32/600 greeting, 15 input, 13.5 rows, 13 UI, 12 meta, 11 badges.

## Files
- `Home Redesign.dc.html`: all turns. **Turn 3 (3a/3b) and turn 4 (moods) are the spec.** The piopio drawing and animation logic is in the `chick()` method of the inline script.
- `support.js`: runtime needed to open the HTML.
- `assets/piopio.svg`, `assets/piopio-sleep.svg`: static reference drawings for the awake and asleep poses.
- `assets/piopio.png`: the original app icon (reference only, not used in the UI).
