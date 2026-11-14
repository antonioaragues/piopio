# 22 — The built-in browser

Status: draft, 2026-11-12. **2026-11-14: Playwright MCP built in as an interim browser (§13). 2026-11-15: the user
chose this design (WebKit in the app) as the browser; §11 decided as proposed. W1 built 2026-11-15 (§14) and the
interim one removed. W2 built 2026-11-15 (§15).** Companion to [23-computer-use.md](23-computer-use.md): the browser
is for websites, computer use is for Mac apps. §8 here holds the plumbing both share. Covers roadmap items B10 (web
preview) and part of D10.

## 1. The experience

Piopio has a browser of its own. You can see it and use it, and so can the model.

1. **Ask for something on the web.** "Find the cheapest direct flight to Lisbon on the 3rd." A browser pane opens
   beside the conversation. You watch the pages load, the search fill in, the results sort. The conversation shows
   one folded line, **Browsed 4 pages · flights.example.com**, that opens into the steps.
2. **It asks before it acts on a new site.** Reading is free. The first time it wants to click or type on a site, a
   card asks: **Let Piopio act on flights.example.com?** — This time · In this conversation · Always · No.
3. **You can take over at any moment.** Click in the pane and the model pauses ("You're driving"). Do what you need
   (sign in, solve a puzzle, pick a seat), then **Hand back**.
4. **Sign-ins are yours to do.** When a page wants a password, the model stops and says **Sign in to continue**. You
   sign in in the pane; the browser remembers it for next time. The model never types a password.
5. **Agents browse too.** A "Price watch" agent opens the same three pages every morning without a pane on screen.
   Its chat shows what it visited, and **Watch** opens its browser live.
6. **In a project, it's the preview.** "Run the app and check the signup form." The model starts the dev server,
   opens `localhost:3000` in the pane, fills the form, reads the console error and fixes it.

The whole model: **a browser you both use; reading runs, acting asks per site, passwords and payments are yours.**

