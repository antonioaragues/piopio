# One plan: the card, the tray and the panel

Proposal and build, 2026-11-21. The mockup is `plan-flow.html`; captures of the built app are in `app/`.

## What was wrong

A Build session could show two plans that disagreed, and ask for the same answer twice:

- **Two plans.** The side panel's "Ask for one" sent the model a message asking for a `todo` checklist, and the
  panel showed that list (its first step marked "now" though nothing ran). Plan mode is a different thing: the agent
  calls `propose_plan` and the transcript shows the proposal. The panel didn't know about proposals.
- **Two places to answer.** The transcript card had Keep planning… / Edit… / a blue Approve and build, and the
  composer's tray had the same three in black with ⌘↩. Grey ink allows one black action per view, blue only for links.

## What's built

1. **No plan, no Plan block.** The Inspector's Plan block appears only when there is a proposal or a todo list, and
   the block above it then has no hairline. "Ask for one" is gone: Plan mode in the composer (⇧⇥) is the way to ask
   for a plan, and it goes through approval.
2. **Proposed.** The transcript card is a document to read: "Plan · 7 steps" and "● Waiting for you" on the right, the
   summary, steps numbered in `fg3`, files, and risks as grey dot lines (no amber ⚠), with no footer and no buttons.
   The composer's tray ("Build this plan?") is the one place that answers. The panel's Plan shows the same steps as
   "● Proposed · 7 steps", in place of any older list. A step's bold lead ("**PIO-7 Pricing:** …") or first clause
   is its title there; the whole step is its detail (click to open).
3. **Approved.** The card folds to one line, "Plan · 7 steps · Approved ›" (also "Approved with your edits", "Sent
   back", "Not answered"); clicking it opens the full card with its footnote. The panel shows the approved steps
   ("0 of 7") until the agent writes its `todo` list, which is the plan from then on.
4. **Sent back** (Keep planning): the panel's Plan reads "Revising…" while the agent works on a new proposal.

Code: `PlanCardView` and `PlanContent.latest(in:)` in `PiopioTranscript/PlanCard.swift`, the fold in `Cards.swift`
(`DisclosureCard(plan:)` starts open only while pending), `PlanBlock.shown` in `Inspector.swift`.

## Checked

Captures with the scripted model (`PIOPIO_FAUX=1`, `PIOPIO_DEMO_PLAN=1`, and the new `PIOPIO_DEMO_APPROVE_PLAN=1`):
`app/plan-none.png` (no Plan block), `app/plan-proposed.png` (card without buttons, tray, panel "Proposed"),
`app/plan-approved.png` (folded card, panel on the agent's list, 1 of 5).

Not checked: clicking the folded card open (background clicks don't reach transcript cards), the "Revising…" state,
and dark mode.
