# @piopio/cloud

The Cloud Engine: a Cloudflare Worker with `RegistryDO` + one `AgentDO` per agent (PiHarness), channel webhooks and the Engine Protocol over WebSocket. Phase 5. See [docs/spec/02-architecture.md §5](../../docs/spec/02-architecture.md).

**Today this is spikes S4 and S7** ([roadmap](../../docs/spec/09-roadmap.md), [Phase 5 plan](../../docs/spec/13-cloud-engine.md)): pi-durable inside a Durable Object through the Agents SDK `PiHarness`, an OpenRouter model through pi-ai, and a hibernatable WebSocket speaking a subset of the Engine Protocol.

## What's here

| Path | What |
|---|---|
| `src/index.ts` | Worker `piopio-cloud`. `GET /v1/ws?agent=<id>` → that agent's `AgentDO`, only with the owner's token. `GET /v1/agents` lists the registry (owner only). `GET /v1/health` is the one open route. |
| `src/registry-do.ts` | (K1) `RegistryDO`, one object named `registry`: the agents deployed here. An agent adds itself on deploy and leaves on retire. |
| `src/auth.ts` | The owner check at the Worker: `Authorization: Bearer <OWNER_TOKEN>`, compared in constant time; no `OWNER_TOKEN` → everything is refused (503). |
| `src/agent.ts` | (S7) `AgentHost`: `AgentCore` on the harness pi opened, memory on the object's SQLite. `AgentWake`: the Lifecycle job that wakes the agent for its schedules and lets it rest in between. |
| `src/agent-do.ts` | `AgentDO`: a plain `DurableObject` with `Lifecycle.install(this).use(PiHarness).use(WebSockets)`. JSON-RPC over the socket: `engine.hello`, `engine.status`, `sessions.subscribe` / `unsubscribe` / `submit` / `abort`, `agents.runs` / `conversations`, and `session.events` notifications. K1: `agents.deploy` / `export` / `retire` move an agent between the Mac and here (docs/spec/30 §13). |
| `src/telegram.ts` | (5.3) The agent's bot by webhook: connect by pasting the token, pair the owner with a `/start` link, a person's message and its answer, messages the agent sends on its own. The Bot API client is `@piopio/runtime`'s, shared with the Mac. |
| `src/models.ts` | pi-ai `Models`: OpenRouter (key from the `OPENROUTER_API_KEY` secret), or the faux echo model when `PIOPIO_FAUX_MODEL` is set. |
| `src/timeline/` | **Copied** from `packages/engine/src/timeline/` (builder + pi-durable adapter). Should move to `packages/runtime` so both engines share one copy. |
| `scripts/deploy.ts` | Deploy by hand with the Cloudflare REST API and an API token (no `wrangler deploy`). The steps live in the engine (`packages/engine/src/cloud-deploy.ts`), which deploys from Settings. |
| `test/` | Miniflare (workerd) tests of the built bundle with the faux model, the deploy script against a fake API, and an opt-in real OpenRouter test. `move.test.ts` and `engine-move.test.ts` (K1): deploy, export and retire on the object, and the real engine (from source) moving an agent up and back. |

Refs on the socket are `{ kind: "agent", id: <agent id>, conversationId?: "person:<contact id>" | "run:<run id>" }`, as
on the Mac. With no `conversationId` it's the owner's conversation (`person:owner`), the one the agent's runs write
to. A person's message goes through the agent as on the Mac: `/pause`, `/resume` and budget first, memory recalled
before the turn and kept after it. A run's conversation is read-only. `agents.runs` lists runs, held messages and
what's next. A socket serves one agent (the one in `?agent=`).

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

Then connect to `ws://localhost:8787/v1/ws?agent=dev` with the header `Authorization: Bearer dev`, and send
`engine.hello` with `token: "dev"`.

## Who can reach it

- **Only the owner, from the first byte.** Every route but `/v1/health` needs `Authorization: Bearer <OWNER_TOKEN>`
  at the Worker, before the request reaches a Durable Object. A WebSocket upgrade without it gets 401, so a stranger
  with the URL can't wake an agent or create objects for made-up agent ids. `engine.hello` checks the same token
  again inside the socket. Browsers can't set that header on a WebSocket; the clients are engines (Node), which can.
- **No token, no service.** A Worker without `OWNER_TOKEN` answers 503 to everything. The deploy script refuses a
  first deploy without one.
- **Test routes stay in tests.** `/__test/*` exists only where `PIOPIO_TEST_HOOKS` is set, and needs the token even
  there. The deploy script sends only `PIOPIO_DEFAULT_MODEL` as a variable and refuses `PIOPIO_TEST_*` and
  `PIOPIO_FAUX_*`.