### Why not just `web_fetch`
`web_fetch` (`tools/web.ts`) downloads a page as markdown. It can't run the page's scripts, stay signed in, click,
fill a form, or show you anything. It stays the cheap default for reading public pages; the browser is for pages that
need a real browser. The prompt says so ("read with web_fetch; open the browser when a page needs scripts, a sign-in
or interaction").

## 2. Decisions this takes (to confirm)

| # | Decision | Alternative considered |
|---|---|---|
| BW1 | **WebKit, hosted by the Mac app** (`WKWebView`), reached through `app.tool`. Nothing to bundle, it's the page you see, and macOS handles sign-ins and passkeys. | A bundled Chromium driven over CDP (Playwright): sturdier automation and the same engine in the cloud, but +150 MB or more, a second process, and you watch a video of it instead of the page. Driving your own Chrome through an extension: your real sign-ins, but not built in and much riskier. |
| BW2 | **Page structure first, pixels second.** The model reads a list of the page's interactive elements with short refs and acts on refs. Screenshots are for what structure doesn't describe (charts, canvases, layout checks). | Screenshot-and-coordinates only: works with fewer models, costs more, and can't refuse a password field by its type. |
| BW3 | **Reading runs; acting asks per site.** Grants are This time · In this conversation · Always. | One switch for the whole browser. |
| BW4 | **The model never types passwords or card numbers, and never reads them.** Sign-in and payment are hand-offs to you. | Filling from the Keychain on your approval (later, if hand-offs are too frequent). |
| BW5 | **Two kinds of profile.** *Yours* (one, keeps your sign-ins, used by your conversations) and *separate* (one per agent, starts empty). An agent can be given yours in its setup, with a warning. | Every conversation gets a clean profile (safe, but nothing stays signed in). |
| BW6 | **Conversations first, then agents, then the project preview.** | Agents first. |
| BW7 | **The browser needs the app open.** With the app closed, browser tools answer "Piopio isn't open", like Apple app tools (06-agents NB2). | A headless helper process (later, with the login-item helper). |

## 3. What the model gets

One tool group, `browser`, with small stable names. Every call takes an optional `tab`; without it, the current one.

| Tool | Does | Kind |
|---|---|---|
| `browser_open({url, newTab?})` | Goes to a URL; waits for the page to settle. Returns title, final URL and the first screen of the page map. | reads |
| `browser_read({selector?})` | The page (or one part) as markdown, like `web_fetch` but of the live, signed-in page. | reads |
| `browser_map({filter?})` | The interactive elements now visible or reachable: `[e12] button "Search"`, `[e13] textbox "From" value="MAD"`, with roles, names, values and state. Refs last until the page changes. | reads |
| `browser_screenshot({ref?, fullPage?})` | An image of the viewport, an element or the whole page. | reads |
| `browser_find({text})` | Refs of elements whose name or text matches. | reads |
| `browser_click({ref \| x,y})` | Clicks an element (or a point, for canvases). | acts |
| `browser_type({ref, text, submit?})` | Types into a field; `submit` presses Return. | acts |
| `browser_select({ref, value})` | Chooses an option, checks a box. | acts |
| `browser_key({keys})` | Keys and shortcuts in the page. | acts |
| `browser_scroll({ref?, by})` | Scrolls the page or one element. | reads |
| `browser_back()` / `browser_tabs({op})` | History; list, open, switch and close tabs. | reads |
| `browser_wait({for, timeout?})` | Waits for text, an element, or a quiet network. | reads |
| `browser_console()` / `browser_requests({filter?})` | Console messages and the page's own fetch/XHR calls. **Projects only** (§6). | reads |
| `browser_eval({code})` | Runs JavaScript in the page. **Projects only, local addresses only,** and it asks. | acts |

- Every acting tool returns what changed: the new URL if it navigated, and the part of the map that differs, so the
  model rarely needs a second call to see the result.
- Tools that return images need a vision model. Without one, `browser_screenshot` isn't offered and the rest work.
- A step budget per turn (default 40 browser actions, a setting) ends runaway loops with "I've stopped after 40
  steps; here is where I am."

## 4. Permissions and safety

### 4.1 What's enforced by Piopio (not left to the model)
- **Acting needs a grant for the site** (the registrable domain: `mail.example.com` and `example.com` are one site).
  No grant, no click. Grants live in Settings › Browser › Sites and can be removed there.
- **Secret fields are closed.** Password inputs, one-time-code fields and payment fields (`type=password`,
  `autocomplete` of `current-password`, `new-password`, `one-time-code`, `cc-*`) are left out of the map with their
  values, drawn blurred in screenshots, and refuse `browser_type`. Reaching one triggers the hand-off (§4.3).
- **Local and private addresses are refused** exactly as `web_fetch` refuses them (same checks, same DNS pinning),
  except in a project, where the project's own dev servers on `localhost` are allowed (§6).
- **Only `http` and `https`.** No `file:`, no `javascript:`, no custom schemes; links that open other apps are not
  followed.
- **Downloads ask, uploads ask.** A download lands in the conversation's files after you allow it, never opened or
  run. Choosing a file to upload always shows you the file and the site.
- **Page permission prompts are denied** (camera, microphone, location, notifications) when the model is driving.
  When you're driving, you get the normal prompt.
- **Pop-ups and new windows** open as tabs in the same pane; a page can't open more than a few without you.
- **Piopio's own pages are out of reach.** The browser can't open Piopio's settings or approval UI (they aren't web
  pages), so a page can't talk the model into approving itself.

### 4.2 What the model is told to do (and may get wrong)
The prompt asks it to stop and ask before anything that sends, buys, books, deletes, publishes, accepts terms or
shares personal details. Piopio can't reliably tell a "Search" button from a "Pay" button, so this part is
instruction, not enforcement. Two things reduce the cost of a miss:
- **"Ask before each submit"** as a per-site level (§4.4) for sites where a wrong click is expensive: every form
  submission and every click that causes a non-GET request shows what will be sent and waits.
- **Payment pages are hand-offs** (enforced, through the secret-field rule): the model can fill a cart but not pay.

