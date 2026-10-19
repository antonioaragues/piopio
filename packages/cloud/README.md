# @piopio/cloud

The Cloud Engine: a Cloudflare Worker with `RegistryDO` + one `AgentDO` per agent (PiHarness), channel webhooks and the Engine Protocol over WebSocket. Phase 5. See [docs/spec/02-architecture.md §5](../../docs/spec/02-architecture.md).

**Today this is spike S4** ([roadmap](../../docs/spec/09-roadmap.md)): pi-durable inside a Durable Object through the Agents SDK `PiHarness`, an OpenRouter model through pi-ai, and a hibernatable WebSocket speaking a subset of the Engine Protocol.

## What's here

| Path | What |
|---|---|
| `src/index.ts` | Worker `piopio-cloud`. `GET /v1/ws?agent=<id>` → that agent's `AgentDO`. `GET /v1/health`. |
| `src/agent-do.ts` | `AgentDO`: a plain `DurableObject` with `Lifecycle.install(this).use(PiHarness).use(WebSockets)`. JSON-RPC over the socket: `engine.hello`, `engine.status`, `sessions.subscribe` / `unsubscribe` / `submit` / `abort`, and `session.events` notifications. |
| `src/models.ts` | pi-ai `Models`: OpenRouter (key from the `OPENROUTER_API_KEY` secret), or the faux echo model when `PIOPIO_FAUX_MODEL` is set. |
| `src/timeline/` | **Copied** from `packages/engine/src/timeline/` (builder + pi-durable adapter). Should move to `packages/runtime` so both engines share one copy. |
| `scripts/deploy.ts` | Deploy with the Cloudflare REST API and an API token (no `wrangler deploy`). |
| `test/` | Miniflare (workerd) tests of the built bundle with the faux model, the deploy script against a fake API, and an opt-in real OpenRouter test. |

Refs on the socket are `{ kind: "agent", id: <agent id>, conversationId?: <pi session id, default "1"> }`. A socket serves one agent (the one in `?agent=`).

## Develop and test

```bash
corepack pnpm --filter @piopio/cloud test
```

The tests build the bundle (`wrangler deploy --dry-run --outdir dist`, the same bundle the deploy script uploads) and run it in Miniflare. No key or account needed. The eviction test waits for the PiHarness heartbeat alarm, so the suite takes ~45 s.

Real OpenRouter (opt-in, makes a paid request):

```bash
OPENROUTER_API_KEY=sk-or-… corepack pnpm --filter @piopio/cloud test openrouter
```

Local server with the faux model:

```bash
cd packages/cloud && npx wrangler dev --var OWNER_TOKEN:dev --var PIOPIO_FAUX_MODEL:1
```

Then connect to `ws://localhost:8787/v1/ws?agent=dev` and send `engine.hello` with `token: "dev"`.

## Deploy with an API token

1. In the Cloudflare dashboard, create an API token with **Account › Workers Scripts › Edit** for your account. Note the account id.
2. Make sure the account has a workers.dev subdomain (Workers & Pages shows it; first-time accounts pick one there).
3. Run:

```bash
cd packages/cloud
CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… \
OWNER_TOKEN="$(openssl rand -hex 32)" OPENROUTER_API_KEY=sk-or-… \
node scripts/deploy.ts
```

What it does, all with `Authorization: Bearer <token>`:

1. `GET /accounts/:id/workers/services/piopio-cloud` reads the deployed DO migration tag, so only newer migrations are sent (same rule as wrangler).
2. `PUT /accounts/:id/workers/scripts/piopio-cloud` (multipart): the bundle as ES modules, plus metadata with the compatibility date/flags, the `AGENT` Durable Object binding, the `new_sqlite_classes` migration and `keep_bindings: ["secret_text"]` so redeploys keep secrets.
3. `PUT …/scripts/piopio-cloud/secrets` for each of `OWNER_TOKEN` and `OPENROUTER_API_KEY` that is set. Omit them on redeploys to keep the current values.
4. `POST …/scripts/piopio-cloud/subdomain` enables `https://piopio-cloud.<subdomain>.workers.dev`, then `/v1/health` is polled.

`--plan` prints the metadata and modules without calling the API. `--skip-build` reuses `dist/`. `PIOPIO_DEFAULT_MODEL=openrouter/<model>` is sent as a plain-text var.

**Not yet run against a real account.** The request shapes are checked against a fake API (`test/deploy.test.ts`) and follow wrangler's own upload. The first real deploy is the remaining S4 step.

