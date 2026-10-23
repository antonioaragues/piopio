# Settings › Models: what's built

The handoff in this folder (m0–m6) is built in `apps/mac/App/Piopio/ModelsSettings.swift`, with engine support in
`packages/engine/src/{providers,models,endpoints}.ts`. Captures with the faux model are in `screenshots/`.

| Screen | Built |
|---|---|
| m1 Models page | Connected providers (whole row opens the detail page), detected-server banner with Not now (remembered), default model per mode, footer note. |
| m0 Nothing connected | Chick empty state, OpenRouter (Recommended), ChatGPT sign-in, a detected server; Browse all providers… / Custom endpoint…; amber dot on Models in the Settings sidebar. |
| m2 Add provider | Catalog sheet: Suggested (On this Mac, Popular, Don't see yours?), Cloud APIs, Subscriptions, Cloud platforms, Local & self-hosted, + Custom endpoint; search by name and model family ("claude" finds Anthropic, OpenRouter, Bedrock, Vertex…). |
| m3 Connect | API key checked live against the provider's model list (`providers.verifyKey`), model preview, Connect only after a good check; sign-in for subscriptions; cloud platforms continue to pi's step-by-step credential sheet. |
| m4 Custom endpoint | Presets (LM Studio, Ollama, LiteLLM, vLLM, llama.cpp, Blank), live probe with latency, OpenAI or Anthropic format, optional key, Advanced (headers, context window), found models with visibility toggles (embeddings hidden). |
| m5 Errors | Not listening (with the preset's start hint), wants a key (focuses the key), no model list, nothing loaded, certificate; Try again / Add anyway. |
| m6 Provider detail | Rename, Base URL, format, key (masked, Replace/Add/Sign in again), headers; models with visibility, search and filter for big catalogs, Refresh list; month spend for OpenRouter; Test connection; Remove with the defaults it changes (they move to the first model left). |

## Left out, on purpose
- **"Prefer Anthropic over OpenRouter for Claude models"** (m3): Piopio has no routing between providers; every model is picked together with its provider, so there's nothing to prefer.
- **Timeout and "Trust for this host"** (m4/m5): pi's OpenAI/Anthropic clients don't take a per-endpoint timeout or certificate override; the certificate error explains what to do instead.
- **Headers are stored in `endpoints.json`**, not the Keychain; secrets belong in the key field (the editor says so).
- Spend for providers other than OpenRouter: their APIs don't report it.