### 4.3 Hand-offs
The model can't get past these on its own; the run pauses and the conversation shows a card (for agents, also Needs
you and a notification):
- **Sign in**: a password or passkey prompt appeared.
- **Prove you're human**: a CAPTCHA or similar check. The model never attempts them.
- **Pay** or **enter a code**.
- **Confirm**: on a site set to "Ask before each submit".

You act in the pane and press **Hand back**; the model gets "The user finished signing in" and a fresh page map,
never what you typed.

### 4.4 Levels, per site
| Level | Reading | Clicking, typing | Submitting |
|---|---|---|---|
| Not allowed (default for a new site) | runs | asks | asks |
| Ask before each submit | runs | runs | asks every time |
| Allowed | runs | runs | runs |
| Blocked | refused | refused | refused |

- With **your profile** (it carries your sign-ins), *opening* a site the conversation hasn't visited also asks,
  unless you wrote or pasted that address yourself. This closes the easy leak where a page tells the model to open
  `evil.example/?q=<something private>`. With a separate, empty profile, opening runs like `web_fetch`.
- For agents, the browser is one row in Setup › What it can use (Off · Asks · Allowed, AD6) and a list of sites. Off
  hides the tools. Asks means the per-site grants above. Allowed means its listed sites never ask; any other site
  still does.
- Banking, government-ID and password-manager sites start as **Blocked for acting** from a short built-in list you
  can edit; the model can read them if you open them, but not click.

### 4.5 What pages say is not what you say
Page text, including hidden text, alt text and anything a page puts in a dialog, reaches the model wrapped and marked
as untrusted content. It never counts as an instruction from you, and it can't grant a permission. Dialogs
(`alert`, `confirm`, `beforeunload`) are answered by Piopio (dismissed, and reported to the model), not by the page.

## 5. The pane

- **Where:** the conversation's right column gets a **Browser** tab, next to Summary and Files. It opens by itself the
  first time the model uses the browser in a conversation, and from the composer's + menu ("Open browser"). It can
  be widened or popped out into its own window.
- **What's in it:** a tab strip, back / forward / reload, the address (you can type one), and the page. A small lock
  shows the site's level; clicking it changes the level.
- **Who's driving:** a thin bar says **Piopio is browsing** with **Stop**, or **You're driving** with **Hand back**.
  While the model drives, its next target is outlined before it clicks, so you can follow.
- **In the transcript:** browser steps fold into one line per stretch of work (AQ8 style): "Browsed 4 pages ·
  flights.example.com · 38s". Opened, each step is a sentence ("Typed 'Lisbon' in To") with a thumbnail when a
  screenshot was taken; clicking a step shows that screenshot large.
- **Agents:** no pane while they work on their own. The agent's chat shows the same folded line, and **Watch** opens
  the pane on its live browser. An agent's browser runs in a window that isn't on screen.
- **Each conversation has its own tabs.** They close when the conversation is archived or after a day unused; the
  profile (cookies, storage) stays.

## 6. In a project: the preview

- The pane is also the web preview Build has been missing (B10). `localhost`, `127.0.0.1` and `*.localhost` on ports
  that a process started from this project is listening on are allowed without asking; other local addresses ask.
- The preview uses a **separate, empty profile per project**, so a page under development never sees your sign-ins.
- `browser_console` and `browser_requests` let the model read errors and failed calls. They come from scripts
  injected before the page's own (console and `fetch`/`XMLHttpRequest` wrapped), so they show what the page does, not
  every network detail a full devtools would.
- `browser_eval` is for poking at your own app. It's limited to local addresses and asks first unless the
  conversation is in Full auto.
- "Pick an element": you click something in the preview and it goes into the composer as a reference (selector,
  text, a small screenshot). Later.

## 7. Sign-ins and profiles

- A profile is a WebKit data store kept on this Mac under Piopio's app support folder: cookies, local storage,
  caches. Nothing is synced and nothing is shared with Safari.
- **Yours:** one profile, used by your conversations. Sign in once to the sites you want Piopio to work on.
- **Separate:** one per agent and one per project preview, created empty. Settings › Browser lists them with their
  size and a **Clear** button.
- An agent set to use your profile shows that in its glance strip ("Can: browse as you"). Its routine runs still
  can't act on a site it has no grant for.
