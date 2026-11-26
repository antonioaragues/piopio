# 10 — Multi-provider model support

Requirements written by the user outside this repo and handed over on 2026-10-22 (roadmap backlog D2). P0 built 2026-10-22 (§11), with custom endpoints (P1) the same day; Settings › Models redesigned 2026-10-23 (§12); OpenRouter's live model list added 2026-10-26 (§13) and removed 2026-11-26, when pi's own `models.json` and catalog began to be followed (§14). The inspection is §9.

## 1. Background and research findings
Piopio uses pi as its agent harness but exposes OpenRouter as the only model provider. pi already implements most of what multiple providers need:

- Native integrations with OpenAI, Anthropic, Google Gemini, OpenRouter, GitHub Copilot and many more.
- API key authentication and provider-specific OAuth.
- ChatGPT Plus/Pro authentication through OpenAI Codex.
- Model discovery, provider configuration and runtime model selection.
- Switching models during an existing session.
- Custom providers and compatible local endpoints.

**Conclusion:** reuse pi's model infrastructure rather than building our own provider abstraction. This is not only a frontend change: the app must integrate authentication, model discovery, secure credential storage and session management.

**pi version:** current releases use `ModelRuntime` for SDK model and credential management. Older SDK examples using `AuthStorage` and `ModelRegistry` may be outdated. Check the installed pi version before implementing.

## 2. Requirement: support multiple model providers
**Problem.** Users are limited to OpenRouter, though pi supports many providers and authentication options. A user with OpenRouter credits and a ChatGPT Plus/Pro subscription should be able to use both without reconfiguring the app.

**Goal.** Connect several providers at once, manage their credentials, and pick models from any connected provider.

**Principles**
1. Several providers can stay connected at the same time.
2. Each session has one active model at a time.
3. Connecting a provider and selecting a model are separate operations.
4. Model capabilities and availability come from pi.
5. Provider selection and billing route are explicit.
6. Existing OpenRouter behavior stays unchanged.

## 3. Scope
**P0 — required**
- Keep OpenRouter working as it does today.
- OpenAI Codex authentication through a ChatGPT subscription.
- OpenAI API authentication with an API key.
- Several provider connections at once.
- A Model Providers settings screen (or the current Settings › Models page, extended).
- A provider-aware model picker in the chat UI.
- Switching provider/model inside an existing conversation.
- Persisted per-session model and a default model.
- Secure credential handling and actionable error states.

**P1 — more providers and capabilities**, through pi's existing integrations:
- Anthropic API, Google Gemini API, GitHub Copilot.
- xAI, DeepSeek, Z.ai, Kimi, MiniMax and other pi-supported providers.
- Local models and custom compatible endpoints.
- Model search and favorites; reasoning/thinking level; model metadata and capabilities; catalog refresh.

**Out of scope:** automatic provider fallback ([29](29-provider-order.md), draft 2026-11-18, not built, would revise this: the same model through the next provider in your order, asking before credits); several models at once for one task; intelligent model routing ([28](28-auto-model.md), draft 2026-11-18, not built, would change this: Auto, once you turn it on, picks among the models in your roles); several accounts for the same provider; consolidated subscription usage or billing dashboards.

## 4. Functional requirements
### FR1 — Provider management
A Settings › Model Providers screen. Each provider shows its name, supported authentication methods, connection status, and Connect / Manage / Reconnect / Disconnect.

States: Not connected · Connecting · Connected · Needs attention.

Connecting another provider never replaces another provider's credentials. Authentication uses pi's own facilities wherever possible, including its OAuth, browser and device-code flows. Disconnecting affects only that provider, with a warning if it supplies the model currently in use.

### FR2 — Model selection
The model picker lists models from every connected provider.
- The catalog comes from pi, never a hard-coded list.
- Models are identified by provider ID and model ID.
- Models are grouped or labeled by provider, and the billing route is clear:
  - OpenAI Codex → GPT model → ChatGPT subscription
  - OpenRouter → Claude model → OpenRouter credits
  - OpenAI API → GPT model → API billing
- The same model name through two providers stays two distinct choices.
  > 29 PO3 (draft 2026-11-18, not built) would change this: models from different providers with the same maker and the same normalized id become routes of one model.
