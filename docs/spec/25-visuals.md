# 25 — Visuals in the conversation

Status: draft 2026-11-16; decisions VS1–VS9 to confirm; V1 (HTML files) and V2 (visuals) built 2026-11-16 (§13, §14); V3's check and V4 not built. References: T3 Code drawing four UI
proposals inline when asked to "show me here inline a few ideas to pick"
([the post](https://x.com/itssotsot/status/2122282435971092760)), Codex rendering a prototype in the chat, and Claude's
inline charts and diagrams.

## 0. Where this comes from

Some answers are better seen than read: a chart of numbers, a diagram of how something works, three versions of a
screen to pick from. Today Piopio can only show text, code, tables and files. When the model makes HTML it lands in a
code block, or in a file you open somewhere else. Piopio's own design work shows the cost: every
`docs/design/*/proposals.html` with its lettered proposals had to be written as a file, opened in a browser and
described back in the chat.

The roadmap already has three items that turn out to be one feature:

| Item | What it asks for | What it needs |
|---|---|---|
| Later · artifacts/canvas (04-chat §1.3) | HTML and Markdown documents the model writes and edits | A place to render HTML, and somewhere to keep it |
| D6 · MCP Apps | MCP servers that return interactive UI, rendered in the transcript | A sandboxed HTML card in the transcript, with a channel back |
| F1 · Concept → 3D | Say a concept, see it in 3D | HTML with a 3D library, in the transcript |

What's missing is one thing: **a sandboxed web view the model can put in the conversation.** This spec adds it and
reuses it for all three.

## 1. The experience

1. **You ask to see it.** "Show me three ways to lay out the usage card." "Chart my spending by month." "How does a
   CRDT merge two edits? Draw it."
2. **It appears in the answer.** Between the answer's paragraphs there's a card with a title ("Usage card: three
   options") and, under it, the visual itself, at the column's width, in Piopio's colours, light or dark with the app.
   While the model is still writing it, the card says **Drawing…**.
3. **You can use it.** Hover shows a tooltip, a slider moves, a tab switches. Some visuals talk back: under option B
   there's **Go with B**, and clicking it sends "Go with B" as your next message.
4. **Bigger when you want.** **Open** on the card shows the visual in the right column (where the browser and file
   previews go), at the column's full height. **Save…** writes it as an `.html` file: in a project, into the project
   folder by default.
5. **It stays.** Scroll back tomorrow and it's still there, drawn again from what the model sent. A new version ("make
   B denser") is a new card under the new answer; the old one stays where it was.
6. **Files too.** An `.html` file the model writes in Build, or that you attach, opens rendered in the file viewer,
   with **Rendered | Source** like Markdown.

## 2. Decisions (to confirm)

| # | Decision | Alternative considered |
|---|---|---|
| VS1 | **One primitive: a sandboxed web view card.** Visuals, MCP Apps (D6) and F1 all use it. | A renderer per kind (charts, Mermaid, 3D): each smaller, but three things to build and keep, and every new kind waits for a new renderer. |
| VS2 | **The model shows a visual with a tool**, `show_visual` (§3). Code blocks stay code, even ` ```html `. | Render ` ```html ` blocks: no new tool, but every HTML snippet you asked to *read* becomes a page, half-written HTML streams in as code first, and there's no title. |
| VS3 | **Saved visuals are files.** No artifact store of its own: Save… writes an `.html` file, and from then on it's a file like any other (viewer, checkpoints, git). | An artifacts panel with its own versions (Claude, ChatGPT canvas): more to build, and since a project is always a folder (CF4), files already do it. |
| VS4 | **The engine records, the app draws.** The visual is in the transcript as the tool call's arguments, so any client can draw it again and the engine needs no web view. When the app is connected it also checks the visual (§3.2). | The engine renders (a headless browser): heavier, and the result is a picture, not something you can use. |
| VS5 | **No network.** A visual can't load anything from the internet or from your disk. A few libraries ship inside Piopio (§5.2). | A CDN allowlist (what Claude does): any library, but every visual reaches the network, and a model that read a hostile page could load from it (§5.3). |
| VS6 | **It looks like Piopio.** The app's design tokens and a base stylesheet go into every visual (§4.2); the prompt asks the model to use them. | Leave styling to the model: every visual a different look. |
| VS7 | **A visual talks back only on your click**, as your message, marked as coming from the visual (§4.4). | Let a visual send whenever it likes: needed by nothing here, and a page that sends on load would write in your name. |
| VS8 | **Live only while on screen.** A visual scrolled away becomes a picture of itself; it comes back to life when it's in view again (§6). | Every visual live all the time: a long design conversation would hold dozens of web views. |
| VS9 | **Everywhere a conversation is shown**: chats, project conversations, Build sessions, agents' in-app chats. It changes nothing, so it runs in every permission mode, Read only too. | Chats only. |

## 3. What the model gets

### 3.1 The tool

```
show_visual({ title, html, look? })
```

| Argument | Meaning |
|---|---|
| `title` | Shown on the card, 2–6 words: "Usage card: three options". |
| `html` | A fragment (no `<html>`, `<head>` or `<body>`: Piopio wraps it, §4.2) or a whole document. At most 300 KB. |
| `look` | Optional. When true, and the model sees images, the result includes a picture of the visual as drawn (§3.2). Default false. |

The result is short: `Shown as "Usage card: three options" (620 pt tall).`, plus any script errors (§3.2). The HTML is
not repeated back to the model.

Where it's offered: every runtime that has a transcript the app draws (chat, Build, agents). It's a read in the tool
profiles (like `todo` and `propose_plan`), so no mode asks for it.

### 3.2 The check

When an app that says `visuals` in `engine.hello` is connected, `show_visual` goes to it as `app.tool` (with the
conversation's `ref`, `groups: ["visuals"]`), the way the browser's tools do (22 §14). The app draws the visual off
screen at the conversation's column width, waits for it to settle (load, then 500 ms without layout changes, at most
3 s) and answers:

- the height it drew at;
- **script errors and failed loads** (a library it doesn't have, a blocked request), so the model can fix them in the
  same turn instead of you finding a blank card;
- with `look: true`, a JPEG of the visual, at most 1280 px wide.

With no app connected (a cloud agent, Telegram), the engine records the visual and answers `Recorded; not drawn, so
not checked.` The card is drawn when an app opens the conversation.

### 3.3 What the prompt says

A short section, in every profile that has the tool:

- **When:** numbers that compare or change over time; how something works (parts and the flow between them); UI or
  layout options to choose from; a small interactive explainer. Not for what a sentence, a list or a table says as
  well; not for long documents (write a file); not for code you'll copy (a code block).
- **How:** use the CSS variables (§4.2) for colours, type and spacing; no fixed widths (the column is 560–900 pt); a
  transparent page background; one visual per idea; options labelled A, B, C, each with a button that calls
  `piopio.send("Go with B")`.
- **Libraries:** the bundled ones (§5.2), by their `piopio-lib:` URL. Nothing from the internet: it won't load.
- **Check:** read the errors in the result; use `look: true` when the layout matters and you can see images.

## 4. The card

### 4.1 In the transcript

An attachment card, like the table and file cards (`NSTextAttachmentViewProvider`):

- **Header:** an icon, the title, and on hover **Open**, **Save…**, **Copy HTML**, **Reload**.
- **Body:** the visual at the column's width. Its height follows the content: a `ResizeObserver` in the wrapper reports
  it, and the card resizes. At most 900 pt; past that the card shows the top and a **Show all** that opens it in the
  right column. No scrolling inside the card (a scroll area in a scrolling transcript catches the wheel).
- **While the call streams:** the header and a placeholder saying **Drawing…**. The visual is drawn once the
  arguments are complete; half a page of HTML isn't shown.
- **If it fails** (the HTML can't be drawn, or the content process dies): the card says so, with **Reload** and
  **Show source**.

### 4.2 The wrapper

Piopio puts every visual inside its own page:

- a strict Content Security Policy (§5.1);
- the design tokens as CSS variables, light and dark, from `DesignTokens.swift`: `--bg`, `--fg`, `--fg2`, `--fg3`,
  `--line`, `--accent`, `--accent-soft`, `--card`, `--radius`, `--radius-card`, `--font`, `--font-mono`, and a
  categorical palette `--c1`…`--c8` for charts;
- a small base stylesheet: the system font at 13 pt, margins at 0, buttons, inputs and tables styled like the app's;
- the `piopio` object (§4.4) and the height reporter.

The app's appearance changes are passed in (a class on `<html>`), so a visual switches with the app without
redrawing.

### 4.3 In the right column

**Open** shows the visual in the right column, in a **Visual** view next to Browser and Files, at the column's width
and full height, with the same buttons. It's the same visual, live; the card in the transcript shows a picture of it
while it's open there.

### 4.4 Talking back

The wrapper defines:

| Call | Does |
|---|---|
| `piopio.send(text)` | Sends `text` as your next message. Only during a click or key press (the page's user activation); otherwise it does nothing and logs an error the check reports. The message shows with a small "from *title*" tag. While a turn runs, it queues like a message you typed (T4). |
| `piopio.prefill(text)` | Puts `text` in the composer without sending, for you to finish. Same rule. |

Nothing else crosses: no reading the conversation, no files, no tools. A visual that needs data gets it in its HTML.

## 5. Safety

### 5.1 The sandbox

Each visual is a `WKWebView` with:

- a non-persistent data store (no cookies, storage or cache kept, nothing shared with the browser's profile);
- the HTML loaded with `loadHTMLString` and a base URL on a custom scheme, so it's its own origin with no access to
  files;
- CSP `default-src 'none'; script-src 'unsafe-inline' piopio-lib:; style-src 'unsafe-inline' piopio-lib:; img-src data:
  blob: piopio-lib:; font-src data: piopio-lib:; connect-src 'none'; frame-src 'none'; form-action 'none'`, set by the
  wrapper and backed by a content rule list that blocks every other load;
- navigation refused (link clicks open in the built-in browser only when you click them, and only http(s));
  pop-ups, downloads, camera, microphone, location and notifications refused; `alert`/`confirm`/`prompt` ignored.

### 5.2 Bundled libraries

Served from inside the app by a `piopio-lib:` scheme handler, pinned versions, about 1.5 MB in all:

| Library | For |
|---|---|
| Chart.js | Charts |
| d3 | Charts and diagrams it can't do |
| three.js | 3D (F1) |
| KaTeX | Maths in a visual (the transcript already has LaTeX, T2) |

Adding one is a code change, not a setting. Mermaid isn't bundled: diagrams are SVG the model writes (the prompt says
how), which reads better and needs nothing.

### 5.3 Why no network

A visual is model output, and the model may have read a page that tells it what to write. With the network open, such
a visual could send whatever the conversation contains to anywhere, or show a convincing sign-in form. With no network
and no channel back but your click, the worst a visual can do is look wrong. It also keeps Piopio local by default:
showing a chart reaches nothing.

## 6. Performance

- All visuals share one web content process pool.
- At most 4 visuals are live in a transcript, the ones in view; a visual that leaves the view is replaced by a snapshot
  (`takeSnapshot`) at its last size and its web view is released. Scrolling back brings it to life again; its state
  (a slider's position) isn't kept.
- A visual's first draw happens once, during the check (§3.2) or when it's first in view; its snapshot is kept in memory
  for the session, so scrolling a long design conversation doesn't redraw everything.

## 7. HTML files

The file viewer (roadmap D8, `FileView.swift`) gets an `html` kind:

- **Rendered | Source**, Rendered by default.
- Rendered in a web view that can read the file's own folder (so a prototype's local CSS, scripts and images work) and
  nothing above it; the network is blocked the same way (§5.1); `piopio-lib:` works too.
- **Open in browser** opens it in the built-in browser (22), with the network, for a prototype that needs it.
- File cards for `.html` files in the transcript open it rendered.

This is the place for prototypes made of several files, and for anything you saved from a card.

## 8. Elsewhere

- **Export (T11).** HTML export puts each visual in a sandboxed `<iframe srcdoc>` with the same CSP and the libraries
  inlined; Markdown export puts its snapshot as an image, with the title as alt text; JSONL keeps the tool call as it is.
  Copy as Markdown gives the title in brackets.
- **Agents on Telegram and WhatsApp.** When the agent's answer has a visual and the app is open, the snapshot goes out
  as an image with the title as caption. With the app closed, the title goes out with "open Piopio to see it".
- **MCP Apps (D6).** A tool result carrying UI (`ui://` resources) is drawn in the same card and wrapper. Its channel
  back is the MCP Apps one (tool calls through the host), not `piopio.send`, and each tool it calls goes through the
  usual approvals.
- **iOS, later.** The visual is in the transcript, so the companion can draw it with its own web view.

## 9. Milestones

| # | Delivers |
|---|---|
| V1 | **HTML files** (§7): the `html` kind in the file viewer, Rendered \| Source, folder-only reads, network blocked, Open in browser; `.html` file cards open rendered. |
| V2 | **Visuals**: `show_visual` in the engine, recorded and given to every runtime, the prompt section; the card (§4.1) with the wrapper, tokens and sandbox (§4.2, §5.1); bundled libraries (§5.2); live only in view (§6); Open and Save…. |
| V3 | **Checked and talking back**: the check through `app.tool` (§3.2) with errors and `look`; `piopio.send` and `piopio.prefill` (§4.4). |
| V4 | **Elsewhere**: export (§8), snapshots to Telegram and WhatsApp, MCP Apps in the card (D6). |

V1 stands alone and is small. V2 alone already gives what the references show; V3 is what makes "pick one" work.

## 10. Later

- **Editing a visual in place**: the model changes a saved file and the card follows it (canvas-style). Until then, a
  new card per version.
- **Drawing as it streams**, once a partial page can be drawn without flicker.
- **State that survives** scrolling away and reloading (a visual's inputs kept with the conversation).
- **F1 as a feature**: a `/visual` command or a quick action that asks for a 3D explanation. With V2 it's a prompt
  away, so this waits until it's used enough to deserve a button.

## 11. Questions for you

| # | Question | Proposed |
|---|---|---|
| VSQ1 | What the card and the tool are called: "Visual", "Preview", "Widget" | Visual, `show_visual` |
| VSQ2 | No network at all, or the bundled libraries plus an opt-in CDN allowlist (Settings › Chat) for libraries Piopio doesn't ship | No network; add a library when one is missed |
| VSQ3 | Clicking **Go with B**: send right away, or put it in the composer | Send (it's your click), with the "from" tag |
| VSQ4 | Should the model look at its own visual by default when it can see images | No: errors only; `look` when it asks |

## 12. Not verified

- A `WKWebView` inside a TextKit 2 attachment view: resizing with the content, scrolling smoothly past it, and the
  wheel going to the transcript, not the page.
- The cost of drawing off screen for the check at the column's width, and of snapshots in a conversation with 30
  visuals.
- That a custom-scheme base URL with `loadHTMLString` gives no file access and that the content rule list catches every
  load the CSP doesn't.
- How well current models follow the tokens and the "no network" rule without examples; the prompt may need a short
  example visual.

## 13. V1 as built (2026-11-16)

**What changed.** `FileView.swift`: `FileKind` has an `html` kind (`.html`, `.htm`, `.xhtml`, globe icon). The viewer shows
it **Rendered** by default, with the same **Rendered | Source** switch as Markdown; opened at a line (a change the agent
made), it starts on Source, where the line is. `HTMLFile` draws the page in a `WKWebView`:

- `loadFileURL` with read access to the file's own folder; when that folder is your home folder or above, only the file
  itself. Both paths are resolved first: WebKit refuses a file at `/private/tmp/…` with access to `/tmp/…`.
- A content rule list (`piopio.offline-html`, compiled once) blocks every load but `file:`, `about:`, `data:` and
  `blob:`, added before the first load.
- A non-persistent data store; no windows opened by scripts; navigation only to files and anchors. A web or mail link
  you click opens in your default browser; any other navigation is cancelled. Responses WebKit can't show are refused
  (no downloads). JavaScript alerts are ignored (no UI delegate).
- Above the page: a `wifi.slash` icon whose tooltip says the preview is offline, and **Open in browser**, which opens
  the file in the system's web browser (not whatever app opens `.html` files).

Build's file viewer counts HTML as editable (Edit and Open in an editor stay). File cards and a folder chat's preview
use the same viewer, so `.html` files open rendered everywhere.

**Different from §7:** **Open in browser** opens your default browser, not the built-in one, which keeps each
conversation's tabs and only loads http(s) (22). `piopio-lib:` comes with V2.

**Checked.** In a copy of the app (own bundle id, temporary data), a folder chat previewing a test page: its local
stylesheet and SVG loaded, its script ran, an image from the internet was blocked, and its `fetch` to the internet
failed; Source showed the highlighted code. Not checked: clicking a web link (it opens your browser), a file in a git
worktree, Build's sheet viewer.

## 14. V2 as built (2026-11-16)

**Engine.** `tools/visuals.ts`: `show_visual({title, html})`, defined once with an extension for pi-coding-agent
(chats and Build, both sets of factories in `runtimes/build.ts`) and one for pi-durable (agents, `agentExtras`). It
checks and answers in one line: empty HTML and more than 300 KB are refused; HTML that reaches for `http(s)` is shown
with a warning that those parts won't load. The HTML stays in the call's arguments, which is what the app draws, so
the protocol didn't change. The prompt section (§3.3) names the tokens, the libraries, `piopio.send`, and says to use
words in Telegram and WhatsApp. It's a user tool in the approval policy (runs in Read only) and stays its own item
when steps fold (`keepAlone`).

**App.** `PiopioTranscript/VisualCard.swift`:
- **The card** is a view attachment like the file cards: a header (icon, title, Open, Save…, Copy HTML, Reload; Show
  all when the visual is taller than 900 pt) over the visual, in a hairline frame. Its height follows the page's
  `ResizeObserver` and the document lays out just that line again. Before the first height it's 180 pt with
  **Drawing…**.
- **The page** (`VisualPage`): our head first (CSP of §5.1, the tokens as CSS variables in light and dark, base styles,
  an import map for `three` and `three/addons/`, the bridge), then the model's fragment as the body; a whole document
  keeps its own head after ours. Loaded with `loadHTMLString` on `piopio-visual://visual/`.
- **The sandbox**: a non-persistent store; a content rule list that blocks everything but `piopio-lib`,
  `piopio-visual`, `about`, `data` and `blob`; navigation only within the page; a link you click opens in your default
  browser; camera and microphone refused; no pop-ups; the wheel goes to the conversation.
- **Libraries** (§5.2) in `VisualLibraries/`, 1.7 MB with their licences: Chart.js 4.4.7 (`piopio-lib://chart.js`),
  d3 7.9.0 (`piopio-lib://d3.js`), three.js r169 as a module (`piopio-lib://three.js` and OrbitControls under
  `three/addons/`), KaTeX 0.16.11 (`piopio-lib://katex/katex.js`, `.css`, woff2 fonts). Served with CORS so modules
  load. The file viewer serves them too, so a saved visual draws there.
- **Talking back**: `piopio.send(text)` sends `text` as your message, only within 3 s of a click inside that visual
  (or a key press while it has focus) and once per click. Clicks are watched app-wide, because WebKit takes them in its
  own views.
- **Live views**: the store keeps up to 6 web views by tool call (the transcript renders items again often; the web
  view moves to the new card instead of reloading), with their heights and a picture taken once a visual settles. A
  visual evicted and scrolled back to shows its picture until it has drawn again.
- **Open** shows the visual in a sheet (1000 × 720, scrolling), where `piopio.send` sends and closes the sheet.
  **Save…** writes the page without the CSP and with `send` a no-op, to the conversation's folder by default.

**Different from the spec:** Open is a sheet, not the right column (§4.3). `piopio.send` came forward from V3, without
the "from *title*" tag; `piopio.prefill` isn't built. Live views are the 6 most recent, not "the 4 in view" (§6). A saved
visual's libraries stay `piopio-lib://` references, so it draws in Piopio's viewer but not in another browser.

**Checked.** Engine tests (the tool's answers, the prompt, Read only) and Swift tests (the library's paths, the page,
a saved page, the renderer). In a copy of the app with the scripted model, in a folder chat: a Chart.js chart in the
app's colours with `fetch` to the internet blocked, three option cards whose height fit, and a three.js cube through
the import map with OrbitControls; Open showed the options in the sheet; **Go with B** sent "Go with B" from the sheet
and from the transcript, and **Go with A** from the transcript. Not checked: Save…, Reload, eviction and pictures with
more than 6 visuals, dark mode, an agent's chat, a real model.

**Known:** clicks in a visual while a turn is still running were lost in early tries (the transcript renders the item
again and the web view moves card); after the turn they worked every time.