- Passwords and passkeys come from macOS when *you* are driving. Nothing in Piopio stores a web password.
- Cloud agents (later, §10) never get your profile.

## 8. Under the hood (shared with computer use)

- **The app serves the tools.** The engine can't host a web view, so `browser_*` and `computer_*` calls go to the app
  as `app.tool` reverse requests, as the Apple apps do (03-engine-protocol §3.12). Changes to the protocol:
  - `app.tool` takes **who is asking as a `ref`** (any conversation or agent), not only an agent. `groups` stays;
    `browser` and `computer` are new groups.
  - Its result gains **`images`** (`[{mimeType, data}]`) next to `output`, for screenshots, and `card.kind` gains
    `page` and `screen`.
  - `engine.hello` says which groups this client serves, so the engine only offers tools the app can run.
  - A call can outlive a normal request (a page load, a hand-off waiting for you). Hand-offs return at once with
    `needsUser` and the engine parks the run with its existing durable approvals; they don't hold a request open.
- **Permissions are decided in the engine, executed in the app.** The engine owns grants and levels (so they work
  the same for agents, conversations and, later, the cloud) and sends the decision with each call; the app enforces
  what only it can see (secret fields, the kind of request a click causes) and reports back when a call needs you.
- **The timeline:** `ToolDetails` gains `{type: "browser", url, title, action, target?, image?}` and
  `{type: "screen", app, window?, action, target?, image?}`. Images are files next to the conversation's attachments
  (`<home>/attachments/<conversation>/captures/`), deleted with it.
- **The page map** is built by a script running in an isolated content world: it walks the accessibility-relevant
  DOM (roles, names, values, visibility, shadow roots, same-origin frames), gives each element a ref, and skips
  secret fields. Cross-origin frames are mapped by injecting into each frame.
- **Acting:** the app delivers real pointer and key events to the web view (pages see trusted input); scripted
  events are the fallback. The web view must be in a window to receive them, hence the off-screen window for agents.
- **The ladder:** the prompt orders the tools from most to least specific: a connector or Apple app tool if one
  fits, `web_fetch` for reading public pages, the browser for websites, computer use for Mac apps.
- **Stop:** the bar's Stop and a global shortcut call `sessions.abort`; the app also drops any action in flight.
- **Costs:** a page map is text (roughly 1–4k tokens); a screenshot is one image. The cost line of a turn doesn't
  change shape; Settings › Browser can cap screenshots per turn.

## 9. Milestones

| | Scope | You can | Size |
|---|---|---|---|
| **W0 · Spike** | A web view driven from a test harness: the page map on 10 real sites, trusted clicks and typing, an off-screen window, two data stores side by side, an image tool result through pi and OpenRouter to a model and back. | Read a go / no-go on BW1, with the sites that failed and why. | S |
| **W1 · Read** | The pane; `browser_open`, `_read`, `_map`, `_screenshot`, `_find`, `_scroll`, `_back`, `_tabs`, `_wait`; your profile; the protocol changes in §8; folded steps. Conversations only. | Ask about a page that needs scripts or your sign-in, and watch it read. | M |
| **W2 · Act** | `_click`, `_type`, `_select`, `_key`; site grants and levels; secret fields; hand-offs; take over and hand back; downloads and uploads ask; Settings › Browser. | Have it fill a form on a site you allowed, sign in yourself when asked, and stop it mid-way. | L |
| **W3 · Agents** | The `browser` row in agent setup with its sites; separate profiles; off-screen runs; Watch; hand-offs in Needs you and notifications. | Give a routine three pages to check each morning with the window closed (app open). | M |
| **W4 · Preview** | Local addresses for a project's own servers; per-project profile; `_console`, `_requests`, `_eval`. | Ask a Build session to run the app and check a page it just changed. | M |

W1 can ship without W2; each later one is useful on its own.

## 10. Later
- **Cloud agents:** the same tool names over Cloudflare's Browser Rendering (a headless Chromium driven from the
  Worker), with a clean profile and no hand-offs to a pane; a hand-off becomes a link you open. Needs Phase 5.