- Switching models inside a session keeps the conversation history.
- Switching during a running turn is handled safely, without interrupting it unexpectedly.

### FR3 — Session persistence
- Reopening a conversation keeps its model.
- A separate default model for new conversations.
- Changing one session's model doesn't affect other sessions.
- Reasoning settings persist where pi supports them.
- Existing OpenRouter selections survive the migration.

### FR4 — Authentication and errors
Handle missing credentials, invalid API keys, expired OAuth, rate limits, subscription or quota limits, unavailable models and network failures.

Never silently switch to another paid provider on an error (29 PO6, draft 2026-11-18, not built, would change this: a switch only along your order, never silent, and moving to credits asks by default). Make clear that a ChatGPT subscription, OpenAI API billing and OpenRouter billing are separate arrangements.

## 5. UX requirements
**Model Providers settings:** connected accounts and available providers, with simple add, reconnect and disconnect. OpenAI offers two clearly different methods that coexist with OpenRouter:
- **ChatGPT / Codex subscription:** pi's subscription sign-in flow.
- **OpenAI API:** an API key.

**Chat model picker:** the current model and its provider are always visible. The picker shows models from connected providers, supports search and filters, tells apart similarly named models from different providers, shows provider and billing route, and restores the right choice when a session reloads.

## 6. Technical requirements
Before implementing, inspect the repo: the installed pi version and how it's integrated (SDK or RPC), how OpenRouter authentication works today, and where sessions and model preferences live.

**Reuse pi's runtime.** On modern SDK versions use `ModelRuntime`, pi's model catalog and its session APIs. Over RPC, the model commands are `get_available_models`, `get_state`, `set_model`, `get_available_thinking_levels` and `set_thinking_level`. RPC doesn't provide an OAuth connection UI, so the app needs a bridge to pi's authentication facilities.

**Credentials**
- Secure storage compatible with pi's credential system.
- OAuth refresh and provider-specific flows.
- Don't expose credentials to the frontend unnecessarily; never put secrets in frontend storage or logs.
- Isolate credentials per user if the app ever becomes multi-user.
- Refresh provider and model availability after authentication changes.

**Compatibility:** keep existing OpenRouter settings, authentication and sessions. No unnecessary custom provider abstractions; pi's model registry and runtime are the source of truth. Verify the installed pi APIs before writing integration code.

## 7. Acceptance criteria
- Existing OpenRouter setup keeps working without signing in again.
- OpenAI Codex can be connected while OpenRouter stays connected.
- OpenAI API credentials can be configured independently.
- The picker shows eligible models from several connected providers, and the same model through different providers is distinguishable.
- Switching between OpenRouter and Codex mid-conversation works and keeps the history.
- The model choice survives a session reload; a default model can be set for new sessions.
- Disconnecting one provider doesn't affect the others.
- Authentication errors come with actionable recovery.
- No automatic fallback to another paid provider.
  > 29 (draft 2026-11-18, not built) would change this: the same model through the next provider in your order, asking before credits (PO4, PO6).
- Credentials stay secure and isolated.
- Integration tests cover authentication, model selection and session persistence.

## 8. Implementation notes
Implement P0 end to end with the installed pi version, the existing architecture and current UI conventions. pi is the source of truth for provider definitions, authentication, model discovery and selection. No provider-specific networking code, no hard-coded catalogs, no changes to unrelated agent behavior. Keep OpenRouter compatible and add automated tests.

After implementing, report: what changed; which pi capabilities were reused; backend changes beyond the UI; which authentication methods were implemented; what was tested; remaining limitations and follow-ups.

**Already in place (2026-10-22):** Settings › Models (docs/design v2, 9a) has a providers card with a "ChatGPT · Coming soon" row and a default model per mode (Build, Chats and notebooks, Quick Chat, New agents); the picker (10a) groups models by maker. Both need provider-aware labels and billing routes.

## 9. Inspection (2026-10-22)

