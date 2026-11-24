# Spec consistency: where docs/spec disagrees with itself

2026-11-23. A read of all 42 specs in `docs/spec/` plus its README, looking for three things:

- **Contradiction:** two places that say incompatible things today.
- **Stale:** an earlier place still states what a later spec overturned, with no note at that place.
- **Term:** one word or ID with two meanings, or two words for one thing where one was retired.

Nothing in `docs/spec/` was changed. This page only lists what to fix.

## Applied on 2026-11-24

The clear-cut fixes below were applied to 38 files in `docs/spec/`, as notes at the stale place ("Since 18 §15
…") and corrected status lines. Earlier text was kept as history. A later draft or an unbuilt decision got a pointer
worded "would change this", not a "Since". Nothing marked **Your call** was touched.

- **Applied:** all of §1 except confirming 27 and the missing decisions-log rows; §2 except 2.8's naming; §3 except
  3.10 and 3.11; 4.1–4.6, 4.8's note, 4.10; 5.1–5.6, 5.10, 5.12; 6.1–6.7; 7.1–7.8, 7.11, 7.12; 8.1–8.3, 8.5, 8.7;
  9.1; 10.1–10.3, 10.4's note in 34, 10.6–10.9; 11.1, 11.2; 12.1–12.6, 12.8, 12.10 except the alarm and version
  items, 12.11; §13; 14.1, 14.2 for the calendar tool; 15.1–15.3; 16.1; 17.1; 18.2 where the word was written after
  its retirement; 5.2.
- **Corrected in place** (slips, not history): "Full access" to "Full auto" in 39; "26 CL9" to "CL8" in 41;
  "Settings › Cloud" and "Settings › Providers" to the built pane names in 30, 33 and 34; "Setup › Abilities" in 12;
  "routines" in 22 §16 and 23; AM3's reviewer in 28; plan in 32's command lists; "13 §5.x" citations in 19 and 30;
  "Telegram through a tunnel" in 19; `calendar_list_events` and two citations in 35; 09-roadmap's tracks, Parked
  and Later lists.
- **Left for you:** everything in §20, plus the README rows that are missing altogether (CT, CA, PS, SB, NF, 32,
  AL), and renaming any ID (§19).

What applying them turned up, which corrects this page:

- **13.1:** `agents.deploy` does exist in the built protocol (the Mac's engine sends it to the cloud, with no
  `target`); `catalog.search` exists too. The note in 03 says so.
- **13.4:** `catalog.db` does not exist at all (`paths.ts` uses `sessions.json` and `projects.json`). The notes
  correct the ledger, projects and approval rules; other mentions of `catalog.db` in 02 §4.3 and 05 BP3 still read
  as if the file existed.
- **4.6:** 07 §7's map is not wholly unmatched: General, Models and Chat exist. 07 now lists the twelve built panes.
- **12.11:** 42 is decided but not built, so 06's voice-note text stands today; it got a pointer, not a "Since".
- **15.1:** 35 §16 replaced the generic `tool` source for calendars only, and the timed refresh is still not built.
- **4.10:** 34 OV8 (2026-11-24) replaced the footer cost line with a chart button; the notes say that.
- **Still unmarked, found in passing:** 26 CL4's "does tasks · reviews · merges"; "routine" and `schedule`/`watch`
  in 19 S3, §9 and §11; "Keep" in 35 §3.4, §3.7 and §6; "plan" in 32 §4.1's Icons line; 09's Track G and its
  questions list still show 14's M4, Q1 and Q3 as open though 14 decided and built them on 2026-11-24; 10 §8
  still names a slot "Chats and notebooks"; 30 §8 and §13 still differ on the cloud ref's field.

## How to read it

Each item gives both places as `spec §section, Lline` with the words quoted, then **Wins** and why.
Line numbers are as of commit `79881a7`.

How the winner was picked, in order:

1. Built beats planned (an "as built" section, or 09-roadmap's record).
2. A later spec marked decided beats an earlier one.
3. A later draft overturns nothing. The earlier text stands, and the item says what is missing (usually a pointer).
4. Where none of these settles it, the item says **Your call** and what has to be decided.

How it was made: eight readers each took one subject and read their specs in full; every quote below was then
checked against the files by exact match. Not done: the "where it touches other specs" tables of 27–42 were not
each walked back to the touched spec, and `docs/design/`, `docs/status.md` and `docs/history/` were not read. Code
was opened in four places only, to break a tie, and each is named where used. Items marked *(less sure)* rest on a
reading that could be loose wording instead of a real difference.

## The short version

Five patterns account for most of the 150 or so items:

1. **Status lines lag the work.** Seven specs say "nothing built" above their own "as built" sections, README calls
   27 "not yet confirmed" although it is built and migrated, and 09-roadmap lists as left what its own "Done" notes
   record (§1).
2. **18's removals never reached the founding specs.** 01, 02, 03, 04 §1, 07 and 08 still describe modes, lenses,
   Spaces, pi-durable chats and OpenRouter-only. 08 has no note at all. Later specs then copied the stale picture:
   30 puts notebooks and pi-durable chats in the cloud, 22 and 12 say chats run on pi-durable (§2, §13).
3. **Long specs contradict their own later sections.** 18 (§3), 35 (§15), 30 (§12), 24, 25, 28, 29 and 14 each carry
   "as built" or "decided after review" sections whose changes are noted only there, not at the place they replace.
4. **Decided specs lean on unconfirmed drafts.** 34, 31 and 36 use 28's roles and 29's routes as if they existed,
   and 28 and 29 disagree with each other in four places (§10).
5. **Names drift.** The place where things wait for you has three names, "routine" survives its retirement,
   "Full access" appears for "Full auto", and phase IDs repeat across and inside specs (§18, §19).

Decisions only you can make are collected in §20.

---

## 1. Status lines, README and the roadmap

**1.1 Automations are built but still "Proposed".** *Contradiction.*
README decisions log, L105: "(draft 2026-11-18, [27](27-automations.md), not yet confirmed) … Would supersede 06
PR1–PR3 and PR6, 19 S3's watches, 21 AD5 and 26 CL10. | Proposed |".
27 status, L3: "A1 and A2 built 2026-11-18 (§10)"; 27 §10, L259–260: "`routines.*` and `offer_repeat` are gone."
09 L21 agrees ("built 2026-11-18").
**Wins:** 27 as built. AU1–AU12 were never marked confirmed, so confirming them is **your call**; then README's row
becomes "Supersedes", 27 loses "draft", and the pointers in 06 §6 (L182, "proposes") and 26 CL10 (L46, "proposes")
change tense.

**1.2 "Nothing built" above "as built".** *Contradiction inside each spec.*

| Spec | Status line | Its own later section |
|---|---|---|
| 12 | L3 "nothing is built yet" | L42 "**Built**"; L143 "(built, above)" for C3 |
| 17 | L3 "Planned; nothing built yet." | §9 L264 "DP4 as built (2026-11-17)"; §10 DP1 |
| 20 | L3 "nothing here is built yet" | §10 L153 "P1 as built (2026-11-10)" |
| 21 | L3 "nothing here is built yet" | §7 L100 "D1 as built (2026-11-11)" |
| 24 | L3 "nothing here is built" | §10 L267 "SD1–SD2 as built (2026-11-17)"; §11 SD3 |
| 26 | L4 "nothing here is built" | §11 L221 "C1 as built (2026-11-17)" |
| 10 | L3 "Not implemented yet; the first step is the inspection in §6." | §11 L176 "Status (2026-10-22): P0 built" (and the inspection is §9) |

**Wins:** the as-built sections in every row.

**1.3 The roadmap lists as left what it records as done.** *Contradiction inside 09.*
09 L21–22 ("Left"): "26 **C1–C4**", "24 side conversations **SD1–SD4**; 17 **DP1** Watchdog rules and **DP4**
non-blocking subagents". 09 L147: "side conversations … decided 2026-11-12, not built". 09 L142: "nothing deployed to
a real account yet".
09 L34–36: "**Done 2026-11-17:** spec 26 C1–C2 … side conversations SD1–SD3 (24 §10–§11), non-blocking `task` DP4
(17 §9), the Watchdog's rules DP1 (17 §10) … and C4". 09 L24: "the Worker on a real account (2026-11-19 …".
**Wins:** the dated Done notes. Really left: 26 C3, 24 SD4, 17 DP6. The heading "Where things stand (2026-11-12)"
(L7) is also eleven days old.

**1.4 The roadmap's Later and Parked lists contradict Now.** *Contradiction inside 09.*
09 L71: "**Parked** … cloud sandboxes, the iOS companion." 09 L202 (Later): "Mac Bridge · cloud Threads/Spaces · iOS
companion · … · cloud Build sessions · web preview · semantic search."
09 L53: "Then **Cloud K2** (chats in the cloud), then **K3** (the iPhone app…)"; the preview is built (22 §6.1) and so
is search by meaning (14 M1).
**Wins:** Now/Next. Also stale in 09: L112 "DPQ1–DPQ6, most of them moot since TD2" (TD2 itself went with 26 CL11);
L208 "**None open** as of 2026-10-18".

**1.5 Connectors C3: built or waiting.** *Contradiction.*
09 L67: "**Connectors C2–C3:** after Piopio's own Google and Microsoft OAuth apps exist."
12 L143: "**C3:** Linear, Notion, Jira and Confluence, GitHub, Sentry (built, above)".
**Wins:** 12 (2026-11-21).

**1.6 The roadmap's Tracks table has no row for 25, 28, 29, 35, 36 or 39.** 35 L1–L4 (first part) and 39 are
built; 25 V1–V4 are built. *Stale.* **Wins:** the specs.

**1.7 README summary rows behind their specs.** *Stale.* **Wins:** each spec's own status line.

| Row | README says | The spec says |
|---|---|---|
| 12 (L19) | "first Google Calendar and Outlook" | C3's six apps built (L143) |
| 17 (L24) | "planned" | DP1, DP4, DP5 built |
| 19 (L26) | "Dispatch becomes the default team; draft 2026-11-09" | decided; "Since 2026-11-17, 26 … replaces teams" (L3–4) |
| 20, 21 (L27–28) | "decided" / "plan" | P1–P4 and D1–D7 built; team parts replaced by 26 |
| 22 (L29) | "draft 2026-11-12" | "2026-11-15: the user chose this design" (L3–4) |
| 25 (L32) | "draft 2026-11-16" | V1–V4 built |
| 30 (L37) | "decided 2026-11-19" | adds "K1 built the same day (§13)" |
| 31 (L38) | "phases A1–A4 … A1 (Claude Code) built" | A1–A3 built; A5 added; CA11–CA14 decided 2026-11-23 |
| 35 (L42) | "Keep turns a visual into an app … L1 built" | "Make app"; L2, L3 and part of L4 built |
| 39 (L46) | "(NF1–NF2)" | NF3 too (L4) |
| 41 (L48, L109) | "(PM1–PM10)" | PM11 (L3) |
| 18 (L25) | stops at §16–§20 | §21–§23 (CF27–CF32) exist |

**1.8 Decisions-log rows overturned with no mark on the row.** *Stale.* **Wins:** the later decided spec in each
case; the row needs "superseded by …".

| Row | Says | Overturned by |
|---|---|---|
| X10 (L67) | "Debate is a mode of the chat page (and `/debate`) … agents also need instructions" | 16 L3 "Removed 2026-11-15"; 19 §9 L261 "Create works with nothing filled in" |
| C2, C3, CQ1, CQ2, AQ13 | lenses, front door, notebooks | CF row lists them; the rows are unmarked |
| C4–C7 (L77), AQ4 (L91) | "Space knowledge + memory doc"; "Spaces and Agents stay separate" | 18 CF4 (not in the CF row's list) |
| B4 (L73), BQ1 (L85) | three approval modes, one default | 18 CF3: five choices; Read only for document folders |
| M1 (L68) | "OpenRouter only in v1" | 10 §11 (P0 built 2026-10-22), 31 |
| AQ7 (L94) | on-device utility model "first" | 07 §1.3 (see 10.1) |
| AQ9 (L96) | "called **Inbox**" | 21 §8 (see 18.1) |
| AQ10 (L97) | "agent boards" later | 26 CL12: agent boards go |
| A3 (L79), A4–A9 (L80) | channels v1; "Author locally → deploy" | 30 (see 12.1, 12.2) |
| TD3 in TD1–TD8 (L102) | "cloud build tasks wait for the Mac" | 30 CT3 (see 12.5); the CL row lists only TD1, 2, 6, 7 |
| X1 (L59) | "BYO Cloudflare account" | 33 PS1: a server is a second kind of cloud |

Missing rows: the log has OV, PM and VO but none for 30 CT1–CT6, 31 CA1–CA14, 33 PS1–PS8, 37 SB1–SB7, 39 NF1–NF3,
32, or 35 AL1/AL9, all decided in their specs.

---

## 2. What 18 removed, and who still describes it

18 (decided and built from 2026-11-07) removed lenses, notebooks/Spaces, the organizer and the Chat start pages,
and on 2026-11-15 moved chats from pi-durable to the pi SDK. **18 wins every item in this section.**

**2.1 08 describes the old shell with no note anywhere.** *Stale.*
08 §1, L5: "**Mode switcher** in the sidebar header: `Build · Chat · Agents` (⌘1 / ⌘2 / ⌘3)." 08 §2, L11: "Chat:
Pinned · Spaces (→ topics) · Projects (chat lens) · Threads". 08 §5, L35: "In a project, the new session page there;
otherwise the chat start page." 08 L37: "Approvals inbox | ⌘⇧A".
18 CF9, L511: "The compose button, ⌘N and File › New Conversation open the New conversation page with no project".
15 §1, L20 (built 2026-10-25) already had "The one sidebar".
08 was edited on 2026-11-19 (§9), so it reads as current. 06 UI3, L270 repeats "⌘1–3 stay the mode switcher".

**2.2 01's glossary keeps Space, Lens and three modes.** *Stale.*
01 §4, L31: "Shared by Build and Chat (folder lens)"; L41: "| **Lens** | …"; L35 Space; §5 L52: "one SQLite file per
space"; §6 L60: "The three modes described in docs 04–06." README L3: "It has three modes".
18 §3, L64–66: "**Space, Topic, Organizer, Lens** leave the app."
Only the Thread row was updated. The glossary also lacks today's words: conversation, helper, automation, playbook,
way of working, place, app, Library.

**2.3 04 §1 still backs a thread with pi-durable.** *Stale.*
04 §1.1, L25: "Backed by **one pi-durable session** (`threads/<id>.sqlite`)"; T13, L45: "Move to Space".
18 §15, L475: "A chat is a pi SDK session (BuildRuntime with a **chat profile**), its file in `<home>/chats/`".
04's note (L63) covers §2 and §3 only.

**2.4 Specs written after 2026-11-15 that still say chats run on pi-durable.** *Stale / contradiction.*

| Place | Says |
|---|---|
| 22 §13, L271 | "chats run on pi-durable and" |
| 22 §14, L330 | "an extension for chats (pi-durable) and one for Build (pi-coding-agent)" |
| 24 §4, L94 | "Build (pi SDK) and chat (pi-durable)" |
| 12 §4, L172 | "chats, notebooks and agents (pi-durable) and Build (pi)" |
| 07 EX4, L113 | "**pi extensions run in Build only.** Threads, Spaces and Agents run on pi-durable" |
| 07 MCP2, L59 | "For pi-durable runtimes (Threads/Spaces/Agents)" |
| 02 §6, L129 | "pi-durable session per thread" (while 02's own diagram, L15, says "chat profile (pi SDK)") |
| 30 §8, L216 | "`ConversationDO`: a cloud chat or notebook, a pi-durable session like the Mac's chats" |

25 §14 (L316) and 31 (L24: "chats run pi-coding-agent, agents run pi-durable") have it right. For 30 this is more
than wording: K2's design has to be restated for a pi SDK chat (33 §8 already assumes "the engine's own sessions").
For 07 EX4 it leaves open whether installed pi extensions now load in chats.

**2.5 30 and 31 keep notebooks alive.** *Contradiction.*
30 §3.1, L48: "| **Notebook** | As today, with its files on the Mac | Its files in R2; the organizer runs in the
cloud |"; 30 L244: "the location chip for chats and notebooks". 31 L174: "Notebooks' heading organizer".
18 §11, L341–342: "**Notebooks removed:** … The Space runtime, the organizer, routing …".

**2.6 15 still offers notebooks, the Folder lens and ⌘⇧N as New Notebook.** *Stale.*
15 §2, L30: "Chats and Notebooks; New chat (⌘N) and New Notebook (⌘⇧N) … (the Folder lens, 04-chat §2)"; L33:
"**Always shown, whatever you choose:** Home, Needs you, Pinned…".
18 §13, L437: "**New project** (⇧⌘N …". 15's note (L6) covers only the Chat switch. No spec says what the welcome's
first step shows now.

**2.7 Debate still "stays" in 18.** *Stale.*
18 §4, L131: "**Model, `+` and Debate don't change.**"; §10, L291: "The Debate page stays, as before."
16 L3: "**Removed 2026-11-15.**" **Wins:** 16.

**2.8 "chat profile" names two tool sets.** *Term.*
04 §2, L73 and 18 §8, L207 ("The chat profile also removes `edit` and `write`"): a folder conversation that reads.
18 §15, L475: a conversation with no project. 05 DG2, L62 still says "Chat projects and review sessions don't run
it", a kind 18 removed. **Your call:** the first is really "Read only"; one of the two needs another name.

**2.9 Do chats have file tools?** *Stale.*
18 §15, L479: "No file or command tools, no approval modes".
04 T14, L46 (built 2026-11-20): "a chat has a folder of its own … It writes files there with `write` and `edit`".
31 L64–65: a chat on a coding agent "runs in its own folder in Auto-edit".
**Wins:** 04 T14 and 31 (later, built). 18 §15 needs the pointer.

---

## 3. 18 against itself

18 has 23 sections written over two weeks. Its "Since" notes sit at §11 and §16; these places have none.
**The later section wins each time.**

| # | Earlier, unmarked | Later |
|---|---|---|
| 3.1 | CF1, L35: "**One start: "New conversation".** Home is that page" (also §7, and README's CF row) | §14, L453: "The `+` buttons open a centered start page in the main window again"; CF9, L511 |
| 3.2 | §10, L300: "**⌘N always opens Home with no project.**" | CF9, L511: ⌘N opens the New conversation page |
| 3.3 | §4, L92: "With no project there's no chip and no line"; CF2: the project is a chip | CF11, L513: "a selector in the box's bottom row … not a chip on top. With no project, the line under the box says so" |
| 3.4 | §6, L176 "(no folder)"; L184 "Clicking its name opens the project page"; §4, L100 "phase 2 adds folder-less ones"; §7, L194 "Projects without a folder" | CF4, L38: "a project is always a folder"; CF20, L559: clicking folds; CF21, L560: "**No project page.**" |
| 3.5 | CF17, L544: "**The project page is a home, not tabs.**" | §19, L555: "Replaces CF17's page" |
| 3.6 | CF13, L515: quick picks under the box | CF25, L576: replaces "the box's "Or in" line from §16, CF13" |
| 3.7 | CF29, L593: "**The compose button is a menu:**" | CF31, L604: "This replaces CF29's pencil" |
| 3.8 | §6, L170: a "Needs you 3" sidebar row | 21 §8, L127: "the Needs you row is gone, and so is its page (2026-11-18)" |
| 3.9 | CF22, L561: project settings end with "Routines" | 27 §4, L148: "in place of Routines, "2 automations work here ›"" |

**3.10 Which area gates New Project?** *Contradiction.*
18 §10, L295: "the Chat area is always on, and its switch is gone."
18 CF31, L604: "New Project… (⇧⌘N, with Chat on)"; §17, L531: "the Projects area off" (no such area exists).
**Your call:** CF31 is later but reads like a slip for "with Build on".

**3.11 ⌘O.** *Contradiction, small.* 18 CF14, L527: "Open Folder… (⌘O)". 18 CF23, L562: "⌘O to open it in your
editor". Probably meant only inside the settings editor; the spec doesn't say the sheet takes the key.

---

## 4. Sidebar, Home, Settings and the right column

**4.1 Agents in the sidebar.** *Stale.*
27 §12, L341–347 (2026-11-19): "the Agents row opens a list column beside the agent's page … no per-agent rows in the
sidebar (18 CF10)".
18 CF27–CF28, L591–592 (2026-11-20): "**Agents is a sidebar section,** after Pinned and before Projects … The
agents' list column beside it is gone; so is the Agents row".
**Wins:** 18 §21. 35 §4.4, L201 also still cites "18 CF10, CF27"; CF10 was replaced.

**4.2 Sidebar order.** *Contradiction.*
26 §5, L87 and 21 §8, L126: "Search · Home · Projects · Agents · Conversations."
27 §4, L94: "Search · Home · **Automations** · Agents … · Projects · Conversations."
**Wins:** 27 and 18 CF27 (later, built). No single spec states today's whole list (Search and New · Home ·
Automations · Library · Pinned · Agents · Projects · Conversations).

**4.3 06 §12 "Agents UI" is replaced and unmarked.** *Stale.*
06 §12, L265–268: "Sidebar: **Inbox** (count badge) at the top"; "Agent page tabs: **Chat** · **Conversations** ·
**Runs** · **Memory** · **Definition** · **Channels** · **Costs**"; UI1: "the approval mode as a badge".
21 §9, L156: "Chat · Setup. The info panel and the Activity tab are gone."; 21 AD6, L42: "**Per-tool permissions**
… Off · Asks · Allowed."
**Wins:** 21 (D3 built 2026-11-11).

**4.4 The agent "info panel" outlived its removal.** *Stale.*
30 §3.2, L66: "in the info panel's footer"; §7, L192: "**Agent info panel (13a):**"; CT1, L260; 34 §2, L31.
21 §9, L156 (above) and 30's own §13, L302: "**The agent's header: Keep it always on** (a pill beside ⋯)".
**Wins:** 30 §13 as built.

**4.5 Agent Setup: six questions with "When it acts", or four groups.** *Stale.*
21 §9, L169–171: "the six questions on the left … **When it acts:** its schedules as sentences".
27 AU3, L48: "Setup loses "When it acts"."; 27 §12, L343: "Setup is four groups".
**Wins:** 27 (built). Also 12 §2, L38 calls the tools list "Setup › Abilities"; 21 L175 and 22 §16 call it "What it
can use". **Wins:** "What it can use".

**4.6 Settings pane names.** *Contradiction.* **Wins:** the built name in each row (pane labels checked in
`SettingsView.swift`).

| Stale or wrong | Built |
|---|---|
| "Settings › Cloud": 30 L73, L180, L195; 33 §4, L66; 34 L140 | "Settings › This Mac & cloud › Cloud": 30 §13, L293; 33 §9, L181 |
| "Settings › Providers": 34 §6.1, L131 | "Settings › Models": 10 §11; 29 PO1, L75; 31 §6 |
| "Settings › Chat › Memory": 07 §5.1, L93; MM1, L119 | "Settings › Memory": 14 §5.3, L133; M3 built 2026-10-25 |
| "Settings › Conversations": 24 §6, L188, keys `side.*` (L214) | "Settings › Chat › Side conversations", keys `chat.side*`: 24 §11, L324 |
| "Settings › Skills" (07 L51), "Settings › Agents" (06 L169), "Settings › Advanced › Logs" (02 L151) | no such panes |

07 §7's "Settings map" (L128–133) is the only map in the specs and matches nothing built. No spec holds the
current list of panes.

**4.7 The Build right column has two vocabularies.** *Contradiction / gap.*
05 §1, L8–9: "Inspector (toggle)" with "[Changes] [Files] [Git]"; 08 L6: "(⌘⌥I)".
22 §5, L137: "a **Browser** tab, next to Summary and Files."; 37 SB4 adds subagent tabs.
**Wins:** 22 and 37 describe what is built, but "Summary" is defined only in docs/design. **Your call:** a note in
05, or a spec section for the column.

**4.8 Where an opened visual goes.** *Contradiction inside 25.*
25 §4.3, L163: "in a **Visual** view next to Browser and Files".
25 §14, L348: "**Different from the spec:** Open is a sheet, not the right column".
**Wins:** §14 today. **Your call** whether the column is still the target.

**4.9 Sidebar footer.** *(less sure)* 30 §5, L163: "`This Mac · reachable from the cloud`". 34 §9, L233: "Sidebar
footer: unchanged text, opens Spend." Neither says how the two share the line. **Wins:** 34 today (built).

**4.10 The usage page has three names.** *Stale.*
07 CO2, L46: "a global **Usage** page"; 06 UI11, L278: "Clicking it opens Costs."; 28 AM10, L87: "Usage groups by
role."
34 OV1, L245: "The page is **Overview**."
**Wins:** 34 (decided, Spend built). 28's "By role" view has no counterpart in 34's selector.

---

## 5. Permissions, approvals and the sandbox

**5.1 05 still says three modes and one default.** *Stale.*
05 §6, L102: "Three modes, set per session (default per project; global default = **Auto-edit**)".
18 §10, L267: "`read_only` is a fourth approval mode"; 18 §4: a folder without code markers "starts in **Read
only**"; Plan is a fifth choice.
**Wins:** 18 (built 2026-11-07).

**5.2 "Full access" for "Full auto", and "asks nothing".** *Term and contradiction.*
39 §2, L24: "**No Full access while filtered** (NF3 …): Full access has no sandbox and asks nothing".
05 AP3, L112: a deny-list "that always asks even in Full auto"; 18 L118: "(the deny-list still asks)".
**Wins:** 05 and 18. The mode is "Full auto" (so says `Permissions.swift`), and it does ask for the deny-list. In
41, "Full" is something else again: a client's grant level.

**5.3 Reads and the network in the sandbox.** *Stale.*
05 AP5, L114: "Reads and the network are not restricted."
39 §1, L8–9: the sandbox "hides Piopio's data, sign-ins, credential files, SSH private keys and the Keychain tool";
§2 filters the network for projects not yet trusted.
**Wins:** 39 (built 2026-11-23). 02 §7, L145 is older still: "OS sandboxing (Seatbelt profiles) is later."

**5.4 Project trust has no home in 05.** *Stale reference.*
07 EX1, L110: "loaded only for trusted projects, 05-build". 05 never mentions trust; 39 §2 and 31 L117 define it.
**Wins:** 39. 05 §6 should carry the rule or 07 should point to 39.

**5.5 Web tools in Ask mode.** *Contradiction.*
18 §4, L116: "| Ask | yes | ask | ask |" (first column is reads, search, web); L269: web tools "are on in every mode".
05 §6, L106: "| **Ask** | auto | ask | ask | ask | ask |" (fourth column is network tools); 22 §14, L335: "they run
in Read only and Auto-edit, and ask in Ask."
**Wins:** 05 and 22 (`policy.ts` asks). Open point for you: Read only runs the web freely while Ask asks.

**5.6 A side conversation's permissions.** *Contradiction inside 24.*
24 SC5, L61: "**Same project, same or narrower permissions** … It can't give itself more than its parent has."
24 §11, L352–353: `side_start` takes "`project` … The side conversation works in that project's folder, with its
permissions".
**Wins:** §11 (26 CL11, built). SC5 and README's SC row need the exception: a chat with no file tools can start a
side conversation in a Full auto project.

**5.7 Board helpers' mode.** *Contradiction inside 26.*
26 §4, L78: "**What helpers may do without asking:** the members' mode today."
26 §7.1, L145: "permissions never wider than the parent's."
**Your call:** as written, an Auto-edit conversation can have Full auto helpers. 39 caps it only in filtered projects.

**5.8 How long an approval waits.** *Contradiction across surfaces.* *(less sure)*
06 AS1, L229: tokens "expire (default 24 h → denied)". 05 AP4, L113: "Approvals time out? **No** by default." 27 §5,
L173: a waiting run, no expiry stated. 36 §4.2, L163 (draft): "(default 3 days)".
**Your call:** an automation that runs as an agent falls under both 06 and 27.

**5.9 Approvals over a channel.** *Contradiction.*
06 AS1, L226–228: the request goes to the app and "the **owner's preferred channel**".
30 §4.1, L108: to a channel "only if the agent has one and you asked for it there".
**Your call:** 30 is the decided target, but 19 §9 (built) still announces approvals on the channel as 06 says.

**5.10 Hand-offs: the design was not built, and later specs cite the design.** *Stale.*
22 §4.3, L110: "press **Hand back**". 22 §15, L379: "there is no paused run or Hand back button."
30 §4.2, L117: "as on the Mac (22 §4.3)"; 23 §5 also uses "Hand back".
**Wins:** §15 is what exists; §4.3 carries no note.

**5.11 Site grant choices.** *(less sure)* 22 §1, L17: "This time · In this conversation · Always · No." 22 §15, L373:
"Allow · Deny · "Allow, don't ask again"". "This time" is missing and not under "Not in W2". 23 promises the same
four for apps.

**5.12 Coding-agent tasks.** *Stale, pending build.*
05 AP7, L116 describes `external-agents.ts`; 37 SB7, L33: such tasks "keep their card … and always wait"; 17 §9
says the same.
31 CA14, L120–122 (decided 2026-11-23, not built): "A `task` handed to Claude Code or Codex becomes a side
conversation on that agent's runtime".
**Wins:** 05, 17 and 37 describe today; all three lack a pointer to CA14.

**5.13 "Never move to credits".** *(less sure)* 31 §8, L172–173: "Never move to credits without asking (spec 29)."
29 PO6 offers "**Switch and tell me**". 29 is a draft; once confirmed, 31's "never" is only the default.

---

## 6. Subagents, side conversations and Dispatch

**6.1 Does `task` block?** *Stale.*
05 §4, L48: "Blocks its parent today; non-blocking is 17 §3 (DP4)."
17 §9, L269: "**`task` returns at once** by default".
**Wins:** 17 §9 (built 2026-11-17).

**6.2 The block above the composer.** *Stale.*
24 §11, L374–375: "the block stays only for subagents at work (17 §3)."
37 SB5, L31: "The "Subagents" block above the composer goes."
**Wins:** 37 (built 2026-11-22). 37 §3, L44 ("side conversations stay as they are") is loose beside its own §6, L82.

**6.3 "You don't talk to it."** *Stale.*
24 §0, L18: a subagent: "You don't talk to it". 26 §7.1, L137: "A read-only piece of this turn".
37 SB4, L30: "its own composer (steer it while it works, ask a follow-up after; its approvals show there)".
**Wins:** 37. Whether subagents are still read-only is not stated anywhere after 37; **your call**.

**6.4 17 §2.6: holds, or has no owner.** *Contradiction inside 17.*
17 note, L23: "§3, §4, §5 and §2.6 still hold". 17 §10, L309–310: "§2.6's cap has no owner."
**Wins:** §10. Only "at most 4 running" survives (24 §4). The "$3 per started session" cap is orphaned, so a side
conversation has no cost cap anywhere.

**6.5 Watchdog on side conversations.** *Stale.* 24 §8, L238 lists it under Later; 17 §10, L312–313 built it.
**Wins:** 17 §10.

**6.6 `/goal`'s limit.** *Stale.* 05 §4, L52: "up to 25 rounds." 32 §8, L150: "up to 25 rounds or $5.00".
**Wins:** 32 (`goal.ts` has the cost cap).

**6.7 The `[Routine]` marker.** *Stale.* 24 §10, L280: `side_start` is refused after a message starting "`[Routine]`".
27 AU12, L57: "the `[Routine]` prefix becomes `[Automation]`." **Wins:** 27. Worth a look at the code: if the guard
still matches only `[Routine]`, an automation's run could start side conversations.

---

## 7. Agents, teams and helpers

26 (decided 2026-11-17, C1–C2 built) wins each of these. 19, 20 and 21 carry header notes naming TD1/2/6/7,
PT1/3/4/7/8 and AD1–3/7; the places below are outside those lists and unmarked.

| # | Earlier, unmarked | 26 |
|---|---|---|
| 7.1 | 19 S1, L32: "A team is an agent too; its board is one more tab on its page."; S5 | CL2, CL12. And 26 L5–6 itself says 19 "S1–S5 … still hold, more strictly" |
| 7.2 | 19 T1, L93: "**One kind of agent.** … There's no separate "subagent" type." | CL1, L37: what exists only for a piece of work "is a **helper**, not an agent" |
| 7.3 | 19 T4, L103: "**Leads don't do the work**" | 20 PT5, L33 and CL3: the lead does small things itself |
| 7.4 | 19 CH-T1, L198: "A channel can point at an agent or at a team"; L204: the front agent routes "by opening a task" | CL12, L48: the front agent "doesn't hand out work"; 27 AU7: "Piopio has no channels" |
| 7.5 | 21 §1, L28: "**Agents can join teams.**"; §10, L207: "**Join a team** (5d-1)" | CL2, L38: "never join a team" |
| 7.6 | 20 §3, L46: "who works here: Piopio, an agent, or a team"; §9, L149 | 21 AD4 and CL2: agents are never assigned to a project |

**7.7 Helper kinds.** *Contradiction inside 26.* §7, L125: "(`build`, `review`, `merge`)". §11, L230: "two kinds,
`build` and `review`. Merging is the board's". **Wins:** §11 as built.

**7.8 Who interviews a new agent.** *Stale.* 06 AD5, L66: "**The Builder interviews first**". 19 §9, L256: "**An
empty agent interviews you**". **Wins:** 19 and 21 (built). 06 AS5 still gives "the Builder" a job; **your call**
whether a Builder exists at all.

**7.9 `ask_user` or `ask_owner`.** *Contradiction.* 06 UI7, L274: an `ask_user` question is "a card in the
conversation, not a sheet above the composer". 21 §10, L196–198: the interview asks with `ask_owner` as "chips above
the composer". **Your call:** two tools or one renamed; 24 lists both.

**7.10 `save_skill`.** *(pending 40)* 06 §4, L99: the agent writes a skill on its own. 40 SH7, L73 (draft): "nothing
edits a skill on its own". 06 stands until 40 is confirmed; then decide whether a run's `save_skill` becomes a
proposal. 06 §12.2, L292 "**Teach a task:**" has no pointer to 40.

**7.11 Agent-to-agent across engines.** *Stale.* 06 AA7, L201: "both agents must be in the same engine". 30 §4, L96:
"a cloud agent asks a Mac agent through the Mac". **Wins:** 30 as the target (K5, not built); AA7 describes today
and lacks a pointer.

**7.12 A wrong citation.** 41 §4.2, L79 cites "(26 CL9)" for `@agent`; the bridge is CL8 (26 L44).

---

## 8. Automations (27) and listeners (36)

**8.1 06 still defines the agent's schedules.** *Stale.*
06 §4, L90: "`schedule(when, prompt, deliverTo?)` / `list_schedules` / `cancel_schedule`"; the §2 schema keeps
`schedules`, `heartbeat`, `triggers`; AD4, L65: `agents.create` takes `schedule`.
27 §5, L179: "These replace the agent's `schedule`, `watch`, `list_schedules` and `cancel_schedule`"; §6, L215:
"**Agent definitions** lose `schedules`, `heartbeat` and `triggers`."
**Wins:** 27 on the Mac (built). 06 holds for the cloud only (27 L261: "the cloud keeps `schedule` and `watch` for
now"), and should say so.

**8.2 `offer_repeat` and routine tools.** *Stale.* 21 §13, L280; 24 §11, L388; 26 §11, L286 ("it offers a routine
instead, as before"). 27 §10, L260: "`offer_repeat` are gone." **Wins:** 27.

**8.3 Routines with two owners.** *Stale.* 21 L6 and README L104 say AD5 stays; 27 L5–6 changes "21 AD5 and 26 CL10".
**Wins:** 27 once confirmed (1.1).

**8.4 Does an automation have a model?** *Contradiction.*
28 §4, L103: "Lead, unless the automation pins a model"; 34 §5.5, L111: "Morning briefing spent $4.10 on Opus 5.5 …
· Change model".
27 §3, L73–89: the `Automation` record has no model field.
**Your call.**

**8.5 Branches.** *Draft against built.* 27 §8, L234: "**No workflow builder.** There are no chains …, no branches".
36 §4.2, L167: a step condition "keeps branching out of prompts". 27 stands; 36's table of changes to 27 omits §8.

**8.6 36: "no file system", yet code steps write files.** *Contradiction inside 36.* §2, L38 against §4.4, L185.
Draft; needs to say by what call a step reads and writes `prices.csv`.

**8.7 A migrated heartbeat's budget.** *(less sure)* 27 §6, L209: PR2's skip "becomes its budget per run". 27 §11,
L336: "Migrated automations get no budget per run". **Wins:** §11 (the trial).

**8.8 27's examples use Slack** (L70 "tell me on Slack") while §8, L237 says "No Slack yet".

---

## 9. Budgets and limits

**9.1 "One new budget" that 07 already had.** *Stale.* 07 CO3, L47: "Optional global monthly budget with alerts."
34 §5.4, L104: "one new budget: **Piopio this month**". **Wins:** 34 OV3 (built); 07 needs the note.

**9.2 "Every budget Piopio has" is not every budget.** 34 §5.4, L102 lists three. Missing: the trace budget (06
AA4, $0.50), `/goal`'s $5.00 (32), 41's per-client monthly budget, which 41 §5, L137 cites as "(34)". **Wins:** 34's
list as built; 41 should say it adds a kind.

**9.3 Step budgets.** *(less sure)* 22 §3, L71: "default 40 browser actions". 23 §3, L66: "default 50 actions, a
setting), as in the browser." **Your call** whether they should match.

**9.4 "One set of limits."** 26 §7.1, L145 claims one "running at once" limit; the numbers are 3 subagents (05,
17, 37), 4 side conversations (24) and 3 board tasks (26). Each is consistent where stated; the sentence is loose.

---

## 10. Models, providers and cost

**10.1 The on-device model: first choice or last resort.** *Stale.*
README AQ7, L94: "(Apple Foundation Models) first, OpenRouter fallback." 14 §3.2, L92–93: the slot "already prefers
Apple's on-device model … with an 8k-token window". 17 L161: "(on-device first, AQ7)".
07 §1.3, L38–40 (2026-11-07): "about 4k tokens … it's an option and a last resort, not the default."
**Wins:** 07 §1.3. 03 L86 also routes it through the app (`app.utility`) where 07 says the engine starts
`piopio-fm` directly.

**10.2 "OpenRouter only" still stated as current.** *Stale.* 07 §1.1, L8: "**v1: OpenRouter only**"; 07 §8 welcome;
MO1, L13: `/models` "cached 24 h". 10 §11 (P0 built 2026-10-22); 10 §13, L213: "cached six hours". **Wins:** 10.

**10.3 Default-model slots.** *Stale / term.* 07 §1.3, L18–24: Build, Chat, Organizer, Agents, Utility. 10 §8: Build,
Chats and notebooks, Quick Chat, New agents. "Default model" then means a per-mode setting (07, 10 §8), one setting
(10 FR3, 28) and the engine's fallback (29 §1). **Wins:** 10 §8 for what is built.

**10.4 Decided specs assume the drafts 28 and 29.** *Stale / premature.*
34 L14: "several providers in an order (29)"; §5.3: "each model with its route (29)"; §6.1: "the roles (28)"; the
ledger's `route` and `role` columns. 31 §8 cites 29. 36 L133: "the Quick role (28)".
28 L3–4 and 29 L3: drafts, "nothing here is built"; under 28 AM0 roles do nothing until Auto is on.
**Wins:** the drafts have changed nothing yet. 34 §13 admits the columns stay empty; its §1, §5.3 and §6.1 don't.

**10.5 28 and 29 disagree with each other.** *Contradictions between two drafts of the same day.* **Your call** on
each before either is confirmed.

| Subject | 28 | 29 |
|---|---|---|
| Is a role a model, or a model on one provider? | AM9, L86: "no provider you didn't put in a role, no silent fallback … (10 FR4 holds)" | §11, L238–241: a role's model "follows your order like any pick"; claims "28's AM9 holds" |
| Background work's fallback | L6: "Background work … stays as it is." | PO2, L76: the order sets "which provider background work falls back to" |
| A session's model | §7, L159: "`ModelRef \| { auto: true }`" | §7, L164: "stays a `ModelRef`" plus `routing` |
| "Pinned" | AM1, L78: on a named model | PO7, L81: fixed to one route |

**10.6 28 against itself: who reviews.** AM2, L79: "**Reviews use Lead**" (and §10, answered by you). AM3, L80: "a
review is Deep". **Wins:** Lead. Also 28 §4, L100 says today's review model is "`reviewModel`, else `buildModel`";
26 §4, L77 says each "defaults to the project's model". **Wins:** 26.

**10.7 29 against itself.** L5–6: "Everything else in 10 holds", yet PO3 (L77) overturns 10 FR2 (L68: "stays two
distinct choices"). §10 Q4, L230 (decided): under 2 minutes an attended conversation waits; §5, L93 moves on after a
`retry-after` over 60 s. **Wins:** Q4; §5 and PO4 weren't updated.

**10.8 10's pointers to 29 read as if 29 were decided,** and two places have none. 10 §3, L50: "(revised by
[29]…)"; yet 10 §7, L114 and §10, L172: "Never fall back to another paid provider." The places 28 says it would
change (07 §1.3, 24 §4 `side_start`'s `model`, 26 §4) carry no pointer.

**10.9 31 CA5 is true for one agent.** CA5, L66–67: titles are "asked from that agent … so a Mac with only Claude
Code works." §9, L250: "CA5 holds for Claude Code only". **Wins:** §9.

---

## 11. Memory and turn context

**11.1 Where recalled memory goes.** *Stale.* 14 §1, L30: "`recall` puts up to 1,200 tokens in the system section."
06 ME2, L219 likewise. 38 R3 as built, L220: "`AgentCore` writes what a message recalls as an entry of its own".
**Wins:** 38 R3 (built, though 38's status says draft).

**11.2 Memory's default.** *Contradiction inside 14.* §5.1, L114: "**Standard** (new default when an embedding model
is set)". §7, L204: "**Off by default** (`memory.semantic`, revised Q4)". Setting names differ too (§5.4 against §7).
**Wins:** §7 and the status line.

**11.3 42 leans on 38's fallback.** *(less sure)* 42 VO5, L147: a note "in its turn context (38)". 38 L5–6: §2–§6
"are the fallback"; the built path is a hidden message beside the user's. 42 should name the built mechanism.

---

## 12. The cloud, the server and channels

**12.1 How an agent reaches the cloud.** *Stale.*
06 L3: "Authored on the Mac, running 24/7 on the user's Cloudflare account."; 06 §11: a local "dev" agent, "Deploy
changes" with a diff, rollback, "Pull state"; 13 5.2, L84: "Deploy to cloud"; README A4–A9.
30 CT1, L260: "**New agents start on this Mac**"; §13: Keep it always on, Move to This Mac.
**Wins:** 30 (decided, K1 built). Three names for one act (Deploy to cloud, Move to cloud, Keep it always on).

**12.2 Channels: v1, or add-ons.** *Stale.* 06 §5 heading, L144; README A3; 13 L7 (acceptance: "Telegram and WhatsApp
both work"). 30 L13: "**add-ons**"; §10: "any time after K1". **Wins:** 30. 13 has no pointer to 30 or 33 anywhere.

**12.3 Telegram on the Mac.** *Contradiction inside 19; stale in 06.* 19 §5, L183: "Telegram through a tunnel". 06
§5.2, L162: "Piopio calls `setWebhook`". 19 S4, L40: "by polling Telegram (no webhook, tunnel …". **Wins:** polling
(built 2026-11-10; 30 and 33 repeat it).

**12.4 Mac Bridge tools when the Mac is off.** *Contradiction.* 06 §10, L241: "Cloud agents see these tools only
while the bridge is connected." 30 §5, L158: "those tools stay listed with `needs your Mac`." **Wins:** 30.
**Your call:** `mac_shell` and `mac_imessage_send` are in 06's list and absent from 30's.

**12.5 Build for cloud work.** *Stale.* 19 TD3, L230: "**Builders wait for the Mac**". 30 §3.1, L49: "A cloud
machine (container) with the project's GitHub repo cloned"; 33 adds a server's disk. **Wins:** 30 CT3 and 33 PS8.

**12.6 30 against itself.** **Wins:** §13 (as built) in each row.

| Subject | Target sections | §13 |
|---|---|---|
| Where Keep it always on lives | §3.2, L66; §3.3; CT1: the info panel | L302: the agent's header |
| Disconnecting | §9, L233: offers "Bring everything back to this Mac" | L299: "is refused while an agent runs there" (33 §4.1 cites §9's version) |
| Cloud models | §4, L87: "API-key providers (OpenRouter, Anthropic, OpenAI…)" | L311: anything "other than OpenRouter" becomes the Worker's default |
| The cloud ref | §8, L206: "`location: "cloud"` on the ref" | L334: the catalog entry "has `cloud`" (05 §10, L197 has a third: "`location: remote`") |

No phase says when other API-key providers reach the Worker.

**12.7 GitHub in the cloud.** *Contradiction.* *(less sure)* 30 §4.1, L102–104: each remote server "gets its **own**
sign-in" on the Worker, GitHub among them. 12 C3, L131 (built two days later): "GitHub registers no clients on the
spot, so it uses Piopio's GitHub sign-in". **Your call:** CT2 ("nothing is copied from the Mac's Keychain") can't
hold for GitHub as written; it matters for K7.

**12.8 The cloud browser.** *Stale.* 22 §10, L243: "no hand-offs to a pane; a hand-off becomes a link you open."
30 §4.2, L118: you take over in "**Live View**", with a profile per agent. **Wins:** 30.

**12.9 Mac apps.** *(less sure)* 30 §4, L93: "Calendar, Reminders, Mail, Notes, Shortcuts". 06 NB5 and AQ5: Reminders,
Calendar, Contacts, Notes, Music, Shortcuts. No Mail tool exists in any spec. **Wins:** 06.

**12.10 Smaller.** Phone pairing: 02 §7, L146 "with the owner token" against 30 §6, L181 "the owner token never
leaves the Mac" (**30**). Cloudflare token scopes: three lists in 02 L112, 13 L124 and 30 §13, L294 (**30**).
Cloud alarms: 06 PR6, L190 "`PiHarness` alarm projection" against 13 L17 "No alarm hook in pi-durable 1.3" (**13**,
*less sure*). 30 and 19 cite "13 §5.2", "13 §5.4"; 13 has no §5, those are milestones 5.1–5.5. Protocol version: 03
§1, L14 "Minor versions only add fields" against 33 §6.3, L133 "must match" (**your call**, *less sure*).

**12.11 Voice notes.** *Stale.* 06 CH3, L158: voice is "stored in R2 … transcribed (OpenRouter audio-capable model
or a configured STT)". 42 §6, L98: "transcribed on the Mac"; §8, L128: "**Audio isn't kept.**" **Wins:** 42.

---

## 13. Protocol and storage

**13.1 03's methods.** *Stale.* 03 still lists `cloud.upgrade`, `cloud.rotateToken`, `cloud.teardown` (L78),
`agents.deploy`/`undeploy` (L75), `approvals.respond` (L63), `projects.setLens` (L42), `spaces.*` (L72) and
`catalog.list` (L36). Later specs use `cloud.update` (30 L299), `agents.retire`/`export`, `sessions.decide` (12 L47).
**Wins:** the later specs; none of 03's names above is in `packages/protocol/src/index.ts`. Only 03 §6 was redone.

**13.2 41 maps its tools onto methods that don't exist.** 41 §4.1, L64: "`catalog.list({kinds:["project"]})`"; L69:
"`agents.list`". **Wins:** neither; redo 41's "Maps to" column against the built protocol.

**13.3 `app.tool`.** *Stale.* 03 §3.12, L85: "`app.tool({name, args, agentId})` → `{result, card?, undo?}`". 22 §8,
L205: it "takes **who is asking as a `ref`**", answers `images`, and groups are declared in `engine.hello`.
**Wins:** 22 (built).

**13.4 Storage.** *Stale.* 02 §4.3, L82 and §6: `catalog.db` holds projects, spaces and the "cost ledger"; 07 CO1,
L45 and 05 AP2, L111 say the same. 34 §13, L265: the ledger "is `usage.db`"; 39 L32: `projects.json`; 19 L298:
`teams.json`. **Wins:** the later built specs.

---

## 14. Connectors

**14.1 What a connector is.** *Contradiction inside 12.* §4, L161: "a small folder that Piopio reads". L124: "Each is
one file in `connectors/`". **Wins:** the C3 text (built).

**14.2 Tool names in examples.** 35 §3.1, L61 "`calendar_list_events`" and 35/36 "`gmail_search`" don't exist; 12 L44
has `calendar_events` and `mail_search`. Gmail is C2, not built. **Wins:** 12.

---

## 15. Visuals, apps and the Library

**15.1 35's design sections describe the flow §14–§17 replaced.** *Stale inside 35.* **Wins:** the later section
(decided after review and built 2026-11-22/23) in each row.

| Subject | §2–§6 | §14–§16 |
|---|---|---|
| The button | §3.6, L135: "**Keep from any visual card**"; AL6, L309 | §14, L469: "**Make app** (it replaces Keep; AL6)" |
| Timed refresh | §3.3, L100: "only while the app is pinned"; §4.4, L203; AL10 | §14, L501: "**Pinning is only for finding it.**"; §16, L652: "kept apart from Pin" |
| The side panel | §3.6, L132: "300 pt wide" | §15, L566: "360 pt panel" |
| Protocol | §6: `app.open` | §15, L528: "`apps.*` rather than `app.*`" |
| A connector source | §3.2: a generic `tool` source | §16, L620: calendar sources "are their own kind" |

**15.2 25 says nothing crosses into a visual.** *Stale.* 25 §4.4, L176: "Nothing else crosses: no reading the
conversation, no files, no tools."; §10, L260: editing in place is later. 35 §14, L539: "**`piopio.onData`** is in
every visual's bridge." **Wins:** 35 (built). 25 has no pointer to 35.

**15.3 A link in a visual.** *Contradiction inside 25.* §5.1, L190: links "open in the built-in browser". §13, L298:
"opens in your default browser". **Wins:** as built. The check's timing differs the same way (§3.2 "at most 3 s"
against §15, L367 "(at most 5 s)" then 3 s more).

**15.4 The script runner.** *Contradiction between two drafts.*
35 §3.1–3.2, L62, L93: the tool list is in the manifest; "10 s per read", 2 MB, 20 tool calls.
36 §2, L43, L52: "`// @tools gmail_search`" in the script's header; "5 s for a filter, 60 s for a code step"; §8,
L247: 35's script source runs "with the same header and limits".
**Your call:** where the tool list lives (it matters for 35 §3.4's re-allow rule) and which timeout an app source gets.

---

## 16. Skills, Show me how and voice

**16.1 Where skills live.** *Stale.* 07 §2, L50–51: "`~/Library/Application Support/Piopio/skills/`" and "Settings ›
Skills". 09 D9, L188: read from `~/.pi/agent/skills` "with no UI to make or manage them"; 26 §11 and 40 use pi's
folders. **Wins:** 09 as what is built. 05 BR5, L91 still writes `/skill:name`; 32 §4.1 lists skills by name.

**16.2 A Python script in a skill.** *Contradiction between two drafts.* 40 §6, L117: "script `add_rows.py`", run
"under Build's sandbox or 36's script runner". 36 §2, L36: "one JavaScript module". And chats have no command tools.
**Your call.**

**16.3 Narration and cloud hearing.** *Latent.* 40 §2, L33: "Your voice is transcribed on the Mac"; §8, L151:
"Nothing is sent while recording." 42 VO9, L151: "**One transcription helper for everything:** … Show me how", and
§7 allows a cloud transcriber. **Your call:** whether Show me how is exempt from an opted-in cloud transcriber.

**16.4 Esc.** *Contradiction inside 42, and across specs.* 42 §4, L72: Esc is Deny on the talk pill; L73: "Esc while
the pill is focused" ends talk mode. Elsewhere Esc aborts a turn (08 §4, L24), stops dictation (42 §3, L46) and
removes a command chip (32 §4.2, L83). No precedence is stated. **Your call.**

---

## 17. Commands and shortcuts

**17.1 `/plan`, `/fork`, `/worktree`.** *Stale.* 05 §4, L40: "`/plan` is always available on demand"; BR5, L91 lists
"`/fork`, `/worktree`". 32 §7, L139: "**Plan is a mode only** …: no /plan command and no chip." **Wins:** 32. Inside
32, §4.1 L62 and §4.2 L88 ("plan's toggle") still list plan. 32 never lists /fork or /worktree and never says they
went *(less sure)*.

**17.2 Where "Check after edits" lives.** *Contradiction.* 05 DG2, L61 (2026-11-21): "On the project page, **Check
after edits**". 18 CF21, L560: "**No project page.**" **Your call:** probably the project's settings sheet; then 18
CF22 needs the row.

**17.3 Shortcuts.** One key, two jobs: ⌘O (3.11) and Esc (16.4). Bound in 08 to things that no longer exist: ⌘1–3
(mode switcher), ⌘⇧A (approvals inbox). 08's ⌘⌥I for the inspector differs from the app (⌘I). ⌘⇧N moved from New
Notebook (15) to New Project (18). No live action has two shortcuts.

---

## 18. Terms with two meanings

**18.1 Inbox, Needs you, Waiting on you.** README AQ9, L96: "called **Inbox**". 21 §8, L127–128 (built): "the Needs
you row is gone, and so is its page (2026-11-18): Home's "Waiting on you" lists everything". Written after that
date and still saying "Needs you" as a place: 34 OV3 (L105, L247), 41 (L83, L202), 30 (L107, L197), 22 §16 (L407,
L422), 31 CA4, 23. 27 uses all three (L53, L130, L291).
**Wins:** "Waiting on you" on Home. **Your call:** whether "Needs you" stays as the label on a card (24 L143) or goes
everywhere.

**18.2 routine.** Retired by 27 AU12 (L57). Still used: 22 §16, L413 (written 2026-11-23: "so routines browse"), 22
W3's row, 23 L184, 06 UI8 L275, 26 §5 L96, README's CL row. **Wins:** "automation".

**18.3 Full access / Full auto / Full.** See 5.2. Also "Ask before edits" in 31 CA4, L63 for "Ask". And "Read
only" is a conversation's mode (18), a linked folder's access (18 CF18) and a client's grant level (41 §5, L129).

**18.4 cloud.** 01 §4, L30: "**Cloud Engine** = Cloudflare Worker + Durable Objects." 33 §2, L33: a server is "a
place like the Worker: the location chip still says `Cloud`." 41 §6.2, L185: "On a Piopio Server or in the cloud"
(the Worker only). 42 uses "cloud voices" for third-party speech providers. **Wins:** 33: Cloud is the place,
Worker or Server.

**18.5 app.** A service you connect (12 L7), a Mac application (23, 40), a kept visual (35 L9), MCP Apps, and Piopio
itself. 35's name is AL6, proposed, yet built under it. **Your call.**

**18.6 Library.** One agent's outputs (06 UI9, L276), everything Piopio makes (35 §4.1), your skills (README X6; 26
CL6 "in your library"). **Wins:** 35 (L1 built). **Your call:** whether UI9 is absorbed as the Library's agent filter.

**18.7 background work.** 07 §1.3: titles, summaries, commit messages (a Settings label). 34 OV3, L247: "background
work (automations, agents' own runs)". 34 itself calls the first "Piopio's own work" and the ledger calls it
`utility`. **Your call:** 34's sense needs another word.

**18.8 helper / subagent.** 26 §7.1: a helper is the board's, a subagent is `task`'s. 31 L20 and CA10, L81: "the
`task` helper". 19 T2 has the older hired helper. **Wins:** 26's split.

**18.9 Lead, Build, Quick, role.** 20 PT4 and 26 CL3: the lead of a project's work. 28 AM2, L79: "*Lead* talks with
you and orchestrates" (a model role; Build and Quick also name an area and Quick Chat). 28 is a draft. **Your call.**

**18.10 hook.** The inbound webhook endpoint (36 LS5, L281; 27) and a script at a point in an agent's loop (36 §13,
L322; 09 PAR6). **Wins:** "hook" for the loop; "webhook" for the URL.

**18.11 Smaller overloads,** each worth one word changed in the later draft: *step* (tool calls in a turn, 06 UI2
and 22; a part of an automation's run, 36; a recorded action, 40); *route* (29's provider route; 40 L125's way of
doing a step; 33's HTTP routes); *place* (30: where it runs; 35 L181: where a file lives); *plan* (Plan mode's
proposal, 05; "the plan block" of board tasks, 21 AD9; a subscription, 29 and 31); *check* (26 §4 "Checks": the test
command; 36 LS12: a filter on a time trigger); *pinned* (10.5; also memory records in 38 TC4); *standing* (07 §5.1:
Hindsight's pre-computed answers; 38 TC4: pinned records); *provider* (model, memory, web search, and in 38 §4 a
function).

---

## 19. IDs that collide

09 L118 already says "**IDs collide.**" for D1–D7 and proposes BL-n for the backlog; it hasn't been done. The
specs that qualify references ("26 CL11", "31's A5") are 26, 27, 29, 33, 36, 40 and 41. Bare codes pile up in
README and 09.

| Code | Meanings | Where a bare use is ambiguous |
|---|---|---|
| W1–W4 | 22's phases (built); 36's phases; 17's Watchdog rules W1–W6 | README L29 and L43; 09 L54–64 |
| A1–A5 | README decisions A1–A10; 27's phases; 31's phases | 09 L21 "trial A3" (27's) and L89 "A1–A3" (31's) |
| D1–D7 | README D1–D5; 09's backlog D1–D13; 21's phases | 09 L21–23; README L32 "MCP Apps (D6)"; 35 L278 "(25 D6)" is the backlog's |
| C1–C6 | README C2–C7; 12's milestones (C6 used, C4–C5 never defined); 26's phases | 09 L36 "and C4"; 18 L3 "(C2)" |
| AD1–AD5 | 06's authoring rules; 21's decisions | 19 "(AD5)" means 06's; README "AD4 and AD5 stay" means 21's |
| T0–T7 | 04 T1–T14; 19's rules T1–T7 and phases T0–T5; 38's phases T0–T4 | 24 L19 "(T5 …)", 25 "(T4)", 41 "(T4)"; 09 L59 |
| TC1– | 19's coordination rules; 38's decisions | |
| S, P, Q, M, B, R, EX | 04/09/19 (S); 04/09/10/20 (P); 04/09/14 (Q); README/14 (M); README/09 (B); 19/38 and Cloudflare's R2 (R); 07/08 (EX) | 14 L3 "Q1 and Q3"; 09 L26 "M4" |
| OV1–OV4, PS1–PS3, SH1–SH4 | inside one spec, both a phase and a decision (34 L222 against L245; 33 L193 against L207; 40 L67 against L175) | README L41 uses both senses of OV in one row |

41 (PM decisions, MS phases) and 42 (VO, VC) show the pattern that avoids the last row. Since 22's W1–W4 are
built and cited from 09, 23 and 40, 36 is the one to rename.

---

## 20. Decisions only you can make

1. Confirm AU1–AU12, so 27 stops being a draft that is built (1.1).
2. Whether a role is a model or a model on one provider, and the other three 28/29 differences (10.5).
3. Whether an automation carries its own model (8.4).
4. One name for the place things wait for you (18.1), and for unattended runs against Piopio's own small jobs (18.7).
5. Whether "App" stays for kept visuals (18.5) and 06's per-agent Library is absorbed (18.6).
6. Channel approvals: always, or only when asked for (5.9). Approval expiry for away runs (5.8).
7. Whether board helpers are capped by the conversation's mode (5.7); whether subagents are still read-only (6.3).
8. The script runner's tool list and timeouts, and whether it runs anything but JavaScript (15.4, 16.2).
9. GitHub's sign-in in the cloud (12.7); `mac_shell` and `mac_imessage_send` on the Mac Bridge (12.4).
10. Which area gates New Project (3.10); where Check after edits lives (17.2); what Esc does first (16.4).
11. Whether a Builder still exists, and whether `ask_user` and `ask_owner` are one tool (7.8, 7.9).
12. Show me how under an opted-in cloud transcriber (16.3).
13. A prefix rule for IDs (§19).

## Checked and found consistent

So these need no second look: worktree location (02, 05, README BQ2); 3 subagents, 4 side conversations, 3 board
tasks, a review sent back at most 3 times, the loop guard of 5 woken turns; `ask_agent`'s guards (hop over 4, 30 an
hour, $0.50) across 06, 13 and 19; `tell_agent` for notices only across 06, 26, 27 and 36; per-run budget defaults
($0.25, $0.50) and the 24 h Undo window; the agent's monthly budget (80% notify, 100% stop) across 06, 27 and 34;
voice never approves (42, 22, 41); an outside client capped at Ask with approvals staying in Piopio (41, 31, 39);
connectors' reads run and changes ask (12, 18, 30, 41); who drives a browser and the never list (22, 23, 40); no
Piopio-hosted backend, no telemetry, local by default (30, 33, 34, 41); secrets in the Keychain with the cloud's and
server's own stores; Telegram bot per agent and one WhatsApp number; ⌘K, ⌥Space, ⌥⌘N, ⇧⌘N, ⌘M; Dispatch's router
dropped consistently in 17, 19, 24, 26 and README; Hindsight opt-in and the built-in provider as default; coding
agents' cost as tokens, not spending (31, 05, 34); the notes that do exist in 04 (§2–§3), 06 (§6, §7, §12.1), 15
(the Chat switch), 17 (top), 18 (§11, §16), 19, 20 and 21 (headers) say what the later spec says.
