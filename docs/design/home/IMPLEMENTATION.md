# Home redesign + piopio: what's built

The handoff (README.md, `Home Redesign.dc.html`; turn 3 and turn 4 are the spec) was implemented on 2026-11-18. The captures are in `captures/`.

## Where
- `apps/mac/App/Piopio/HomeView.swift`: the layout (3a normal, 3b empty), the tabs, the rows, and the restyled AskBox with its perch.
- `apps/mac/App/Piopio/NeedsYou.swift`: the waiting rows (tile, pills, inset card, "Open … →").
- `apps/mac/App/Piopio/PiopioMascot.swift`: piopio, drawn in a `Canvas` from the 120-unit SVG and animated from the clock in a `TimelineView`. This covers the bob, blink, tuft sway, cursor-following face, hop, flap, bubble, nap with z's, and the outfits.
- `apps/mac/Sources/PiopioKit/PiopioMood.swift`: the moods, greetings and lines, with unit tests.
- `Design.swift` `StatusTone`: the tile colours.

## Deliberate differences
- **Colours:** surfaces, ink and lines use the app's `ds` tokens, so dark mode and the system accent keep working. Only the status tiles, the count badge and the success dots are new tokens (`StatusTone`). The orange, red and green values come from the handoff's oklch values, and each has a dark variant. The blue tile follows the system accent.
- **Greeting:** Christmas, Halloween and New Year greet with the holiday ("Merry Christmas, Antonio"), as on the moods page. Valentine's and every other day use the time of day.
- **Bubbles in English:** "on it!", "good morning!", "peep!", "zzz… still here?", "Happy 2027!" (the year being welcomed), and so on.
- **Target chip:** a pill with the target's name and no icon, as in the spec. Permissions stay beside it when a project is chosen.
- **AskBox everywhere:** the new box style also applies where AskBox is reused (the New conversation page and Chat's first run). piopio perches only on Home.
- **Reduce motion:** piopio stands still. A tap still makes it talk, but it doesn't hop.
- **First visit:** until the agenda arrives, Home keeps the top-aligned layout. Later visits start from the last agenda, so the empty state doesn't flash.

## Captures
`PIOPIO_DEMO_MOOD=morning|afternoon|night|christmas|halloween|newYear|valentine` forces a mood.