### What's installed
- pi **1.3.0** across the board: `pi-ai`, `pi-coding-agent`, `pi-durable`, `pi-agent-core` (the requirements' 0.80.8 reference predates it). Its docs ship in the package (`node_modules/@earendil-works/pi-coding-agent/docs/`).
- The engine uses pi as an **SDK** in process, not over RPC. Build sessions run pi-coding-agent; chats, notebooks and agents run pi-durable.

### How models and the OpenRouter key work today
- `ModelHub` (`packages/engine/src/models.ts`) owns one `InMemoryCredentialStore`, shared by:
  - a pi-ai `createModels()` collection with **only** `openrouterProvider()` registered (plus the faux provider in dev), used by pi-durable `Harness.open({ models })` in `runtimes/space.ts` and `runtimes/agent.ts`, by `sessions.ts` to validate model refs, and by `utility()`;
  - a lazily created `ModelRuntime` for Build sessions (`buildRuntime()`), which has every built-in provider but only ever gets the OpenRouter credential.
- The key lives in the **app's Keychain** (`provider.openrouter.apiKey`). The engine asks for it with the reverse request `secrets.get` the first time a provider is needed (`ensureCredential`) and keeps it in memory only (`secrets.ts`). `SECRET_BY_PROVIDER` maps only `openrouter`.
- `listModels()` returns OpenRouter's catalog only. `verifyProviderKey()` and `providerUsage()` are OpenRouter-specific (`/api/v1/key`).
- Model refs are already `{ provider, id }` everywhere (protocol, sessions, agents, the app's per-mode defaults), and each session stores its own model, so FR2/FR3's identity and per-session persistence need no data migration.

### What pi 1.3.0 provides (reuse, don't rebuild)
- **`ModelRuntime`** implements pi-ai's `Models` interface, so the same object can serve pi-durable (`Harness` takes `Models`) and pi-coding-agent. It has `getProviders()`, `getAvailable(providerId?)` (models whose provider has usable auth), `checkAuth`, `getProviderAuthStatus`, `isUsingSubscription`, `listCredentials`, `refresh()`, `login()`, `logout()`.
- **App-owned credential storage:** `ModelRuntime.create({ credentials })` accepts any `CredentialStore` (`read`, `list`, `modify`, `delete`). `modify` is the single serialized write path; OAuth refresh runs inside it, so a Keychain-backed store gets refreshed tokens written back.
- **Login without a terminal:** `login(providerId, "api_key" | "oauth", interaction, { agentName, getDeviceId })`. The `AuthInteraction` is two callbacks the app implements: `prompt()` (text, secret, select, or `manual_code` for pasting a callback URL) and `notify()` (events `auth_url`, `device_code`, `progress`, `info`). The ChatGPT flow runs its own callback server on localhost:1455.
- **Providers and methods** (from `getProviders()` on this install; 43 in all):

| Provider id | API key | Sign in (OAuth) |
|---|---|---|
| `openrouter` | ✓ | ✓ OpenRouter OAuth |
| `openai` | ✓ OpenAI API key | ✓ ChatGPT subscription |
| `openai-codex` (marked *legacy*) | — | ✓ ChatGPT Plus/Pro |
| `anthropic` | ✓ | ✓ Claude Pro/Max |
| `github-copilot` | ✓ token | ✓ subscription |
| `google` (Gemini) | ✓ | — |
| `xai` | ✓ | ✓ Grok/X subscription |
| `deepseek`, `zai`, `kimi-coding`, `minimax`, `mistral`, `groq`, … | ✓ | some |

### Gaps and risks
1. **One credential per provider.** pi stores a single credential per provider id, and `openai` covers both the API key and ChatGPT sign-in. P0 asks for both at once. Options: ChatGPT through `openai` plus the API key through a second provider registered with `registerProvider` (an "OpenAI API" alias over the same models), or ChatGPT through the legacy `openai-codex`. pi's docs note that while `openai` is signed in through ChatGPT, API-key-only models (such as the Decisions API) aren't listed.
2. **pi-durable only sees OpenRouter.** Chats, notebooks and agents get models from the pi-ai collection with one provider; switching them to the shared `ModelRuntime` is the core backend change.
3. **Secrets are read-only today.** `secrets.get` is the only reverse request; OAuth needs writes (login, token refresh, logout), so the protocol needs `secrets.set`/`secrets.delete`, or the engine needs its own secure store.
4. **Utility model and web search are pinned to OpenRouter** (`DEFAULT_MODEL`, `tools/web.ts`). With only ChatGPT connected, titles, commit messages, follow-ups and web search would fail; they need a fallback to whatever is connected.
5. **Usage/spend** is OpenRouter-only (`/api/v1/key`). Fine for P0 (consolidated billing is out of scope), but the providers card should show spend only where it's known.

## 10. P0 plan
1. **One runtime.** `ModelHub` builds a single `ModelRuntime` with an app-owned `CredentialStore` and hands it to pi-durable and pi-coding-agent; drop the separate pi-ai collection. Faux stays a native provider.
2. **Keychain-backed `CredentialStore`.** Each provider's credential (API key or OAuth JSON) is one Keychain item, `provider.<id>.credential`, read through `secrets.get` and written through new `secrets.set`/`secrets.delete` reverse requests. The existing `provider.openrouter.apiKey` item is read as OpenRouter's credential, so nothing is re-entered (acceptance: "works without reauthentication").
3. **Protocol:** `providers.list` (id, name, methods, status Not connected / Connecting / Connected / Needs attention, subscription or API billing, source), `providers.login` (runs `ModelRuntime.login`; streams `auth_url`, `device_code`, `progress` as notifications and asks `prompt()` questions as a reverse request), `providers.cancelLogin`, `providers.logout`. `models.list` returns every available model with its provider and billing route.
4. **OpenAI both ways:** ChatGPT subscription and OpenAI API as two separate entries, per the decision in gap 1.
5. **App:**
   - Settings › Models lists connected and available providers with Connect / Reconnect / Disconnect. Disconnect warns when the provider serves a default or an open session's model.
   - Sign-in sheet: opens the browser for `auth_url`, shows the device code with Copy, and offers a paste field for `manual_code`.
   - The model picker groups by provider and labels the billing route ("ChatGPT subscription", "OpenRouter credits", "OpenAI API").
6. **Errors:** map `ModelsError` codes (auth, rate limit, quota, unavailable model, network) to error cards with one recovery action (Reconnect, Choose another model, Try again). Never fall back to another paid provider.
   > 29 (draft 2026-11-18, not built) would change this: a request that fails before streaming is tried on the next route of the same model, asking before credits (PO4, PO6).
7. **Fallbacks:** the utility model and web search use the session's provider when OpenRouter isn't connected, or say clearly that they're unavailable.
8. **Tests:** a fake `CredentialStore` and a faux OAuth provider cover login, refresh written back, logout of one provider leaving the others, model listing across providers, switching provider mid-conversation, and persistence across restart.

## 11. Status (2026-10-22): P0 built
**Decision:** ChatGPT signs in through pi's `openai` provider; the OpenAI API key goes to a second provider, `openai-api`, registered as an alias of `openai` (same models, API key only).

**Built**
- Engine: one `ModelRuntime` for every runtime (`models.ts`), credentials in the Keychain through `KeychainCredentialStore` (`credentials.ts`) with `secrets.set`/`secrets.delete` reverse requests, the OpenAI API alias and sign-in flows (`providers.ts`), `providers.list` / `login` / `answer` / `cancelLogin` / `logout`, `providers.auth` and `providers.changed` notifications. `models.list` returns only connected providers' models, each with `providerName` and `billing`. Errors name the provider and mark it "Needs attention" on a rejected key or sign-in. Web search says it needs OpenRouter when it isn't connected; the utility model falls back to a connected provider's small model.
- App: Settings › Models lists ChatGPT, OpenAI API and OpenRouter first and every other pi provider under "More providers", with Connect, Replace key / Sign in again, Reconnect and Disconnect (warning when a default model uses it). A sign-in sheet follows pi's steps (browser page, device code, key, pasted code). The model picker gives each non-OpenRouter provider its own section titled with who bills; rows say "via ChatGPT" etc.; subscription models show "Plan" instead of a price tier; the composer chip names the provider once more than one is connected.
- The existing OpenRouter key keeps working untouched (its Keychain item is read as OpenRouter's credential).
- Tests: engine (key login through the sheet's prompt, Keychain write, both providers listed, switching a conversation's provider, restart, logout of one provider, sign-in steps and cancel, refreshed tokens written back) and Swift decoding.

**Custom endpoints (P1, built 2026-10-22)**
- Any OpenAI-compatible server — LiteLLM, Ollama, LM Studio, vLLM — added by name, address and an optional key with "Add a custom provider…" inside Settings › Models › More providers, where the ones you added and servers found on this Mac are listed first (the section opens by itself once you have one). The sheet asks `GET <address>/models` (adding `/v1` when needed) and shows what it found before saving; errors say whether the server is down, wants a key, or isn't a model server.
- Ollama (port 11434) and LM Studio (port 1234) running on this Mac are offered with one-click Add.
- Engine: `endpoints.ts` kept the list in `endpoints.json` (no secrets) and registered each as a pi provider until 2026-11-25; each is now a provider entry in pi's own `models.json` (§14). Keys are Keychain credentials like any provider's. Methods `endpoints.check`, `endpoints.save` (add or update; no key keeps the stored one), `endpoints.remove`, `endpoints.detect`.
- Picker: one section per endpoint ("LiteLLM (home) · On this Mac" / "Your server"), price tier "Yours", context "unknown" when the server doesn't report it. Endpoint models were text-only, without thinking, until 2026-11-25; see §14 for where that comes from now.

**Not verified yet**
- A real LiteLLM, Ollama or LM Studio server (tested against a fake OpenAI-compatible server).
- A real ChatGPT sign-in and real requests with real keys (needs your accounts). Captures used fake keys in a separate Keychain service (`PIOPIO_KEYCHAIN_SERVICE`).
- Switching provider while a turn is running relies on the existing `sessions.configure` behavior (the change applies to the next turn).

## 12. Settings › Models redesign (2026-10-23)
Built from the design handoff in [docs/design/models](../design/models/IMPLEMENTATION.md): the page shows only connected providers, detected servers and the default per mode; adding happens in a catalog sheet (43 providers plus custom endpoints); each provider has a detail page. New engine methods: `providers.verifyKey` (checks a key against the provider's model list; with no key, the stored one), `providers.saveKey`, `providers.models`, `providers.setHidden` (models hidden from the picker, `model-visibility.json`); endpoints gained API format (OpenAI or Anthropic), headers, context window, hidden models, "add anyway", error kinds and latency; detection covers Ollama, LM Studio, LiteLLM, vLLM and llama.cpp.

## References
- https://pi.dev/docs/latest/models
- https://pi.dev/docs/latest/providers
- https://pi.dev/docs/latest/sdk
- https://pi.dev/docs/latest/rpc-commands
- https://pi.dev/docs/latest/custom-provider
- https://pi.dev/changelog/releases/0.80.8

## 13. OpenRouter models newer than pi (2026-10-26)
> **Removed 2026-11-26 (§14).** pi now publishes a newer catalog on pi.dev and Piopio follows it, so `openrouter-live.ts` and `openrouter-models.json` are gone. What follows is how it was.

- **Why a model can be missing:** pi ships OpenRouter's models as a list fixed at its release (`pi-ai/providers/data/openrouter.json`), and its refresh only narrows that list to what your key may use. A model OpenRouter adds later never shows. Example: `deepseek/deepseek-v4.1-flash-1017` (released 17 October) wasn't in pi 1.3.0.
- **The upgrade:** pi moved to 1.4.0, which lists it. The migration:
  - durable sleeps (`sleepUntil`) for schedules and the outbox, with sleeping tasks counted as live;
  - `checkpointWhen` on the three session documents;
  - the Cloudflare Agents SDK moved to 0.30.1, so only one pi version is in the cloud bundle.
- **No more waiting for pi:** `packages/engine/src/openrouter-live.ts` reads OpenRouter's public model list (cached six hours in `openrouter-models.json`). It adds the chat models with tool calling that pi's catalog lacks:
  - **From OpenRouter:** prices, context and image input.
  - **From the catalog:** reasoning levels and compatibility flags, taken from the model of the same maker with the closest id.
  - **When:** the first model list waits for it, and Refresh in the picker forces it; otherwise a stale list updates in the background.
- **Checked on 2026-10-26:** five models on top of pi 1.4.0 (`openai/gpt-6.1-terra`, `moonshotai/kimi-k3.1-pro`, `minimax/minimax-m3.1-flash`, …). A real request through pi's runtime to `minimax/minimax-m3.1-flash` answered.

## 14. pi's own model configuration (2026-11-26)

Since the first scaffold the engine created pi's model runtime with its `models.json` and its catalog refresh switched off, without a recorded reason. Both are pi's own mechanisms, and both are on now.

- **`models.json` in pi's folder applies here too**, as it does in pi's CLI: providers it adds, a built-in provider's base URL or headers, and `modelOverrides` (a model's name, limits, cost or `compat`). It is read at start and again on Refresh.
  - A provider that only exists in `models.json` is in the runtime, but the picker still lists the providers you connected in Settings › Models (FR2: billing stays explicit). Listing those too is a separate decision.
- **Models newer than this pi come from pi's catalog on pi.dev**, for every built-in provider, not only OpenRouter. pi asks at most every four hours and keeps what it got; OpenRouter's is then narrowed to what your key may use.
  - Kept in `<home>/models-store.json`, not beside pi's own: OpenRouter's list is narrowed to the key in the Keychain, which pi's CLI may not have.
  - The first model list after a start restores the kept catalog and asks in the background; Refresh in the picker waits for it. Nothing is asked before the engine serves, in tests, or with the scripted model.
- **Checked on 2026-11-25:** pi.dev's OpenRouter catalog was a day old and lacked 3 of OpenRouter's 410 tool-calling models, all two days old or less.
- **§13's live list is removed** (decided by the user, 2026-11-26). With pi's catalog on, it only added the newest few models, with flags guessed from a sibling model. A brand-new OpenRouter model now shows a day or two later, with pi's real flags. Its cache file is deleted at start.
- **What stays from that module:** the one flag pi's OpenRouter catalog lacks for Claude (`supportsMidConvoSystemMessages`, 38 §8 R2), now alone in `openrouter-flags.ts`. Checked 2026-11-25: none of pi.dev's 32 `anthropic/*` OpenRouter entries has it. It goes when pi's catalog carries it.
- **Custom endpoints' models (2026-11-25).** Every endpoint model was registered as text-only and without thinking, whatever it was. Now, in order:
  - what the server's own model list says, where it says (OpenRouter-style `architecture.input_modalities` and `supported_parameters`);
  - what pi's catalog knows about a model with the same id, as it is or by its last part, without regard to case (a gateway serving `claude-sonnet-5` or `openai/gpt-5.5`). When several providers list it, it reads images or thinks only if all of them say so. Its output limit comes from there too;
  - otherwise text only, without thinking, as before.
  - Not done: asking each kind of local server for a model's abilities (Ollama's `/api/show`, LM Studio's `/api/v0/models`), which would be Piopio-only code per server; and switches for images and thinking in the endpoint's page.
- **Custom endpoints are providers in pi's `models.json` (decided by the user, 2026-11-25).** Piopio's own `endpoints.json` is gone: Settings › Models writes the endpoint's provider entry (`name`, `baseUrl`, `api`, `headers`, `models`) into the `models.json` in pi's folder, and pi reads it itself. Nothing is registered by hand any more.
  - **The same servers are in pi's CLI.** One that wants no key works there at once (`apiKey: "none"`, pi's own convention). One with a key has it in Piopio's Keychain, never in the file, so pi's CLI needs its own (`/login` or `auth.json`).
  - **The file is yours too.** Piopio edits it in place with a comment-preserving editor (`jsonc-parser`): only the endpoint's own entry is written, and comments, formatting and other providers stay. A file with an error is never written over: saving says so.
  - **Your corrections hold.** A model already in the entry keeps it as it is when the endpoint is checked again; only new models are added, models the server dropped go, and a context size the server reports or you set replaces the old. To change what a model can do, edit its entry (`reasoning`, `input`).
  - **A provider you wrote there by hand** is listed in Settings › Models and in the picker like one added there (the gap §14 left open above). The rule is pi's: an entry with an address, an API and its own models.
  - **Existing endpoints moved once**, at the first start: each went into `models.json` unless that id was already there, and `endpoints.json` was renamed `endpoints.json.migrated`. Removed 2026-11-26 with the other alpha migrations: an `endpoints.json` left now is ignored.
  - **What changed for you:** a model whose context size the server doesn't report shows pi's default (128k) instead of "unknown"; the "assumed context" you set is each model's `contextWindow`, not a setting of the endpoint; embedding models aren't listed.
  - **Not verified:** a real Ollama, LM Studio or LiteLLM, and the migration on your own `~/.pi/agent/models.json`.
