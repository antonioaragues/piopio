# Handoff: Piopio Settings — Connectors, Chat, MCP servers, Extensions, This Mac & cloud

## Overview
This is a redesign of five Settings pages in the Piopio macOS app (repo `antonioaragues/piopio`, SwiftUI, `apps/mac/App/Piopio`, mainly `SettingsView.swift` and the files it uses). It follows the same pattern as the **Settings › Models** handoff (`design_handoff_piopio_models`). Build that first, or alongside, because these pages reuse its components.

Current screens are in `before/`.

## The shared pattern (apply to every list-type page)
1. **Header.** Title (24 bold, −0.02em), then a **one-line fact summary** (13.5, `fg2`), e.g. "3 servers · 31 tools · shared with the pi CLI". The current explanatory paragraphs go away.
2. **One primary add button**, top-right: "+ Add connector / server / Install". It is 30 tall, a capsule with `inv` fill, and sits in the same place on every page.
3. **The list shows only what you have**, as grouped cards (radius 12, inset dividers starting at 62).
   - **Row:** 34pt tile (radius 9), name (14 semibold), a 6pt status dot, a subtitle (12 `fg3`), an optional small badge (where it's used), then a chevron.
   - **Each row pushes a detail page inside Settings.** No inline edit or remove buttons.
4. **Adding happens in a sheet.** It shows a catalog or form, **tests the thing live**, and shows what was found (tools, models, contents) before saving.
5. **Editing happens on the detail page.** The page has a back link "‹ Page", a 48pt tile header with a status line, grouped cards, and a footer: an impact note on the left, "Remove / Disconnect…" on the right (`chip` fill, red text).
6. **Empty state.** Use `EmptyState`: 64pt chick with a 6pt `yolkSoft` ring, title (22 bold), one sentence, then real starting points. Anything detected on this Mac or in other apps appears as a `yolkSoft` card.
7. **Fine print goes next to the control it affects**, not in a footer paragraph.

Status colors match the rest of the app: green = OK, amber = needs attention (expired sign-in, update available), red = error, grey = off.

## About the design files
`Piopio Settings Extend.dc.html` is an **HTML design reference**, not production code. Rebuild it in SwiftUI with the existing `Design.swift` components and native controls: `Form`/grouped sections, `.sheet`, `NavigationStack` push, `Toggle`, segmented `Picker`, `Menu`, `DisclosureGroup`.

To view it, open the HTML in a browser with `support.js` and `Piopio Settings Sidebar.dc.html` in the same folder. Screens have id badges (c0–c4, h1, p0–p2, e1–e2, g1). The Tweaks panel toggles light/dark and the accent color.

Glyphs stand in for SF Symbols:
- ⌕ `magnifyingglass` · + `plus` · › `chevron.right` · ‹ `chevron.left` · ⌄ `chevron.down`
- ▦ `calendar` · ✉ `envelope` · ⌁ `puzzlepiece.extension` · ◆ `shippingbox` · ✎ `text.badge.star` · ❏ `doc.on.doc` · ▣ `cpu` · ☁︎ `cloud`

Connector and server tiles stand in for real app logos. All data is sample data.

**Fidelity:** high for structure, copy, hierarchy and tokens. Use native controls wherever they exist.

## Settings sidebar
This is unchanged from today: General, Models, Connectors, Chat, Approvals | **Extend:** MCP servers, Extensions | **Where it runs:** This Mac & cloud. Each item has a 20pt colored icon tile. The selected item gets `accentSoft` fill and semibold text. An amber dot after an item means it needs attention (e.g. nothing connected in Models).

---

## 1 · Connectors

### c0 · Empty
- Title "Connect your apps".
- Body: "Connect once and any chat, notebook or agent can use it. Reading runs on its own; changes ask you first."
- Two option rows for the connectors available today (Google Calendar "Your day in every briefing", Outlook "Calendar and mail"), each with **Connect**. Connect opens c4 directly.
- Link: "Browse all connectors…" opens c3.

### c1 · Connectors page
- Summary line: "2 connected · used by chats, notebooks and agents". Primary button: **+ Add connector**.
- **Connected** card, one row per account:
  - Subtitle: the account and its permission summary, e.g. "antonio@gmail.com · reads freely, asks before changes".
  - Trailing text: "Used by Daily briefing" or "Not used yet".
  - An expired sign-in shows an amber dot and the subtitle "Sign-in expired · **Sign in again**" (accent link that reruns OAuth inline).
- Footer note (12 `fg3`): "Reading runs on its own; anything that changes something asks you first. Change it per connector."
- **Unavailable apps do not appear here.** They only appear in the c3 catalog.

### c2 · Connector detail (pushed)
- Header: tile, name, "● Connected as antonio@gmail.com · 3 calendars", and a **Switch account** button.
- **What it can do** card, one row per capability:
  - Human-readable label, with the tool ids beneath in 11.5 `fg3` (`list_events, free_busy`).
  - Trailing **permission menu**: Runs (green dot) / Asks first (amber) / Off (grey). This replaces the "What it can do" expander.
- **Resource card**, connector-specific (for Calendar: one toggle per calendar, with a 10pt color swatch).
- Footer: impact note ("Used by Daily briefing. Disconnecting removes calendar access from it.") and **Disconnect…**, which confirms in an alert.

### c3 · Add connector sheet (800×620)
- Header: "Add a connector", a search field, Cancel.
- **Left categories** (190 wide): All · Calendar & mail · Files & docs · Team chat · Dev & ops. Pinned at the bottom: **"Use an MCP server"**, which opens p2. This is the escape hatch, like "Custom endpoint" in Models.
- **Right side:** a 3-column tile grid (radius 12). Each tile has a logo, name (13.5 semibold) and a one-line description (11.5 `fg2`).
  - Connected apps stay visible with "✓ Connected".
  - Apps not yet available are in a "Coming soon" group at 60% opacity with a "Soon" badge, and are not clickable.

### c4 · Connect step (pushed inside the sheet)
- Back link "‹ All connectors". Header: tile, name, description.
- **What it can do** card, using the same permission menus as c2, preset to safe defaults: read = Runs, create/change = Asks first, delete = Off. Caption: "Safe defaults. You can change these any time."
- Footer: Cancel / **Sign in with Google…** (accent), which starts OAuth. On success, the sheet closes and the new row appears in c1 with a brief highlight.

---

## 2 · Chat (h1)
These are settings, not a list, so there's no add button and no detail pages.
- Summary line: "Chats and notebooks".
- **Suggestions** card, two toggle rows. Each row has a label and a `fg3` subtitle:
  - "Suggest follow-up messages" / "A few replies under each answer"
  - "Suggest moving a chat into a notebook" / "When a conversation grows into a subject"
- **About me**. The header reads "About me · 3 facts", with a right-aligned **History** link (opens version history in a sheet).
  - **Fact list card**, the same component as notebook memory. Each row has a label (11 semibold `fg3`, 80 wide), the value (13), and a source (11.5 `fg3`: "You" / "Learned · Daily briefing"). Rows support Edit and Forget on hover or with the context menu.
  - Last row: "+ Add something about you…".
  - **Settings card:**
    - "Share with" segmented control: **Chats & notebooks** / + Agents / Nobody. This replaces the "Use it" toggle and the "Where" checkboxes.
    - "Learn from conversations" toggle, subtitle "New facts show in the chat with Undo".
    - "Stored in" menu (Piopio / …).
  - Caption: "Never shared with Build sessions."
- The empty text area and the separate History column go away.

---

## 3 · MCP servers

### p0 · Empty
- Title "Give the agent more tools".
- Body: "MCP servers add tools like a browser, a database or your company's APIs. Piopio shares them with the pi CLI."
- Primary button: **+ Add server**.
- **Found in other apps**: a `yolkSoft` card, e.g. "3 servers in Claude Desktop · playwright, postgres, linear", with **Review & import**. Detect by reading Claude Desktop, Cursor and VS Code MCP config files. Never import automatically.
- The terminal alternative (`pi mcp add`) moves to the add sheet's footer as a hint.

### p1 · Servers list
- Summary line: "3 servers · 31 tools · shared with the pi CLI". Primary button: **+ Add server**.
- Grouped by scope:
  - **For all projects** (`~/.pi/mcp.json`).
  - **In ⟨project⟩ only**, one group per trusted project (`.pi/mcp.json`).
- Row subtitle: the mono command or URL, plus the tool count. For project servers, also "trusted project".
- **Badge** showing where the server is used: "Build" or "Build + Chat".
- Status: green = started, amber = needs sign-in ("Sign-in expired · Sign in again"), red = failed to start ("Exited with code 1 · View log").
- Footer note: "Changes apply to sessions you start or reopen."
- Servers in **untrusted projects** go in a collapsed group "Waiting for trust (N)", which offers "Trust project…".

### p2 · Add server sheet (600 wide)
- Title "Add an MCP server", subtitle "Run a command on this Mac, or connect to a URL".
- **Segmented control:** Command | URL | Paste JSON.
  - Paste JSON accepts a standard `mcpServers` block and fills in the form.
- **Form card** (110pt label column):
  - **Name.**
  - **Command** (mono; for URL mode this row becomes the URL). The command is **started and probed live**. The right side shows "● Started · 1.2 s" or the error in plain language.
  - **Available to:** segmented control, All projects / One project….
  - **Environment variables** ›, a disclosure. Secret values go to the Keychain.
- **Found N tools**: the first few tool names inline (`fg3`).
- **Where it's used** card:
  - "Use in Build sessions" toggle, on by default. Subtitle: "Follows your Approvals settings".
  - "Use in chats and notebooks" toggle, off by default. Subtitle in amber: "Tools run there without asking". This replaces the page-level "In Chat" toggle and makes the choice per server.
- Footer: "Saved to ~/.pi/mcp.json" (`fg3`) · Cancel · **Add server** (enabled after a successful probe).

### MCP server detail (pushed; not drawn, follows m6/c2)
- Header with status and the **Restart** and **View log** actions.
- Connection card: command/URL, environment variables, scope.
- Where it's used: the same two toggles as p2.
- **Tools** list with a per-tool toggle.
- Footer: Remove server…

---

## 4 · Extensions

### e1 · Installed packages
- Summary line: "3 packages · 1 update · shared with the pi CLI".
- Actions: secondary "Browse pi.dev ↗" and primary **+ Install**. The always-visible install field goes away.
- **Installed** card. The header has a right-aligned **Update all** link. Rows:
  - Tile and package name (14 semibold).
  - **Content badges** in plain words: "Extension · Build", "2 skills", "1 skill · everywhere", "4 templates · everywhere".
  - Source and version (11.5 `fg3`): "npm · 1.4.0", "git · github.com/…", "folder · ~/prompts".
  - An available update shows as an "Update to 1.5" capsule (`accentSoft` / accent), then the chevron.
- **Legend** at the bottom, one line each:
  - **Extension**: runs code in Build, with your permissions.
  - **Skills, templates**: text, usable everywhere.
- Empty state: chick, "Add skills and commands", plus "Browse pi.dev" and "+ Install".

### e2 · Install sheet (600 wide)
- Title "Install a package", subtitle "From npm, a git repository, or a folder on this Mac".
- **Source field** (mono, with focus halo). It resolves the package as you type and shows "✓ Found" or an error. Next to it: **Choose Folder…**.
- **Preview card:** tile, name, version, author and a one-line description. Then **What it adds**, one row per part:
  - Amber dot: **Extension** (what it registers: commands, tools) · "Build only · runs code".
  - Green dot: **Skills / templates** (names) · "Everywhere".
  - Grey: parts Piopio can't show, e.g. "Terminal panel · Not shown in Piopio".
- **Trust note** (`chip`): "The extension runs with your user's permissions. Only install packages you trust." Shown only when the package contains an extension.
- Footer: "Installs to ~/.pi/packages" · Cancel · **Install**.

### Package detail (pushed; not drawn)
- Version and source, Update / Pin version, the contents list (as in e2) with per-skill toggles, and Uninstall….

---

## 5 · This Mac & cloud (g1)
- The page title matches the sidebar label: **"This Mac & cloud"** (it was "Engines"). Subtitle: "Where agents run. Everything stays in your own accounts."
- **This Mac** card:
  - Engine row: green tile, "Local engine" with "● Running", subtitle "1 session open · 1 chat · 104 MB", and the actions **View logs** and **Restart**.
  - "Keep running when Piopio quits" toggle, subtitle "Scheduled agents keep working while the app is closed".
  - **Details** disclosure, collapsed by default: Runtime (Node 24.8.0), Version, Data path (mono) with "Show in Finder".
- **Cloud** card: Cloudflare row with subtitle "Runs agents 24/7 in your own account, even when your Mac sleeps" and a "Coming soon" badge. When it ships it becomes a normal connect flow (sheet → detail page), like Models.
- Engine states: Running (green), Starting… (spinner), Stopped (grey, the primary action becomes **Start**), Crashed (red, "Exited unexpectedly · View logs", primary **Restart**).

---

## State / data (additions)
```swift
enum Permission { case runs, asksFirst, off }

struct ConnectorAccount {
  id; connectorID; account: String; status
  capabilities: [Capability: Permission]
  resources: [Resource]   // e.g. calendars with an enabled flag
  usedBy: [AgentRef]
}

struct MCPServer {
  id; name
  transport: .command(String) | .url(URL)
  env: [String: SecretRef]
  scope: .global | .project(URL)
  useInBuild: Bool; useInChat: Bool
  tools: [Tool(enabled)]
  status
}

struct Package {
  id; source: .npm | .git | .folder
  version; latest
  parts: [.extension(commands, tools), .skill(name, enabled), .template(name)]
}

struct AboutMe {
  facts: [Fact(label, text, source)]
  shareWith: .chats | .chatsAndAgents | .nobody
  learn: Bool; store: StoreRef
}
```

## Design tokens
Same as the Models handoff (`docs/design/README.md` / `Design.swift`, plus `yolkSoft`):
- **Surfaces:** win #fdfdfc / #1a1a1c · card #fff / #242426 · chip rgba(0,0,0,.045) / rgba(255,255,255,.08)
- **Text:** fg #1d1d1f · fg2 #5b5b61 · fg3 #8e8e93 · line rgba(0,0,0,.08)
- **Accent:** system accent · accentSoft 14% / 26% · accentLine 45% / 60%
- **Status:** green oklch(.60 .15 150) · amber oklch(.72 .15 70) · red oklch(.60 .19 25)
- **Brand:** yolkSoft oklch(.97 .04 92) / oklch(.30 .05 92) · scrim rgba(30,30,35,.28) / rgba(0,0,0,.5)
- **Type:** 24 bold page · 22 bold detail/empty · 19 bold sheet sub-page · 17 bold sheet · 14 semibold row · 13 UI · 12 secondary · 11 semibold `fg3` labels · SF Mono 12.5 for commands, paths and ids
- **Radii:** sheet 16 · cards 12 · tiles 8–12 · capsules. 4pt spacing grid.

## Files
- `Piopio Settings Extend.dc.html`: all screens above, with the rationale header.
- `Piopio Settings Sidebar.dc.html`: the Settings sidebar component used by every screen.
- `before/*.png`: the current screens.
- `assets/chick.png`: app icon art for empty states. Use the existing icon asset in the app.
- `support.js`: runtime needed only to open the HTML locally.

## Suggested implementation order
1. Shared components: page header with summary line and add button, the list row, the detail-page scaffold, the permission menu, and the live-probe field.
2. Connectors (c1 → c2 → c3/c4, then c0).
3. MCP servers (p1 → p2 → detail → p0 import).
4. Extensions (e1 → e2 → detail).
5. Chat (h1), reusing the memory fact-list component.
6. This Mac & cloud (g1).
