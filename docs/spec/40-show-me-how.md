# 40 · Show me how: skills from a demonstration

Status: draft, 2026-11-23. **2026-11-24:** `/learn` and its card are built for project rules and About me (14 §9); SH0 adds skills to that same card. It develops 23 §9's "Teach by showing" and 32's `/learn`, and it
needs PAR12's skill writing (D9). Prompted by Claude's **Record a skill** (Cowork, July 2026).

## 1. What Claude does

From the dialog itself and third-party write-ups (no official Anthropic page for the feature was found):

- **Where:** Claude desktop, Cowork, the + menu › Record a skill. Pro, Max and Team; macOS and Windows; not on the web.
- **What it captures:** the screen, clicks, typing and your voice ("Your screen, clicks, typing, and voice are
  recorded, then sent to Claude"). The dialog only *warns* you not to type passwords or show private things; nothing
  is left out on its own. A mic picker sits beside Start recording.
- **What happens next:** the recording goes to Anthropic's servers, Claude writes a skill (a folder with a
  `SKILL.md`), and asks whether to save it as a new skill or merge it into one you have.
- **How it runs later:** like any skill, through whatever Cowork can use (files, connectors, computer use, Claude in
  Chrome). Sources disagree on the details.
- **What reviewers found:** one demonstration isn't a test; a stray tab or click ends up in the skill; it repeats steps
  that were only incidental; retention of the recording isn't documented; whether it survives a changed UI is open.

OpenAI's Codex is reported to have a similar Record & Replay; not checked.

## 2. Where Piopio can do better

The idea is right: showing is faster than writing instructions, and a narrated demonstration carries the *why* that a
prompt leaves out. Piopio can keep the idea and change five things, because it already sees apps and pages the way
its model acts on them (23, 22):

| Claude's Record a skill | Show me how in Piopio |
|---|---|
| A video of the whole screen | **Steps, not video.** Each action is recorded as what the model itself would do: `pressed [button "Export…"] in Numbers`, `typed "Q3" into [field "Name"]`, `opened example.com/invoices`, with a picture of that window only at each step. Small, exact, and in the same words as the tools that will run it. |
| Everything on screen, with a warning | **Only the apps you pick.** You choose Numbers and Mail; switching to Messages pauses recording ("Not recording Messages"). Password fields are never read (23 §4.2), and the never list (Piopio, password managers, system prompts) can't be recorded at all. |
| Uploaded, then written up | **Read on the Mac first.** Your voice is transcribed on the Mac; you see the steps and can delete the stray ones and mark what varies or what's secret *before* anything goes to a model. Then the model your conversation already uses writes the skill from text (pictures only if it has vision and needs them). No new destination. |
| Saved after one take | **Tried before it's kept.** The draft runs once on a new input, asking before each action; you keep it, fix it or drop it. |
| Replays what you clicked | **Keeps what you meant, picks the sturdiest way.** The skill says the goal of each step; when a connector, an MCP tool or a script can do a step, the skill uses it and keeps the clicks only as a fallback. Forty clicks to copy a table become one read through a connector. |

And a second way in, which is often better than recording: **do it together, then `/learn`.** When Piopio can already
do the job with its tools, you ask it, correct it as it goes, and `/learn` turns the conversation into the skill. The
trace is already in the model's own actions, so nothing needs translating. Recording is for jobs Piopio can't yet do,
or that are faster to show than to explain.

## 3. The experience

1. **Start.** In the composer's + menu, **Show me how…** (also `/show`). A sheet asks which apps to watch (the
   built-in browser and running apps, Numbers already ticked if it's in front), whether to use the microphone and
   which one, and says in one line what's recorded and what isn't. **Start**.
2. **Do it.** A pill at the top of the screen: a red dot, "Showing Piopio · Numbers, Browser · 12 steps",
   **Pause**, **Done**. Talk if you like ("I always pick the last month, never the current one"). Switching to an app
   you didn't pick greys the pill: not recording. ⌥Esc pauses.
3. **Look it over.** **Done** puts a review card in the conversation: the steps as sentences, each with a thumbnail
   and what you said at that moment. You can delete a step, merge two, and on any value you typed choose **It's
   always this · It varies (ask or work it out) · It's secret (never kept, asked each time)**. Piopio has already
   guessed which ones vary (dates, names, amounts, file names). **Write the skill**.
4. **Read the draft.** A skill card: its name, when to use it, the inputs, the steps, how to check it worked, and
   which steps it will do through a connector or script instead of clicks. **New skill** or **Add to "Monthly
   invoices"** when one looks close (shown as a diff).
5. **Try it.** "Try it with October?" It runs in this conversation, asking before each action the first time.
   If it goes wrong, say so; the fix goes into the draft. **Keep** saves it; **Keep and run every month** also
   offers an automation (27).
6. **Later.** When a run of the skill has to deviate (a button moved, a step failed and was worked around), the
   result ends with "The skill is out of date: Export moved to File › Export To. Update it?" as a diff you accept.