- **A headless helper** so agents can browse with the app closed (with the login-item helper, 06-agents NB2).
- Filling a saved sign-in from the Keychain on your approval, without the model seeing it.
- Pick an element, record a flow as a routine, saved pages as conversation files, reader view, a content blocker.

## 11. Questions for you (decided 2026-11-15, as proposed)
1. **BW5:** should your conversations use one profile with your sign-ins (proposed), or start clean each time?
2. **Where the pane lives:** a tab in the right column (proposed), or a full page of its own in the sidebar?
3. **Agents with your sign-ins:** allow it with a warning (proposed), or never?
4. **Order:** the browser before computer use (proposed: it covers most tasks, needs no macOS permissions and is
   easier to make safe), or the other way round?

## 12. Not verified
- Nothing was run. Every claim about WebKit here is from its documented API, not from a test: per-identifier data
  stores, script injection in an isolated world, snapshots, trusted input to an off-screen view, and whether the
  SwiftUI `WebView`/`WebPage` API exposes enough or `WKWebView` is needed. W0 checks them.
- Whether macOS password and passkey AutoFill appear in an embedded web view for a non-browser app.
- Whether pi passes images in tool results through to each provider (OpenRouter, ChatGPT sign-in, local models).
- How many real sites refuse or degrade for WebKit that isn't Safari (user-agent checks, bot detection). If W0 finds
  this is common, BW1's Chromium alternative comes back.
- Cloudflare Browser Rendering's current limits and price.

## 13. As built (2026-11-14): Playwright MCP, built in

Decided with the user on 2026-11-14: instead of building BW1's WebKit browser, ship an existing Chromium one, on by
default. What was looked at first (npm, 2026-11-14): about 30 pi packages for the browser, every one Chromium
(agent-browser, CDP to your own Chrome, Playwright, chrome-devtools-mcp); none hosts a browser inside an app.

**Why Playwright MCP and not a pi package.** pi packages' extensions load only in Build; chats run on pi-durable and
reach MCP servers instead. An MCP server works in both, through what already exists (Settings › MCP servers, Build's
approvals). `@playwright/mcp` (Microsoft, Apache-2.0, ~10M downloads a week) has the contract the pi packages
converged on: an accessibility snapshot with `[ref=eN]`, actions by ref, `browser_find` to search a big page,
screenshots as images, tabs, console and network.

**How it runs** (`packages/engine/src/browser.ts`):
- The engine runs **one** Playwright MCP server over local HTTP (`127.0.0.1`, a port chosen once and kept in
  `<home>/browser/state.json`), driving the Mac's **Chrome** (else Edge, Brave or Chromium), **visible**, with its
  own persistent profile in `<home>/browser/profile`. You watch it work, and you sign in in that window yourself; the
  sign-in stays. Every client shares that one Chrome and its tabs (a persistent profile opens in one Chrome only).
