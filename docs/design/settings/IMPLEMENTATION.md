# Settings › Connectors, Chat, MCP servers, Extensions, This Mac & cloud: what's built

The handoff in this folder (c0–c4, h1, p0–p2, e1–e2, g1) is built on the pattern from the Models handoff
(`../models`). Captures with the faux model are in `screenshots/`.

Shared pieces: `apps/mac/App/Piopio/SettingsParts.swift` holds the page header with summary and add button, the list
row, the detail page scaffold, the permission menu, the empty state, the "found" card and the toggle row.

## Connectors (`ConnectorsSettings.swift`, engine `connectors/`)
| Screen | Built |
|---|---|
| c0 Empty | Chick, the two apps available today with Connect (opens c4), Browse all connectors… (c3). |
| c1 Page | One row per connected account. The subtitle is the account and a summary of its permissions ("reads freely, asks before changes"). An expired sign-in shows an amber dot and an inline "Sign in again". The trailing text says where it's used ("Chats & agents" / "Agents only"); see below. |
| c2 Detail | Header shows "Connected as … · N calendars", plus Switch account (signs in, then removes the old account) or Sign in again. "What it can do" has Runs / Asks first / Off per capability, with its tool ids. A calendars card (toggle and color per calendar). "Where it's used" (chats, notebooks and Build on or off; agents always). Disconnect… with an alert. |
| c3 Add sheet | 800×620, categories with counts, search, Available (✓ Connected) and Coming soon (60%, Soon badge, not clickable). "Use an MCP server" opens the Add server form inside the sheet. |
| c4 Connect step | Permission menus preset to safe defaults, then "Sign in with Google… / Microsoft…". Progress and errors show in the sheet; on success it closes and the new row is highlighted briefly. |

Engine: `connectors/permissions.ts` groups tools into capabilities. Permissions are stored per tool in
`connectors.json`. C1's "Don't ask again" list still reads as Runs.
- **Defaults:** reading runs, changes ask, deleting is off.
- **Never Runs:** sending (mail, calendar invitations) and deleting can't be set to Runs.
- **Off:** a turned-off tool refuses before it touches the app.
- **Reads that ask:** a read set to Asks first asks once per call.
- **Calendars:** turned-off calendars are never read. Outlook reads each chosen calendar; with no choices made, it reads the default one as before.

## MCP servers (`McpSettings.swift`, engine `mcp.ts`, `mcp-probe.ts`)
| Screen | Built |
|---|---|
| p0 Empty | Chick, + Add server. "Found in other apps" reads the configs of Claude Desktop, Cursor, VS Code and Windsurf; Review & import shows a checklist, and nothing is imported on its own. The same card shows on the list page while there's something to import. |
| p1 List | Grouped: For all projects, then In ⟨project⟩ only (trusted projects), then a collapsed "Waiting for trust (N)" with Trust project…. Each server is started to get its status (green, amber for sign-in, red with the error) and its tool count. A badge shows Build / Build + Chat. |
| p2 Add sheet | Command / URL / Paste JSON (fills in the form from an `mcpServers` block or a single server). The command is started about a second after you stop typing: "● Started · 65 ms" or the error in plain words. Also: Available to (all projects / one project), environment variables, "Found N tools", Build and Chat toggles, and "Add anyway" after a failed start. |
| Server page | Status with Restart (starts it again) and View log (its stderr). Connection info, the Build and Chat toggles, tools with a toggle each, and Remove server…. |

Engine:
- **Probe:** `mcp.probe` and `mcp.status` start a server with the MCP SDK, list its tools and close it. Statuses are cached for 10 minutes; Restart refreshes one.
- **Tools off:** a turned-off tool is written as pi's `toolExposure: "hidden"`, so the pi CLI agrees. Chats skip those tools too.
- **Chat per server:** the old page-wide "In Chat" switch became `chat.mcpServers`, a per-server list. Until a choice is made, the old switch still decides, so nothing changes for existing users.

## Extensions (`ExtensionsSettings.swift`, engine `packages.ts`)
| Screen | Built |
|---|---|
| e1 Installed | Summary with the number of updates, Browse pi.dev ↗, + Install, Update all. Rows show content badges in plain words, source and version, and "Update to X" when npm has a newer version. A legend sits under the list. Empty state: chick, Browse pi.dev, Install. |
| e2 Install | The source resolves as you type: "npm:" is added to bare names and "git:" to GitHub paths. The preview shows name, version, author, description and "What it adds": extension (amber, Build only · runs code), skills and templates (green, everywhere), and themes and terminal panels (grey, not shown in Piopio). The trust note shows only when there's code. Choose Folder… is next to the field. |
| Package page | On/off for the whole package, source and install folder (Show in Finder). Each kind (extensions, skills, templates, themes) has its own toggle, and each item has one too. Update and Uninstall…. |

Engine:
- **Preview:** `packages.preview` reads npm packages from the registry, with their file list from jsDelivr. GitHub repos come from their package.json and git tree, folders from disk. Contents come from the `pi` manifest or pi's conventional folders.
- **Single items:** turning one item off writes pi's `-path` filter, which the pi CLI shares.
- **Updates:** checked hourly, for unpinned npm packages only.

## Chat (`ChatExtras.swift`)
h1 has two blocks.
- **Suggestions:** two toggle rows.
- **About me:**
  - **Fact list:** the notebook memory parser, with "Label: value" or the section as the label. The source is "You" or "Learned · when". Edit and Forget appear on hover or in the context menu, and "+ Add something about you…" adds a fact.
  - **History:** a sheet with Undo.
  - **Share with:** Chats & notebooks / + Agents / Nobody.
  - **Learn from conversations:** a toggle.
  - **Stored in:** a menu with Piopio, MCP memory providers, Edit/Try/Remove, and Add MCP memory….

"+ Agents" is new in the engine: About me reaches agents when `aboutMe.inAgents` is on.

## This Mac & cloud (`SettingsView.swift`)
g1:
- **Local engine:** status (Running / Starting… / Stopped with its reason), "N sessions open · N chats · MB", View logs and Restart.
- **Keep running when Piopio quits:** a toggle, off in debug builds and saying why.
- **Details:** runtime, version, uptime, and the data folder with Show in Finder.
- **Cloud:** Cloudflare, Coming soon.

## Adapted, on purpose
- **"Used by Daily briefing"** (c1/c2) isn't tracked. Nothing records which agent used which connector, so the row shows where the connector is available instead ("Chats & agents" / "Agents only"), and the detail page has that toggle.
- **The OAuth client setup is gone from the user's path.** When a build has no registered Google or Microsoft sign-in, the connect step says so. A small "Developer setup…" link takes a client ID for development; users never create OAuth apps.
- **Environment variables stay in mcp.json** (as pi reads them), not the Keychain. Keychain values wouldn't reach the pi CLI, so the editor suggests `${NAME}` for secrets.
- **Project servers aren't offered in chats.** Chats have no project. The toggle is shown off with the reason.
- **Agents and "Runs" for changes:** agents ask through their own approvals, per tool. With "Create and change events" set to Runs, an agent can send invitations without asking. Chats and Build still ask.
- **MCP sign-in** isn't run from Settings. A server that wants it says to sign in with `pi mcp` (amber).
- **"Pin version"** on the package page is left out. Pinning is part of the source (`npm:name@1.2.0`); install it that way.