## 4. Decisions (to confirm)

| # | Decision | Alternative considered |
|---|---|---|
| SH1 | **Steps, not video.** Record actions in the vocabulary of Piopio's own tools (accessibility refs for apps, page map refs for the built-in browser), with one picture of the recorded window per step. | A screen video, as Claude does: works for any app, but costs more, carries everything on screen, and has to be turned back into actions by a model. |
| SH2 | **Per app, chosen before you start.** Switching to an app not on the list pauses capture. The never list (23 §4.2) and secure fields apply as in computer use. | The whole screen with a warning. |
| SH3 | **Review on the Mac before any model sees it.** Voice transcribed on device; you edit steps and mark values as fixed, varying or secret first. | Send first, review the written skill after. |
| SH4 | **The output is a normal skill** (Agent Skills `SKILL.md`, pi's folders), written to say *what* each step achieves and *how* as a preference order: connector or MCP tool, script, browser, app. No Piopio-only format. | A replayable macro. Breaks as soon as the UI moves, and can't use a better route. |
| SH5 | **Tried before kept,** on a new input, asking before each action. You can still save without trying. | Saved straight away. |
| SH6 | **Two ways in, one result.** Show me how (record) and `/learn` (from a conversation) both end in the same draft card and the same skill. | Recording only. |
| SH7 | **Skills update by proposal.** A run that deviated proposes a diff; nothing edits a skill on its own (26 CL7). | Silent self-repair. |
| SH8 | **Attended only, conversations first.** Recording is something you do; skills it makes run wherever skills run, with the usual grants (22, 23). | — |

## 5. What's recorded

| From | Captured per step | Needs |
|---|---|---|
| **A Mac app** | The action (press, set value, choose menu item, shortcut, typed text as the field's new value), the element it hit (role, label, its path in the window, the window's title), and a picture of that window after it. | Accessibility (23 §4.1); Screen Recording for pictures; possibly Input Monitoring for the listen-only event tap (§9) |
| **The built-in browser** | URL, the element as the page map names it (`button "Download CSV"`), clicks, typed values, navigations, downloads; a picture of the page. | Nothing new (22) |
| **Your voice** | Transcribed on the Mac, time-stamped, attached to the step it was said during. The audio is dropped once transcribed. | Microphone; on-device speech recognition |
| **Notes** | Type a note in the pill at any moment; kept like speech. | — |

**Never recorded:** apps not on the list; Piopio's own windows; the never list; anything typed into a secure field
(not even its length); raw keystrokes (text is read back from the field after you leave it, so typos and corrections
aren't kept); the clipboard's contents. Other browsers (Safari, Chrome) are see-only for computer use (23 CU6): they
can be recorded through accessibility, but the skill replays those steps in the built-in browser, where your sign-ins
may differ, and the review card says so.

**Noise is trimmed before you see it:** focus changes without an action, scrolling that led nowhere, an undo and the
action it undid. They stay in the trace, folded, in case one mattered.

The trace is a JSON file of steps (`{t, app, action, target, value?, picture?, said?}`), kept in
`<home>/recordings/<id>/` with its pictures.

## 6. From the recording to a skill

**The draft pass** is one call to the conversation's model (or Build in Auto, 28) with: the edited steps as text, what
you said, the values and how you marked them, the connectors, MCP tools and skills this conversation can use, and
pictures only for steps the text doesn't explain (a canvas, a chart) when the model has vision. It returns the skill
and, per step, the route it chose. The estimated cost is shown on **Write the skill**.

**The skill's shape** (what the draft pass is asked to write):

```markdown
---
name: monthly-invoices
description: Export last month's invoices from the billing site and file them in Numbers. Use when asked for the
  monthly invoices or the invoice summary.
---
## Inputs
- month: the month to export. Default: last month (never the current one; it isn't closed yet).
## Steps
1. Get the invoices for {month}. Prefer: billing connector `list_invoices`. Else: browser, billing.example.com ›
   Invoices, filter by month, Download CSV.
2. Add them to "Invoices 2026.numbers", sheet {month}. Prefer: script `add_rows.py` in this folder. Else: Numbers,
   File › Import, …
## Check
- The sheet has one row per invoice and the total matches the site's total for {month}.
## Learned from
- Shown on 2026-11-23 (recording 7f3a). Not tried on other months yet.
```

- Steps say the goal first, then routes in order. Clicks are written by label and menu path, never coordinates.
- What you said becomes the reasons and rules ("never the current one"), which is what a demonstration alone misses.
- A script is written only when it removes many clicks, lives in the skill's folder, and runs under Build's sandbox
  or 36's script runner, like any other.
- Secret values become a line "ask the user for the account PIN; never store it".

**Where it's saved:** your skills (`~/.pi/agent/skills/<name>/`) by default; the project's (`.pi/skills/`) when you
recorded inside a project and choose so; an agent's skills when you recorded in an agent's chat. New or merged into
an existing skill, chosen on the card; a merge is shown as a diff.

**The recording is kept** with the skill's draft until you keep or drop the skill, then deleted, unless you ticked
**Keep the recording** (useful to redo the draft later). Pictures are never copied into the skill folder.

## 7. Trying and updating

- **Try it** starts a run in the same conversation with the skill loaded and the first input you give it. Every
  acting step asks, whatever the app's or site's level, for this first run only.
- Corrections you make during the try ("no, the PDF, not the CSV") are applied to the draft as a diff before
  Keep.
- **Later runs** note when they had to leave the skill's steps (a route failed, a label changed, you corrected
  them). At the end of such a run Piopio proposes the change as a diff on a card; nothing changes without your yes.
  This is the same card `/learn` uses (32), so a skill's history is a list of accepted diffs.

## 8. What's sent, what's kept

- **Sent:** the edited trace as text, and the pictures the draft pass asks for, to the provider the conversation
  already uses. Nothing is sent while recording. With a local model nothing leaves the Mac.
- **Kept:** the recording until the skill is kept or dropped (§6); the skill as files you can read and edit;
  nothing else. Memory never learns from a recording (23 §6).
- **Secret values** are never written to the trace; they appear as `‹secret›`.

## 9. Under the hood

- **App side (Swift):** an `AXObserver` per recorded app for value, focus, menu and window changes; a listen-only
  `CGEventTap` to know where a click or shortcut landed, resolved to an element with
  `AXUIElementCopyElementAtPosition`; ScreenCaptureKit for one window's picture after each step; on-device speech
  recognition for the voice. The recorded-apps filter is applied in the app, before anything is written.
- **Browser:** the page map script (`BrowserScript.swift`) gets a recording mode that reports clicks, inputs and
  navigations with the same role and name it already computes for the model.
- **Engine:** `record.start` / `record.stop` / `record.get` / `record.discard`, the trace store, the noise trimmer and
  the input guesser (plain code, no model); `skills.draft` (the model pass), `skills.save`, `skills.propose` (a diff
  card, shared with `/learn`).
- **Shared with 23:** the element description and the never list. Recording needs only 23's *reading* layer, so it
  can come before U2; replaying Mac-app steps needs U2.

## 10. Milestones

| | Scope | You can | Size |
|---|---|---|---|
| **SH0 · Skills you can make** | PAR12/D9's minimum: the draft card (new or merge, as a diff), saving to pi's folders, `/learn` from a conversation (32 CM4). | Do a job with Piopio, `/learn`, and get a skill that the next conversation uses. | M |
| **SH1 · Show me in the browser** | Recording in the built-in browser, the review card, the draft pass with routes, Try it. Browser actions already exist (22 W2). | Show it a web chore once and have it done next month on another input. | M |
| **SH2 · Show me in Mac apps** | The per-app recorder, pictures, the pill, the never list. With 23 U2 (replay). | Show it a job across a site and Numbers. | L |
| **SH3 · Narration** | Microphone, on-device transcription, what you said attached to steps and turned into rules. | Explain while you work and see your reasons in the skill. | S–M |
| **SH4 · Kept up to date** | Deviation notes on runs, the update card, "Keep and run every month". | Accept a fix after a site changed, and schedule the skill. | M |

SH0 is useful on its own and comes first: it's what makes every later recording worth something.

## 11. Not doing

- **Watching all the time** (Rewind or screenpipe style, then mining it for skills): too much for too little; you
  show what you want learned.
- **Whole-screen video** as a mode: see SH1–SH2.
- **Macros that replay coordinates** with no model: they break silently. A step-by-step skill with a script for the
  stable part covers the case.

## 12. Questions for you

1. **Name:** "Show me how" (proposed; `/show`), or "Record a skill" as in Claude?
2. **SH0 first:** ship `/learn` and skill making before any recording (proposed), or go straight to recording in the
   browser?
3. **SH2 order:** recording Mac apps waits for computer use U2 (proposed), or record now and let the skill hand Mac
   steps to you until U2?
4. **Keep the recording:** deleted once the skill is kept (proposed), or kept with the skill?

## 13. Not verified

- Claude's feature details come from the dialog in the screenshot and third-party coverage; no Anthropic page was
  found. Sources: [Digital Applied](https://www.digitalapplied.com/blog/claude-record-a-skill-train-agents-by-demonstration-2026),
  [MindStudio](https://www.mindstudio.ai/blog/claude-record-a-skill-feature),
  [Coursiv](https://coursiv.io/blog/claude-cowork-record-a-skill),
  [Android Headlines](https://www.androidheadlines.com/2026/07/claude-cowork-record-a-skill-screen-recording-feature.html).
- Whether a listen-only event tap needs Input Monitoring on macOS 27 on top of Accessibility.
- How well `AXUIElementCopyElementAtPosition` names what was clicked in everyday apps (23's U0 measures the same
  layer).
- On-device speech recognition quality in Spanish and English mixed in one recording.
- That a model turns a trimmed trace plus narration into a skill that works on a second input more often than one
  written from a video. SH1 should compare both on a few real chores before SH2.