- **Channel webhooks:** `POST /v1/channels/telegram/<agent>` is the one route without the bearer, because Telegram
  can't send it. It's checked by Telegram's secret-token header instead (see Telegram below).

## Deploy with an API token

**From the app (2026-11-19):** Settings › This Mac & cloud › Connect takes one Cloudflare API token and does all of
this itself (the engine's `src/cloud-deploy.ts`, with the Worker bundled next to the engine as `cloud-worker/`),
making the owner token and sending the Mac's OpenRouter key. The script below is the same steps by hand.

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

**First run against a real account on 2026-11-19** (below). The request shapes are also checked against a fake API (`test/deploy.test.ts`).

## On a real account (2026-11-19)

The Worker deployed with `scripts/deploy.ts` and an "Edit Cloudflare Workers" token (free plan,
`piopio-cloud.<subdomain>.workers.dev`), driven from the Mac over the socket.

- **Deploy:** the first upload, the DO migration (`none → v1`), both secrets, workers.dev and the health check all
  worked. A redeploy without secrets kept them, and kept the agent's state. Bundle: 3.86 MB, 680 KB gzipped.
- **Who can reach it:** `/v1/health` answers 200. A socket with no token or a wrong one gets 401 at the Worker. The
  test routes answer 404, and so do unknown paths. With the owner's token, `engine.hello` answers from `cloud:trial`.
- **A real model:** Claude Haiku 5.5 through OpenRouter from inside the Durable Object answered in 1.6 s, for
  $0.0009. The first attempt used an expired key, and the error came through as the answer's `error` with
  OpenRouter's message.
- **A reminder with nothing connected:** set for 09:38 UTC, it fired at **09:38:00.047**, ran, messaged the owner
  (`sent: 1`) and cost $0.0004. No client was connected between setting it and reading the runs afterwards with
  `agents.runs`, so the alarm woke the agent.
- **Found and fixed:** "remind me in 3 minutes", sent six minutes after the first message, became a time already
  past, because the model sees the clock only when a message starts something new. The tools now say what time it is
  when they refuse one (`passedText`, in `@piopio/runtime`).

- **After the fixes (same day):** the owner's conversation over the socket showed the 09:38 reminder's message, and
  the agent listed only memory, messages and schedules among its tools, no Mac apps.

**Not verified yet on the account:** a run longer than 15 minutes across alarms; what resting saves on duration
billing (the dashboard's Durable Objects usage after a day); retry timing after a real eviction.

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

## What spike S7 learned (2026-10-25): **go**

Piopio's own agent runtime (`AgentCore` from `@piopio/runtime`) runs in the AgentDO on the pi that `PiHarness` opens,
verified in workerd via Miniflare with the faux model (`test/agent.test.ts`, 3 tests; the S4 suite still passes).

- **The agent runs unchanged.** `AgentCore` takes PiHarness's pi harness, a definition from the object's storage (a
  personal-assistant default until the app deploys one) and the built-in memory provider. People's conversations are
  PiHarness sessions, so a person's turn interrupted by an eviction finishes from PiHarness's alarm, as in S4. Model ids
  in definitions are `provider:id` (`faux:echo`).
- **Memory on the object's SQLite works**, FTS5 and its triggers included (`durableSql` adapts `ctx.storage.sql` to the
  provider's synchronous `Sql`). What a person said is recalled after an eviction.
- **Schedules need our own wake.** PiHarness hands only model retries and deferred polls to the alarm; our schedules,
  reminders and outbox sleep inside pi-durable tasks, which nothing wakes once the object is gone. `AgentWake` (a
  Lifecycle job) is due at the agent's next wake, from the new `Proactivity.nextWake()` in `@piopio/runtime`, which
  computes it from the definition, the reminders and the outbox rather than from task checkpoints (a task just started
  hasn't written one yet).
- **Sleeping tasks pin the object.** The timer behind a task's `sleep` keeps the Durable Object in memory until it
  fires: an eviction waited 5 s for a reminder's timer. In production that's an agent billed for duration around the
  clock and never hibernating. So the agent **rests**:
  - **when:** 30 s after activity, if nothing runs, no conversation is busy, no client is subscribed, and the next wake
    is more than a minute away;
  - **how:** pi's in-memory side is closed (`PiHarness.dispose()`; durable state stays) and the alarm is the only timer
    left.
  - **verified:** the eviction is then immediate, and the reminder fires from the alarm at its moment, with nothing else
    touching the object, and then rests again.
- **Bundle:** 3.47 MB, 584 KB gzipped (+170 KB over S4), well under the 64 MiB limit. Under `nodejs_compat` it uses
  `async_hooks`, `diagnostics_channel`, `os`, `util`, `path` and `fs` (code paths it doesn't run).

**Gaps, for 5.1**
- **More sleeps for `nextWake()`:**
  - ~~approval expiry (24 h)~~: since 2026-11-26 a call waiting for approval is parked at pi-durable's gate with the
    24 h as its `until`, so it is one of pi's own sleeps and reaches the alarm through `onWake` (not run on Cloudflare
    yet);
  - `ask_agent` timeouts;
  - the heartbeat's budget check.
- **Real traffic:** turns go through test routes here. The protocol (`agents.*` over the socket) and channel webhooks
  come in 5.1 and 5.3.
- **Not verified on a real account:**
  - production alarm timing;
  - the 15-minute alarm limit with a long run;
  - a real model;
  - what resting saves in duration billing.
- **Upstream asks:**
  - a "next timer" from pi-durable's scheduler would make the wake generic instead of knowing our tasks;
  - with the S4 note, `unref`-less timers on Workers pin objects.

## Telegram from the cloud (5.3)

An agent's bot is read by webhook, so it answers with the Mac off.

1. **Connect:** the owner pastes the @BotFather token in their conversation with the cloud agent. It's caught before
   the model or the transcript sees it, checked with `getMe`, and kept in the object's storage. The webhook is set to
   `https://<worker>/v1/channels/telegram/<agent>` with a random secret, and the owner gets a note with a pairing link
   (`t.me/<bot>?start=<code>`, valid for an hour).
2. **Pair:** opening the link and tapping Start sends `/start <code>`: that chat becomes the owner's
   (`channels.telegram`), and Telegram their preferred channel. When Telegram opens the chat with a bare `/start`
   (the chat already existed, or the link went through a browser), the bot asks for the code, and the code sent on
   its own pairs too.
3. **Write:** a message from a known chat goes to that person's conversation, through the agent (memory, `/pause`,
   budget), with "typing…" while it works; the answer goes back to the chat. An answer still owed when the object is
   evicted is sent after the next wake.
4. **On its own:** what the agent sends a person whose preferred channel is Telegram (a reminder, a run's message)
   goes there.

**Who can reach it:** the webhook route is the one route without the owner's token: Telegram can't send it. The Worker
refuses a request without Telegram's secret header, and the agent compares it in constant time with the one it set.
Each update is handled once, by its id, because Telegram retries. Strangers get nothing (or a canned line on
`/start`), unless the definition's `unknownSenders` says otherwise.

**On the account (2026-11-19):** a new bot connected from the Mac's driver with the token pasted in the owner's
conversation; the note gave the `t.me` link. Telegram opened the chat with a bare `/start` (no code), so the first try
didn't pair: the owner sent `/start <code>` by hand, and the bot now asks for the code itself. Then:

- **Answers:** "Hi" and "Who are you" from the phone were answered in the chat by Claude Haiku 5.5 from the cloud,
  and both turns show in the owner's conversation.
- **On its own:** a reminder set over the socket for 11:24 UTC fired at **11:24:00.002**, sent 1 message for
  $0.0002, and **arrived on the phone**: the agent's message went to Telegram because it's the owner's preferred
  channel, though the request came from the socket.
- **Found and fixed:** asked who it was, the agent said it could watch for new emails and file changes. The cloud
  has no mail, folders or webhook URLs, so `watch` is now offered only where the host runs watches (the Mac), and a
  new agent's interview in the cloud sets routines by time only.

**Not yet:** approvals as inline buttons, `/pause` answered in the chat, photos and voice notes (R2). A bot read by the
cloud can't also be polled by the Mac: use a new bot for the cloud agent.

## Moving agents from the Mac (K1, 2026-11-19)

The Mac's engine connects with the Worker's address and owner token (Settings › This Mac & cloud), then moves agents
up and back over each agent's socket. What moves and how: [docs/spec/30 §13](../../docs/spec/30-cloud-target.md).

- **Deploy:** `agents.deploy` carries the definition and instructions (validated, and for this object's id only), and
  on a move the memory records, reminders and Telegram token. A deploy without `schedules` keeps the cloud's.
- **Back:** `agents.export` reads it all (nothing changes); `agents.retire` then deletes the webhook, the registry entry
  and the object's data, and leaves a marker so it refuses everything until deployed again.
- **A Worker deployed before K1** needs a redeploy (`node scripts/deploy.ts`) for the registry: its migration `v2` adds
  `RegistryDO`, and the engine says so if `/v1/agents` is missing.

## Open items for Phase 5

- One socket per agent (`?agent=`). The phone app (30 K3) wants one `/v1/ws` for everything: terminate it in a gateway (Worker or `RegistryDO`) that fans out to `AgentDO`s over RPC. The Mac's engine keeps one per agent until then.
- Move `src/timeline/` to `packages/runtime`, and validate `session.events` against the protocol schema in tests. The
  copy here is older than the Mac's: a message the agent sent on its own shows as a user item with
  "(… sent this message on its own …)", where the Mac shows the agent's outbound message.
