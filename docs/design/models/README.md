# Handoff: Piopio — Settings › Models (providers)

## Overview
This is a redesign of the **Settings › Models** page in the Piopio macOS app (repo `antonioaragues/piopio`, SwiftUI, `apps/mac/App/Piopio`, mainly `SettingsView.swift`).

The page today mixes connected and unconnected providers in one long list. Every row has the same "Connect" button, and the one active provider can end up buried under "More providers (40)". See `before/settings-providers-today.png`.

The new structure:
1. **The Models page** shows only what is in use: connected providers, providers detected on this Mac, and the default model for each mode.
2. **An "Add provider" sheet** holds the full catalog of 40+ providers, plus **custom endpoints** (any OpenAI- or Anthropic-compatible URL).
3. **A provider detail page** (pushed inside Settings) handles editing, replacing the key, choosing which models are visible, and removing.

## About the design files
`Piopio Settings Models.dc.html` is an **HTML design reference**, not production code. Rebuild it in SwiftUI using the existing patterns in `Design.swift`: `GlassPanel`, `PillStyle`, `SectionLabel`, `StatusDot`, `EmptyState`, `CardTile`. Use native `Form`/grouped sections, `.sheet`, `NavigationStack` push inside Settings, `Toggle`, segmented `Picker`, `Menu`, and SF Symbols.

To view it, open the HTML in a browser with `support.js` in the same folder. It's a pan/zoom canvas, and every screen carries an id badge (m0–m6). The Tweaks panel switches light/dark and the accent color.

The glyphs in the HTML stand in for SF Symbols: ⌕ `magnifyingglass`, + `plus`, › `chevron.right`, ‹ `chevron.left`, ✓ `checkmark`, ⌄ `chevron.down`, ⚙︎ `gearshape`, ✦ `sparkles`. The provider "tiles" (OR, A, GPT, OL, LH) are placeholders for real provider logos. Use the logo assets if the app has them; otherwise use a colored rounded square with the initials, as shown.

## Fidelity
**High fidelity** for structure, copy, hierarchy, spacing, and tokens. Where a native macOS control exists (sheet, segmented control, toggle, menu, text field focus ring), use it rather than copying the HTML pixel for pixel. All data shown is sample data.

## Screens

### m1 · Models page (connected)
- The Settings window sidebar is unchanged: General, **Models**, Chat, Approvals | Extend: MCP servers, Extensions | Where it runs.
- **Header:** title "Models" (24 bold, −0.02em). Subtitle "2 providers · 399 models · $0.47 this month" (13.5, `fg2`). Primary button **"+ Add provider"** on the right (30 tall, capsule, `inv` fill). This is the only add entry point on the page.
- **Connected** section (13 semibold label + grouped card, radius 12, inset dividers starting at 62):
  - Row: 34pt tile (radius 9), name (14 semibold), green status dot, optional **"Custom"** badge (18 tall, `chip`, 10.5 semibold).
  - Subtitle (12, `fg3`): kind · auth · model count, e.g. "Cloud · API key · 396 models", or a mono `localhost:4000` · "This Mac · 3 models".
  - Right side: this month's spend (13.5 semibold) over "this month" (11), or "Free / runs locally". Then a chevron.
  - **The whole row pushes the provider detail (m6).** There are no inline Replace or Remove buttons.
  - Status dot: green = OK, amber = key expired or rate-limited, red = unreachable. A non-green row shows the reason in its subtitle.
- **Detected banner** (only when something is found and not added): `yolkSoft` card, radius 12. Title "Ollama is running on this Mac", subtitle mono `localhost:11434` · "3 models · free, nothing leaves your Mac". Actions: "Not now" (text) and **Add** (`inv`). "Not now" dismisses it per provider, persisted.
- **Default model** section: the header has a right-aligned hint, "Any chat can still switch". It is a grouped card with one row per mode: Build sessions / Chats and notebooks / Quick Chat / New agents. Each row has a capsule menu showing "Model · Provider" (provider in `fg3`), which opens the existing model picker filtered to connected providers.
- **Footer note:** "Billed to your own accounts. Keys stay in the macOS Keychain." (12, `fg3`).

### m0 · Models page (nothing connected)
- An amber dot appears next to "Models" in the Settings sidebar.
- Centered `EmptyState`:
  - 64pt round chick with a 6pt `yolkSoft` ring.
  - Title "Connect a model to get started" (22 bold).
  - Body "Piopio uses your own accounts. Pick one; you can add more later."
- Three option rows (radius 12):
  1. **OpenRouter** with a "Recommended" accent label and the decision halo (1px `accentLine` + 4px `accentSoft` ring): "One key, 300+ models from every lab", **Connect** (accent).
  2. **ChatGPT subscription**: "Sign in; usage counts against your plan", Sign in.
  3. **Ollama**, only if detected (`yolkSoft`): "Found on this Mac · 3 models · free and private", Add.
