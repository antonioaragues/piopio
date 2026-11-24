# 32 · The / menu: commands as intents

Proposed 2026-11-21; decided and CM1–CM3 built the same day (§7); CM4's /goal in Chat built 2026-11-23 (§8). From the user's screenshots of Antigravity's composer and a read of Piopio's
composer ([Composer.swift](../../apps/mac/App/Piopio/Composer.swift)), the engine's command list
([build.ts](../../packages/engine/src/runtimes/build.ts) `commands()`) and the specs each command maps to.

## 1. What Antigravity gets right

- **A row says what a command does at a glance.** An icon, the name in the body font, a one-line description in
  grey. Piopio's own commands come first, skills after.
- **A picked command becomes a chip.** `/schedule` turns into a token (clock icon + "schedule") at the start of the
  box, and its description floats above the box while you write the rest. You always know what your message will do.
- **Commands are verbs that wrap the next instruction**, not settings: `/schedule <instruction>`, `/goal <done>`,
  `/btw <question>`, `/plan <task>`, `/browser <task>`, `/teamwork <project>`. The menu teaches what the app can do.
- **Worth having:** btw, goal, compact, schedule, browser, plan, grill-me, teamwork, learn.

What not to copy:
- **Three ways to say "several agents"**: teamwork, boost and swarm, one with "(Preview & Quota Heavy)" in its text.
- **Skills in one alphabetical list**, user actions (automation, swarm) mixed with developer guides
  (agy-customizations, antigravity-guide, migrate-workflows), most with the same generic `<>` icon.
- **A callout that stays up the whole time you type.** It costs a line above the box for something you read once.

## 2. Where Piopio is

Most of the capabilities behind Antigravity's commands already exist in Piopio; the menu hides them.

| What | Today |
|---|---|
| Rows | Name in monospace, description in fg3, no icon. `icon(_:)` exists (Composer.swift:909) but the list never calls it |
| List | At most 12 rows, no scroll, no groups. Piopio's commands match by prefix, pi's by substring; descriptions aren't searched |
| Skills | Shown as `/skill:name` |
| Build | plan, compact, model, review, commit, new, side, then pi's templates, skills and extension commands. **/plan shows twice**: the built-in (toggles plan mode) and the `plan` extension (sent as text) |
| Chat | Only /side, plus templates and skills. No /compact, though the context popover can compact |
| Picking | A built-in runs at once (/side waits for words); a pi command inserts plain `/name ` text. Nothing says what it will do |
| /goal | Built (`piopio-goal`, 05 §2), Build only, and only findable by typing it |

## 3. Antigravity's commands in Piopio

| Antigravity | Piopio today | Proposal |
|---|---|---|
| **btw** | `/side <what>` (24) | Keep `/side`; "btw" is a search keyword for it, not a second row |
| **goal** | `/goal` in Build | Show it as a Piopio command with a chip and hint. Chat later, if the chat runtime loads `goalExtension` |
| **compact** | Build built-in; popover in both | Also in Chat |
| **schedule** | Automations are made by asking (27 §4); triggers include once (`at`) | **New.** `/automation <what and when>`: a bundled template that asks for an automation; 27's card answers. Named after what it makes, so the command, the sidebar and the card share one word; "schedule", "timer", "remind" and "every" find it. Antigravity's separate `automation` skill (a guided design) isn't needed: the model asks when details are missing. Both modes, since both load the automation tools |
| **browser** | Browser tools and pane (22) | **New, small.** `/browser <task>`: do this in the browser pane, and show it |
| **plan** | Build: plan mode | Not a command: plan is a mode, set in the mode selector (§7) |
| **grill-me** | `ask_user` exists | **New, cheap, high value.** `/grill-me <idea>`: the agent asks one question at a time with `ask_user` until it can state the plan back, then writes it. A bundled template, both modes |
| **teamwork / boost / swarm** | Parallel work board, off by default ([swarms](../research/swarms.md)) | **One command**, `/parallel <task>`: the board on for this request, with its budget shown in the chip's hint. After daily use of the board says it's worth a command |
| **learn** | Memory (14); [self-improvement](../research/self-improvement.md) research; creating skills is PAR12 | **New.** `/learn`: look back at this conversation (corrections, what worked) and propose a skill, an AGENTS.md rule or a memory, as a card you approve or dismiss. Nothing is saved without you. Waits on PAR12's skill writing |
| automation, generative_ui skills | Automations (27), visuals (25) | Nothing: the model already has these |
| agy-customizations, antigravity-guide | — | Optional: a bundled `piopio-guide` skill so "how do I…" questions about Piopio get answered from its docs |