## What spike S4 learned

Versions: `agents` 0.28.1, `@earendil-works/pi-durable` 1.3.0, `@earendil-works/pi-ai` 1.3.0, wrangler 4.151.1 (Miniflare 5 beta, workerd 1.20261012.1). Verified locally in workerd via Miniflare, 2026-10-19.

- **PiHarness works on a plain Durable Object.** No `Agent` class needed: `Lifecycle.install(this).use(harness).use(webSockets)`. pi's tables live in the object's SQLite under a `pi_` prefix. The factory runs once per isolate start; the default model is passed as `{ provider, id }` and resolved against the factory's `Models` on every request.
- **Hibernation needs the `no_nodejs_global_timers` compatibility flag.** With `nodejs_compat`, `setTimeout` returns Node-style timers whose `unref()` does nothing in workerd. pi-durable keeps an `unref`'d 10-minute timer (idle-document sweep) and trusts `unref()` to make it harmless. In workerd, the timer pins the object in memory: it never hibernates, and Miniflare refuses to evict it ("still has active references"). Without Node global timers, pi-durable sees no `unref` and takes its documented Workers path (sweep at commit time, no timer). The idle object then has zero pending timers. Worth reporting upstream. (Alternative: `settings.documentRetentionMs: 0`.)
- **Hibernation + wake on a WS message: works.** Tested with `unsafeEvictDurableObject(…, { webSockets: "hibernate" })`. The socket stays open, the next message starts a new instance, and subscriptions come back from the connection attachment (`connection.setState`). pi's event streams are memory-only, so after every wake the object reopens them and sends each subscriber a `resnapshot`. Sequence numbers continue because they are persisted in the attachment on every batch. Socket attachments are size-limited, so the subscription list per socket must stay small.
- **Alarm-driven resume after eviction: works.** A run was evicted mid-stream (`webSockets: "close"`), with no client connected afterwards. The answer was complete when a client reconnected, and an alarm had run in between. Mechanism: PiHarness keeps one Lifecycle job per busy session and awaits pi inside an alarm invocation (`trackAlarmWork`), with a 30 s heartbeat reschedule. The eviction aborted that alarm, workerd retried it right away, `onStart` reopened pi, and pi resumed the interrupted run. If the retry did not happen, the heartbeat alarm (≤ 30 s) would. Production retry timing is unverified.
- **Reconnect gets a fresh snapshot: works and is the only option.** No cursor. Every `sessions.subscribe` returns the whole timeline. Clients reset on each subscribe and on `resnapshot`.
- **The 15-minute alarm limit is not testable locally** (Miniflare doesn't enforce wall time). From the PiHarness source: one wake waits on pi for at most 10 min (`WAIT_BUDGET_MS`), then the job ends that alarm and is due again at once, so a long run spans several alarms. pi waits longer than 60 s (retry backoff, deferred polls) go to the alarm instead of an in-memory timer. Still to prove on a real account: a stream longer than 15 min survives the hand-off between alarms.
- **OpenRouter through pi-ai works unchanged in workerd, up to auth.** `openrouterProvider()` bundles and runs as is (`nodejs_compat`). With a dummy key, the request reached OpenRouter and came back `401 User not found`. That surfaced as an `error` assistant item plus a `Not answered (model_error)` system item. A real streamed answer with usage and cost needs a key: `test/openrouter.test.ts`.
- **Bundle:** 3.3 MB, 540 KB gzipped (pi-ai's model catalog is most of it). Within the Workers size limits.
- **Tooling:** wrangler 4.151 ships Miniflare 5 (beta) with a new options shape. `convertV4MiniflareOptions` bridges it, and `unsafeEvictDurableObject` gives real hibernation/eviction in tests. `@cloudflare/vitest-pool-workers` needs vitest 4 and the repo uses vitest 5, so tests drive Miniflare from Node instead.
- pi-durable commits partial answers every 100 ms (as in S1), so short faux answers arrive with no `item.delta`.

## Open items for Phase 5

- WebSocket upgrades are accepted before auth (auth is `engine.hello` inside the socket), so anyone can open a socket and wake an object. Check the owner bearer at the Worker (`Authorization` header) before upgrading.
- One socket per agent (`?agent=`). The app wants one `/v1/ws` for all agents: terminate it in a gateway (Worker or `RegistryDO`) that fans out to `AgentDO`s over RPC.
- `state.model` reports the default model, not each session's stored one.
- Move `src/timeline/` to `packages/runtime`, and validate `session.events` against the protocol schema in tests.