- Links below: "Browse all providers…" and "Custom endpoint…".

### m2 · Add provider sheet (catalog)
- Sheet 800×620, radius 16.
- **Header row:** "Add a provider" (17 bold), search field "Search 43 providers", Cancel.
- **Left category list** (190 wide, 13pt rows, count in `fg3`): Suggested · Cloud APIs 24 · Subscriptions 2 · Cloud platforms 4 · Local & self-hosted 6. Pinned at the bottom, below a divider: **"+ Custom endpoint"** in accent.
- **Right pane (Suggested):**
  - **On this Mac:** a 2-column grid. Detected but not added appears as a `yolkSoft` card with Add. Already added shows "✓ Added".
  - **Popular:** a 3-column card grid (radius 12): tile, name (13.5 semibold), one-line value proposition (11.5 `fg2`), auth method (11 `fg3`): "API key" / "Sign in" / "AWS credentials".
  - **Connected providers stay visible** with "✓ Connected", so the catalog doesn't shift.
  - **Bottom card:** "Don't see yours?" / "Any OpenAI- or Anthropic-compatible URL: LiteLLM, LM Studio, vLLM, a company gateway" → **Custom endpoint…**
- **Search** filters across all categories by name, alias, and model family (typing "claude" shows Anthropic, OpenRouter, Bedrock, Vertex).
- Picking a provider pushes **m3** inside the same sheet ("‹ All providers" back link).

### m3 · Connect a catalog provider
- Sheet 560 wide. Back link "‹ All providers".
- Header: 44pt tile, name (19 bold), one line about who bills you.
- **API key** field (36 tall, mono). It validates after paste, debounced at about 400 ms, by calling the provider's models endpoint.
  - Success: green "✓ Valid", plus the field's focus halo.
  - Error: red inline text, e.g. "This key was rejected (401)".
  - Helper text: "Stored in your Keychain. Create a key at console.anthropic.com ›".
- **Model preview** card (`chip`): "9 models available" plus the first 3 as chips and "+6".
- **Overlap checkbox**, shown only when another connected provider serves the same models: "Prefer Anthropic over OpenRouter for Claude models". This sets the routing preference.
- Footer: Cancel / **Connect** (accent). Connect stays disabled until the key validates.
- OAuth providers (ChatGPT) replace the key field with a "Sign in with OpenAI" button and a browser flow. Cloud platforms (Bedrock, Vertex) show their own credential fields (region, profile / project).

### m4 · Custom endpoint
- Sheet 600 wide. Title "Custom endpoint", subtitle "Any server that speaks the OpenAI or Anthropic API".
- **"Start from" preset capsules:** LM Studio · LiteLLM · vLLM · llama.cpp · Blank. A preset fills the name, URL, port, and format:
  - LM Studio: `http://localhost:1234/v1`, OpenAI
  - LiteLLM: `:4000/v1`
  - vLLM: `:8000/v1`
  - llama.cpp: `:8080/v1`
- **Form** (grouped card, 110pt label column):
  - **Name**
  - **Base URL**: mono. Probed live while typing (debounced) with `GET {base}/models`. The right side shows "● Reachable · 82 ms" (green) or the error state (m5).
  - **API format**: segmented "OpenAI-compatible | Anthropic".
  - **API key**: "Optional", placeholder text set from the probe result.
  - **Advanced ›** (disclosure): custom headers (key/value list), timeout, context-window override.
- **"Found N models"** list: mono model id, context size, and a visibility toggle. Embedding-only models are detected and **off by default**, marked "Embeddings · hidden".
- Footer: "Runs on your network · free" (12 `fg3`) · Cancel · **Add provider** (accent).

### m5 · Endpoint errors
Errors replace the URL row's status with "● Can't connect" (red) and a red 1px inner border. A help block below the row gives a plain-language reason and actions:
- Connection refused: "Nothing is listening on port 1234. Is LM Studio's server running? In LM Studio: **Developer › Start server**." Buttons: Try again, Add anyway. The hint is specific to the preset.
- 401/403: "The server wants an API key." Focus moves to the key field.
- 404 on `/models`: "Reachable, but no model list. Did you mean …/v1?", with a one-click fix that appends `/v1`.
- 0 models: "Connected, but no models are loaded on the server."
- TLS or certificate error: "The certificate isn't trusted." Offer "Trust for this host" under Advanced.

### m6 · Provider detail (pushed page inside Settings)
- Back link "‹ Models". Header: 48pt tile, name (22 bold), status line "● Connected · checked 2 min ago · Custom, OpenAI-compatible". Action: **Test connection**.
- **Connection card** (120pt label column, trailing accent text action on each row):
  - Name → Rename
  - Base URL → Edit (custom only)
  - API key: masked mono · "Keychain" → Replace
  - Headers → Add