Piopio's own that Antigravity lacks stay: /model, /review, /commit, /new. PAR12's `/init` (write AGENTS.md) joins
them when built.

## 4. Proposal

### 4.1 The menu

- **Row:** SF Symbol (11 pt, fg3), the name in the body font (13, fg), the description (12, fg3), one line,
  truncated. 30 pt high, radius 8, the highlighted row on `dsChip`, as today.
- **Groups:** Piopio's commands first, in a fixed order by use (goal, side, automation, grill-me, compact, review,
  commit, model, new, …; no plan, which is a mode only, §7), then **Skills**, then **Templates** and extension commands,
  each after a small fg3 label. Groups are hidden while filtering leaves one.
- **Scroll:** about 8 rows visible; ↑/↓ keep the highlighted row in view. No 12-row cap.
- **Matching, the same for every kind:** name prefix, then name substring, then keywords and description words.
  Keywords are per command ("btw" for side, "schedule", "timer", "remind", "every" for automation).
- **Skills by their name**, without `skill:`; the folder it came from in the row's help tag.
- **One row per name.** A Piopio command wins over a pi command of the same name (fixes the double /plan).
- **Icons:** Piopio's commands each have their own (plan `list.bullet.rectangle`, goal `scope`, side
  `bubble.left.and.text.bubble.right`, automation `clock`, grill-me `questionmark.bubble`, compact
  `arrow.down.right.and.arrow.up.left`, review `checklist`, commit `arrow.triangle.branch`, browser `globe`, learn
  `lightbulb`); skills `sparkles`; templates `text.badge.plus`; extension commands `puzzlepiece.extension`.

### 4.2 The chip

- Picking a command that takes words (side, goal, automation, grill-me, browser, parallel, a template with an
  argument hint, a skill) puts a **chip** at the start of the box: its icon and name on `dsChip`, radius 6, the same
  height as a line of text. The chip is a view before the text field, not text inside it.
- **The box's placeholder becomes the command's hint**: "What done looks like…" for goal, "What, and when or how
  often…" for automation, "The idea to pressure-test…" for grill-me. That replaces Antigravity's floating callout; the
  chip's help tag has the full description.
- **Backspace** in an empty field, or **Esc** with the field empty, removes the chip. Clicking the chip's × does too.
- Typing a known command and a space by hand (`/goal `) makes the chip the same way.
- **Nothing new is sent.** The message still goes out as `/name words`; the chip is how the composer shows a
  leading command. A saved draft ([ComposerDraft](../../apps/mac/Sources/PiopioKit/ComposerDraft.swift)) keeps the
  text, and the chip comes back from it.
- Commands that act on their own (model, compact, review, commit, new) run when picked, as today.

### 4.3 Where each runs

| Command | Mode | Kind | Runs in |
|---|---|---|---|
| /goal | Both (Chat since 2026-11-23) | Words | `piopio-goal` extension |
| /side | Both | Words | App (24) |
| /automation | Both | Words | Bundled template → automation tools (27) |
| /grill-me | Both | Words | Bundled template → `ask_user` |
| /browser | Both | Words | Bundled template → browser tools (22) |
| /compact | Both | Acts | App |
| /review, /commit, /model, /new | Build | Acts | App, as today |
| /learn | Both | Acts | Engine: a utility pass over the conversation → a proposal card (needs PAR12) |
| /parallel | Build | Words | Engine: the board on for this request |

