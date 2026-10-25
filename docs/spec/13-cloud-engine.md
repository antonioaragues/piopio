# 13 · Phase 5 plan: agents in the cloud, Telegram and WhatsApp

Status: plan, 2026-10-24. The architecture is in 02-architecture §5 (Cloud Engine) and 06-agents §5 (channels), §7
(agent-to-agent), §11 (lifecycle). This page turns them into milestones and records what changed since they were
written.

**Acceptance (from the roadmap):** two agents live 24/7 with the Mac off; Telegram and WhatsApp both work; the owner
approves from Telegram buttons; agent-to-agent works in the cloud.

## What we have to build on
- **`@piopio/runtime` is portable already.** `AgentCore` (definitions, conversations per person, memory banks,
  schedules, outbox, approvals, budget, kill switch, peers) imports only pi-durable, pi-ai, chord and typebox. The
  built-in memory provider runs on a synchronous SQL interface, which a Durable Object's `ctx.storage.sql` provides.
- **pi-durable 1.3 runs in a Durable Object**: `openDurableObjectSqliteStorage(ctx.storage)` from
  `@earendil-works/pi-durable/storage/sqlite/cloudflare`; images through `/images/cloudflare`; codemode through a
  `RemoteCodemodeSandbox`.
- **No alarm hook in pi-durable 1.3.** Schedules, the outbox and approval expiry wait with `runtime.sleep()` inside
  durable tasks. In a Durable Object that only works while the object is awake. So each AgentDO sets a Durable Object
  alarm for its next wake (next schedule fire, outbox release, approval expiry, heartbeat) and on `alarm()` opens the
  harness and calls `resume()`. A sleep whose time has passed returns at once.

