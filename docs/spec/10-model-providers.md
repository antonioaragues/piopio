# 10 — Multi-provider model support

Requirements written by the user outside this repo and handed over on 2026-10-22 (roadmap backlog D2). Not implemented yet; the first step is the inspection in §6.

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

**Out of scope:** automatic provider fallback; several models at once for one task; intelligent model routing; several accounts for the same provider; consolidated subscription usage or billing dashboards.

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

Never silently switch to another paid provider on an error. Make clear that a ChatGPT subscription, OpenAI API billing and OpenRouter billing are separate arrangements.

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
7. **Fallbacks:** the utility model and web search use the session's provider when OpenRouter isn't connected, or say clearly that they're unavailable.
8. **Tests:** a fake `CredentialStore` and a faux OAuth provider cover login, refresh written back, logout of one provider leaving the others, model listing across providers, switching provider mid-conversation, and persistence across restart.

## References
- https://pi.dev/docs/latest/models
- https://pi.dev/docs/latest/providers
- https://pi.dev/docs/latest/sdk
- https://pi.dev/docs/latest/rpc-commands
- https://pi.dev/docs/latest/custom-provider
- https://pi.dev/changelog/releases/0.80.8