- On first launch it's **seeded into pi's `~/.pi/agent/mcp.json` as `browser`** (`exposure: "deferred"`,
  `browser_run_code_unsafe` hidden) and turned on for chats. From then on it's an ordinary MCP server: Settings › MCP
  servers shows it, turns it off (the engine stops the server) or deletes it (Piopio doesn't add it back). An entry
  of your own called `browser` is left alone. The pi CLI sees it too, while the app's engine runs.
- Chrome closes after **5 minutes without a browser call** (`--idle-timeout`; decided with the user 2026-11-15
  instead of asking the model to close it) and opens again on the next call, still signed in.
- Options: `--snapshot-mode none` (actions return the URL and title; the model asks for `browser_snapshot` or
  `browser_find`, because a whole page can be 600k characters and Playwright otherwise writes it to a file a chat
  can't read), `--codegen none`, `--file-paths absolute`, console at warning level, output capped at 50 MB.
- **Fourteen core tools are declared from the start** (navigate, back, snapshot, find, click, type, fill_form,
  select_option, press_key, screenshot, tabs, wait_for, handle_dialog, close; per-tool `toolExposure: "direct"`);
  the rest are found with `tool_search`. The first real run (2026-11-15, Hacker News, Sonnet) needed two searches to
  reach `browser_snapshot`, and each search changed the tools and lost the prompt cache: about $0.18 for three
  stories. It also read the URL-and-title answer of `browser_navigate` as an empty page, so the description now
  says actions return only that. Installs seeded earlier get both on the next launch (`state.json` version 2).
- Chats list their deferred MCP servers in the prompt (`serversSection` in `tools/mcp-chat.ts`), since
  `tool_search` doesn't say what's behind it; Build already had pi's `mcp_servers` section.
- The release bundle ships `@playwright/mcp`, `playwright` and `playwright-core` in `engine/node_modules` (+23 MB,
  no browsers). Off with the scripted model and with `PIOPIO_BROWSER=0`.

**What's not there (compared with §1–§12):**
- **Approvals per site** (BW3) and secret fields (BW4) aren't enforced. In Build, each browser tool is an MCP tool:
  Ask asks per tool, Auto-edit runs it. **In chats nothing asks** (chat MCP has no approvals); the server's
  description tells the model to stop before sending, buying or sharing, and to leave passwords to you.
- No pane in the app: the browser is Chrome's own window. No folded "Browsed 4 pages" line beyond the usual tool rows.
- Agents don't get it (agents have no MCP yet). Build sessions share your signed-in profile (no per-project one, §6).
- The HTTP server answers any process on this Mac, with the browser's sign-ins. Same as the pi packages that attach
  to Chrome; a token would need Playwright to support one.
- Tried with Sonnet in a chat on 2026-11-15 (Hacker News): it works; not tried in Build.

**Interim.** On 2026-11-15 the user chose §1–§12 (WebKit in the app) over making this one Piopio's own. Removed with W1
(§14): the engine deletes its `browser` entry from `mcp.json` (if it still points at its port), its chat switch and
`<home>/browser/`. What it added to chats' MCP stays: deferred servers named in the prompt, per-tool `toolExposure`,
and retrying a server that didn't answer.

**Local models can't see screenshots:** custom endpoints are declared text-only (`endpoints.ts`), so pi replaces a
tool result's image with "(see attached image)". OpenRouter models that take images and ChatGPT sign-in get them.

**What the stopped WebKit spike (W0) measured**, for if §1–§12 come back: a `WKWebView` takes trusted clicks and
keys sent straight to the view in any window (on screen, off screen, never shown); a page map from an isolated content
world reaches shadow DOM and same-origin frames, and cross-origin frames by their `WKFrameInfo`; two
`WKWebsiteDataStore(forIdentifier:)` stores stay apart and persist across launches. A window off screen or never shown
is throttled to 1 animation frame a second (`inactiveSchedulingPolicy = .none` doesn't help); an on-screen window at
alpha 0 that ignores the mouse runs at full speed. The real-site run didn't finish.

## 14. W1 as built (2026-11-15)

**Engine.** `tools/browser-tools.ts`: `browser_open`, `_read`, `_map`, `_find`, `_screenshot`, `_scroll`, `_back`,
`_tabs` and `_wait`, defined once with an extension for chats (pi-durable) and one for Build (pi-coding-agent), and a
prompt section. Each call goes to the app as `app.tool` with the conversation's `ref` and `groups: ["browser"]`;
`app.tool` now takes `ref` (with `agent` optional) and answers `images`. Only an app that says `browser` in
`engine.hello` is asked; with none, the tool says Piopio isn't open. `browser_open` refuses anything but http(s) and
local or private addresses before asking the app (as `web_fetch`). In Build the tools count as network reads (like
`web_fetch`): they run in Read only and Auto-edit, and ask in Ask.

**App.** `Browser.swift`: `BrowserCenter` keeps each conversation's tabs (`BrowserSession`, `BrowserTab`), all in one
persistent `WKWebsiteDataStore(forIdentifier:)`: your profile (BW5). The page script (`BrowserScript.swift`, from W0)
runs in an isolated content world: the map (refs keyed to the element, `@(x,y)`, secret fields left out and named),
reading as markdown (headings, lists, links, tables, code; a selector reads every match), scrolling, waiting for text.
Screenshots are JPEG, at most 1280 px wide. Tabs no panel shows live in a transparent window on screen (alpha 0,
ignores the mouse) so pages run at full speed (W0). The user agent ends like Safari's. Links to other schemes and to
local addresses aren't followed; downloads, camera and microphone are refused; pop-ups open as tabs (up to 8);
`alert`/`confirm`/`prompt` are answered by Piopio and reported to the model.

**Panel.** `BrowserPanel.swift`: a Browser view (globe) in a chat's toolbar and in Build's right column (560 pt):
tabs when there are several, back / forward / reload, the address (or a search), a new tab, and the page itself,
which you can use. It opens by itself the first time the model browses in that conversation.

**Checked.** Engine tests: the calls reach only an app that runs the browser, with the conversation's or the Build
session's ref; the URL check; the interim browser's removal. In the app, with a copy (own bundle id, scripted model,
temporary data): open, read, find, scroll, screenshot, a second tab, the tab list and wait on Wikipedia, Hacker News
and BBC News; a local address refused; the panel opening by itself (capture). Not yet with a real model.

**Not in W1:** acting (W2); a folded "Browsed 4 pages" line (each call is its own tool row); Settings › Browser (clear
the profile); closing a conversation's tabs when it's archived; offering `browser_screenshot` only to models that see
images; reading pages that lay out with tables (Hacker News) reads cramped.

## 15. W2 as built (2026-11-15)

**Acting.** `browser_click` (a ref, or x and y; `double`), `browser_type` (replaces unless `append`; `submit` presses
Return), `browser_select` (an option by value or text; a checkbox or radio with true or false) and `browser_key`
("Enter", "ArrowDown", "cmd+a"…). The app re-resolves the ref, scrolls it into view and refuses when something covers
it (it names what). Clicks and keys are real events sent straight to the web view (W0), so they work in the panel and
in the transparent window alike and never type into the composer. Typing reads the field back; when the page didn't
take the keys it sets the value with the native setter and says so. Each action answers with what changed: the new
page with its map, or the map's lines that appeared (+) and went (−).

**Per site (BW3, §4.4).** The engine keeps the sites: Always allowed and Blocked in `<home>/browser-sites.json`, and
each conversation's in memory (until the engine restarts). It sends the allowed ones with every acting call; the app
compares them with the registrable domain of the page actually showing (a short list of two-part suffixes stands in
for the Public Suffix List) and, if it isn't there, does nothing and answers `needsSite`. The engine then asks: in a
chat, a card (Allow · Deny · "Allow, don't ask again", which saves the site); in Build, Build's approval prompt. A
blocked site is refused without asking; a denial tells the model not to try another way. In Build, the approval mode
no longer asks per acting tool (the site asks); Read only still keeps them out.

**Yours (BW4, §4.3).** Typing into a password, one-time-code or card field is refused, also when a click or Tab moved
the focus there, with the instruction to ask the user. Hand-offs are that message and the prompt: the model tells you
to sign in, solve the check or pay in the panel and waits for you to say so; there is no paused run or Hand back button.

**Panel.** "Piopio is browsing" with Stop (it stops the conversation's turn) while the model acts and for six
seconds after. Downloads ask ("Save X from site?") and go to Downloads, never opened; choosing a file to upload is the
system's panel, naming the site. Settings › Browser lists Always allowed and Blocked sites (remove, block one), and
Clear… deletes the profile's cookies, storage and cache.

**Checked.** Engine: Allow is per conversation, "don't ask again" keeps the site and Settings lists it, Deny, blocked
without asking (`acting asks per site…`); policy (`the browser reads like web_fetch…`). In the app copy with the
scripted model: the httpbin.org order form filled and sent (name with an accent, a radio, a checkbox, a textarea,
Submit; the server got exactly that), the card before the first action on each site, GitHub's password field refused
after Tab; captures of the bar and Settings › Browser. Not yet with a real model, and downloads and uploads only built.

**Not in W2:** "Ask before each submit" (§4.4) and a built-in list of blocked sites; taking over by clicking in the
page (Stop is the way); downloads into the conversation's files; secret fields blurred in screenshots; site levels
for agents (W3).