## Facts checked (2026-10-24)
- **Worker size:** 64 MiB uncompressed on Free and Paid since September 2026 (the old 3 MB / 10 MB compressed limits
  are gone). pi-ai plus pi-durable plus our runtime fit.
  [Changelog](https://developers.cloudflare.com/changelog/post/2026-09-04-increased-worker-size-limit/)
- **Durable Objects on Free:** SQLite-backed objects only, 5 GB in total, 100k rows written per day. Enough to try;
  a daily-use account will want Workers Paid.
  [Limits](https://developers.cloudflare.com/durable-objects/platform/limits/)
- **WhatsApp and AI assistants:**
  - **Allowed only where the law requires it.** Since January 15, 2026, Meta allows "general-purpose AI assistants"
    on the Business Platform only where it's legally required to. The EU/EEA is one of those markets.
    [AI Providers policy](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing/ai-providers.md)
  - **Per-message charges.** From October 1, 2026, Meta charges per message for service messages, replies inside the
    24-hour window included. Templates were already charged.
    [Pricing](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing)
  - **Where that leaves us:** whether a person running their own assistant on their own number counts as an
    "AI Provider" is not spelled out. WhatsApp stays in scope for EU users, last, with this stated in its setup.
- **Telegram** is unchanged: free, one bot per agent, webhooks with a secret-token header, inline keyboards.

## Milestones
**5.0 · Spike S7: an agent in a Durable Object** (no Cloudflare account needed, runs in workerd locally)
- A `packages/cloud` Worker with an `AgentDO` that hosts `AgentCore` on DO SQLite, built with esbuild and run in
  workerd (Miniflare / `wrangler dev`), tested with `@cloudflare/vitest-pool-workers`.
- **Proves:**
  - a turn with the faux model;
  - memory recall on DO SQLite;
  - a schedule that fires through an alarm after the object was evicted;
  - a restart in the middle of a turn resumes;
  - the bundle size, and what needs `nodejs_compat`.
- **Exit:** a written go/no-go with the gaps.

**S7 result (2026-10-25): go.** `AgentCore` runs in the AgentDO on PiHarness's pi. Verified:
- memory on the object's SQLite;
- a turn interrupted by eviction finishes;
- a reminder fires from the agent's own alarm after the object rested and was evicted.

Two things the platform didn't give us:
- **The wake:** a Lifecycle job at `Proactivity.nextWake()`.
- **Rest:** a sleeping task's timer pins the object, so pi is closed between wakes.

Details and gaps: [packages/cloud/README.md](../../packages/cloud/README.md).

**5.1 · Cloud Engine core**
- **Worker routes:**
  - `GET /v1/ws`: the Engine Protocol over a hibernatable WebSocket, behind the owner token;
  - `POST /v1/channels/...`;
  - `POST /v1/triggers/...`.
- **`RegistryDO`:**
  - agents and their definition versions;
  - routing (`telegram bot → agent`, `WhatsApp phone_number_id → agent`);
  - contacts;
  - channel credentials, encrypted with `MASTER_KEY`.
- **`AgentDO`:**
  - `AgentCore` on DO SQLite;
  - the alarm scheduler;
  - the run log, cost ledger and inbox.
- **Secrets:** Worker secrets for `OWNER_TOKEN`, `MASTER_KEY` and the model provider keys. Cloud agents use API-key
  providers (OpenRouter, Anthropic, OpenAI API); subscription sign-ins stay on the Mac.

**5.2 · Set up and deploy from the app**
- **Setup:** Settings › This Mac & cloud › Cloudflare becomes a connect flow. Paste an API token (the scopes are
  listed), pick the account, and the app uploads the bundled Worker with its Durable Object migrations, bindings and
  secrets through the Cloudflare API. No wrangler on the user's Mac.
- **Agent deploy:** "Deploy to cloud" on an agent sends its definition as data (`agents.deploy`), with no Worker
  redeploy. Deploying changes shows a diff. Rollback goes to version N−1. An agent's memory comes along when it's in the
  built-in provider.
- **Live view:** the local engine proxies cloud sessions to the app (CloudLink), so the agent's Chat, Runs, Inbox and
  Memory tabs work the same.
- **Badges:** ☁︎ for cloud agents, This Mac for local ones. "Pull state" brings a cloud agent's conversations and
  memory down for debugging.

**5.3 · Telegram**
- **Bots:** one bot per agent. You paste the @BotFather token, and Piopio checks it (`getMe`) and calls `setWebhook`
  with a secret token.
- **Inbound:** sender → contact → `person:<id>`, idempotent on the update id. Unknown senders follow
  `unknownSenders` (ask the owner with buttons).
- **Outbound:**
  - Markdown converted to Telegram's HTML;
  - long replies split;
  - "typing…" while it works;
  - approvals as inline buttons (Approve / Deny);
  - `/pause` and `/resume` from the owner.
- **Later in the milestone:** photos and voice notes stored in R2 and passed as attachments.

**5.4 · Agents together in the cloud**
- **Messages between agents:** `ask_agent` and `tell_agent` become RPC calls between AgentDOs, with the same guards
  (hops, rate, trace budget) and the trace view.
- **Reaching the owner:** the Inbox and approval notifications come from the cloud to the app and to Telegram, and the
  first answer wins.
- **Budget:** monthly budgets come from the cloud ledger.

**5.5 · WhatsApp (EU users first)**
- **Setup:** a guided checklist (Meta app, WhatsApp Business account, number, permanent token), each step checked
  with a test call.
- **Routing:** one number goes to one front agent, which reaches the others with `ask_agent`.
- **Webhooks:** checked by the verify token and `X-Hub-Signature-256`.
- **Messages:**
  - free-form replies only inside the 24-hour window;
  - outside it, the approved utility template;
  - reply buttons (at most 3) for approvals.
- **Fine print:** the setup says what Meta charges, and the policy above.

## What only you can do
- **Before 5.2:** a Cloudflare account and an API token (Workers Scripts edit, Durable Objects, R2, Account settings
  read). The free plan is enough to start.
- **Before 5.3:** one Telegram bot per agent from @BotFather (a minute each).
- **Before 5.5:** a Meta developer app, a WhatsApp Business account and a dedicated phone number.