- **Models card:** the header reads "Models · 3 shown in the picker" with "Refresh list". Each row: mono id, context size, a usage note in accent ("Default for Quick Chat"), and a visibility toggle. For providers with large catalogs (OpenRouter, 396 models), add a search field plus a "Show only…" filter above the list.
- **Spend:** cloud providers show the month's spend and a link to the provider's billing page. Not shown in the custom example.
- **Footer** (top hairline): an impact note in `fg3`, then **Remove provider…** (`chip` fill, red text). The note says what will change, e.g. "Used by Quick Chat. Removing it switches Quick Chat to Claude Haiku 5.5." Removing asks for confirmation in a native alert and deletes the Keychain item.

## Interactions & behavior
- **Detection.** On opening Settings, and every 60 s while it's open, probe the known local ports in parallel with a 300 ms timeout each: Ollama 11434, LM Studio 1234, LiteLLM 4000, vLLM 8000, llama.cpp 8080. Matches that aren't added show up in m1's banner and m2's "On this Mac" section.
- **Validation is always live and never blocks typing.** Primary buttons are enabled only after a successful check, except "Add anyway".
- **Removing a provider** reassigns any default model that used it to the first available model, and the confirmation states which defaults will change.
- **Model picker:** only shows models from connected providers with visibility on. Custom providers group under their user-given name.
- **Keyboard:** ⌘, opens Settings; in the sheet, ⌘F focuses search, ↩ activates the primary button, Esc cancels.

## State / data model
```swift
enum ProviderKind { case cloudAPI, subscription, cloudPlatform, local, custom }
enum APIFormat { case openAI, anthropic }

struct ProviderConnection: Identifiable {
  let id: UUID
  var catalogID: String?          // nil for custom
  var name: String
  var kind: ProviderKind
  var baseURL: URL?
  var format: APIFormat
  var hasKey: Bool                // secret lives in the Keychain
  var headers: [String: String]
  var status: Status              // .ok, .warning(String), .error(String)
  var lastChecked: Date?
  var models: [ProviderModel]     // id, contextWindow, isEmbedding, visible
  var monthSpend: Decimal?
}

struct DetectedEndpoint { preset, url, modelCount, dismissed: Bool }

struct ModeDefaults { build, chat, quickChat, newAgents: ModelRef }  // ModelRef = providerID + modelID

routingPreference: [modelFamily: providerID]
```

## Design tokens
These are the same tokens as `docs/design/README.md` / `Design.swift`, plus the brand `yolkSoft`.

| Token | Light | Dark |
|---|---|---|
| win | #fdfdfc | #1a1a1c |
| glass | rgba(242,242,246,.78) | rgba(40,40,44,.85) |
| card | #ffffff | #242426 |
| chip | rgba(0,0,0,.045) | rgba(255,255,255,.08) |
| pill | rgba(255,255,255,.9) | rgba(74,74,78,.95) |
| fg / fg2 / fg3 | #1d1d1f / #5b5b61 / #8e8e93 | #f5f5f7 / #b8b8bd / #8e8e93 |
| line | rgba(0,0,0,.08) | rgba(255,255,255,.12) |
| inv / invfg | #1d1d1f / #fff | #f5f5f7 / #1d1d1f |
| accent | system accent (#0a84ff) | same |
| accentSoft / accentLine | accent 14% / 45% | 26% / 60% |
| green / amber / red | oklch(.60 .15 150) / (.72 .15 70) / (.60 .19 25) | same |
| yolkSoft (brand) | oklch(.97 .04 92) ≈ #FDF7E1 | oklch(.30 .05 92) |
| scrim (behind sheets) | rgba(30,30,35,.28) | rgba(0,0,0,.5) |

- **Type (SF Pro / SF Mono):** 24 bold page title · 22 bold detail title / empty state · 19 bold sheet sub-page title · 17 bold sheet title · 14 semibold row title · 13 UI · 12 secondary · 11 semibold `fg3` section labels · SF Mono 12.5 for URLs, keys and model ids.
- **Radii:** sheet 16 · cards 12 · tiles 8–12 · fields 9 · capsules.
- **Spacing:** 4pt grid. Card rows 10–13 vertical padding, 14–16 horizontal. Section gap 18–22.
- **`yolkSoft` is brand-only.** Here it marks "detected on this Mac" items and the empty-state ring.

## Files
- `Piopio Settings Models.dc.html`: all screens (m0–m6) plus the rationale header.
- `before/settings-providers-today.png`: the current screen, for comparison.
- `assets/chick.png`: the app icon art, used in the empty state. Use the existing app icon asset.
- `support.js`: the runtime needed only to open the HTML locally.

## Suggested implementation order
1. Data model: `ProviderConnection`, Keychain storage, and migration of existing providers.
2. m1 connected list plus Default model card, with m0 as its empty state.
3. m6 provider detail: move Replace and Remove out of the list rows.
4. m2 catalog sheet and m3 key flow (reuse the existing provider metadata).
5. m4/m5 custom endpoint: live probe, presets, model discovery.
6. Local detection banner.