Bundled templates live with Piopio's own resources, so both runtimes' resource loaders list them, and they show in
the Piopio group with their own icons rather than as templates.

## 5. Phases

| Phase | What | Size |
|---|---|---|
| **CM1 · The menu** | §4.1: icons, body font, groups, scroll, one matching rule, keywords, skill names, dedupe; /compact in Chat | S · built |
| **CM2 · The chip** | §4.2, for every command that takes words, including pi templates and skills | S–M · built |
| **CM3 · Cheap commands** | /automation, /grill-me, /browser as bundled templates; /goal shown as a Piopio command | S · built |
| **CM4 · Commands with engine work** | /learn (after PAR12's skill writing), /parallel (after real use of the board), /goal in Chat | M each · /goal in Chat built 2026-11-23 |

CM1 and CM2 are app-only and change nothing in the protocol. CM3 adds three template files and their rows.

## 6. Decisions (2026-11-21)

- **CM-Q1.** The hint is the box's placeholder; no callout above the box.
- **CM-Q2.** Keep `/side`; "btw" finds it.
- **CM-Q3.** `/parallel` waits for real use of the Parallel work board (CM4).
- **CM-Q4.** No `piopio-guide` skill for now: not worth its context on every request.

## 7. As built (2026-11-21)

- **Menu** ([Composer.swift](../../apps/mac/App/Piopio/Composer.swift)): groups Piopio, Skills, Templates and
  commands, each labelled only when more than one shows; about 8½ rows, then it scrolls. Matching is
  [CommandMenu](../../apps/mac/Sources/PiopioKit/CommandMenu.swift): name prefix, name substring, then from two
  letters a keyword or a word of the description. A pi command with a Piopio command's name is hidden.
- **Piopio's commands that need the engine** (/goal, /automation, /grill-me, /browser) show only where the session
  lists them, so each appears exactly where it works: /goal in Build; /browser only with the browser on; /automation
  only with automations.
- **Chip:** the message stays `/name words` in the composer's text (drafts, the queue and editing are unchanged); the
  field edits the words after the chip. The chip is its own state, set by picking a command, a space after one typed
  by hand, or a message put in the box (a draft, an edit), never re-read from the text while you type: the text
  field can't be rewritten under the cursor. A command with a chip needs words to send. ⌫ listens for U+007F, what
  the Mac's delete key sends (SwiftUI's `.delete` is U+0008).
- **Plan is a mode only** (decided after use, 2026-11-21): no /plan command and no chip. It lasts past one message
  and decides what the agent may do, like Auto-edit, so it lives in the mode selector, which already showed it; a
  chip for it was the same state in a second place. pi's own /plan extension command isn't listed either.
  Skills without an argument hint get "What the skill should do…".
- **Templates** ([piopio-commands.ts](../../packages/engine/src/runtimes/piopio-commands.ts)) join pi's through the
  resource loader's `promptsOverride`, so Build and chats have them; a template of the same name in the user's pi
  folder or a package wins. Agents' chats (pi-durable) don't have them yet.

## 8. CM4, /goal in Chat (2026-11-23)

- **Chats have it.** The same `piopio-goal` extension as Build joins a chat's extensions, so /goal lists there and
  works as in Build: another round each time the model ends a turn without `update_goal`, up to 25 rounds or $5.00,
  Stop pauses it, `/goal continue` and `/goal off`. The composer shows it wherever the session lists it (it was
  Build only).
- **Checked:** an engine test (`goal-budget.test.ts`): a chat lists `goal`, and a goal set there gets a second round
  on its own and ends when the model calls `update_goal`. Not yet with a real model.
- **Still waiting:** /learn needs skill writing (PAR12, spec 40 SH0); /parallel waits for real use of the board (CM-Q3).

