# 33 · Piopio Server: your cloud on a machine you choose

Status: draft 2026-11-21; **decided by the user the same day (§11, PS1–PS8, every recommendation accepted)**; not built.
It adds a second kind of cloud to 30 (the cloud target): besides your Cloudflare Worker, **a Piopio Server**, the
engine running headless on a machine you rent or already have. The user's requirement for it, in their words: its
deployment must be **very** simple. §4 weighs the options against that.

## 1. Why

- **One container covers every cloud.** AWS, Google Cloud and Azure have nothing like a Durable Object (an actor
  with its own SQLite, an alarm, hibernating sockets and a URL in one thing). A native port to each would mean four
  or five services, IAM, a deploy flow of its own and a test matrix, all to rebuild what the Worker already does.
  The people who need "it runs in our AWS" can run a container on a VM there (§7).
- **The engine is already portable.** The Mac's engine is a Node process. It runs `AgentCore` on `node:sqlite`
  (`runtimes/agent.ts`), reads Telegram by polling (`channels/manager.ts`), and hosts chats and Build sessions. A
  server is that engine with a network front door, its own secret store and a Dockerfile. It isn't a rewrite.
- **It does what the Worker can't** (§3): subscription models, local MCP servers, coding agents, a real browser,
  and Build on a disk that stays. That makes 30's K7 (Build in the cloud) much cheaper on a server than on
  Cloudflare's containers.
- **Your data on your machine.** A rented box in the region you pick, a home server or a Mac mini. That fits X1 (no
  Piopio-hosted backend) and "local by default".
- **Orca does the same** (research/orca.md): a "Remote Orca Server" that keeps going while the laptop sleeps.

## 2. What it is

- **`piopio-server`:** the engine (`Engine` from `packages/engine`) without the app. It listens on HTTP and
  WebSocket instead of the Mac's Unix socket, and it serves **the Worker's routes** (`/v1/health`, `/v1/agents`,
  `/v1/ws?agent=…`, `/v1/channels/…`, `/v1/oauth/callback`). The Mac's `CloudLink` connects to it as it connects
  to a Worker: K1's "Advanced" connection already takes an address and an owner token.
- **One image** for `linux/amd64` and `linux/arm64`, with everything it keeps in one volume (`/data`, the
  engine's `PIOPIO_HOME`). Every way of deploying it (§4) runs this image, and the same engine runs natively on a
  Mac.
- **In the app it's a place like the Worker:** the location chip still says `Cloud`. Settings › This Mac & cloud
  says which cloud it is (`Cloudflare · piopio-cloud` or `Server · hel1 · 4 GB`), and the toolbar subtitle reads the
  same as 30 §7 ("keeps going with your Mac off").

## 3. What it can do, next to the Worker

| Capability | Cloudflare Worker (30 §4) | Piopio Server |
|---|---|---|
| **Models** | API-key providers only | API-key providers; **subscription sign-ins** once §11 PS7 is settled |
| **Memory, automations, messages** | Yes, woken by the object's alarm | Yes, the engine's own timers (the process is always up) |
| **Web search and fetch** | Yes | Yes |
| **Connectors** | Remote MCP servers, OAuth back to the Worker | Remote ones the same way, **plus local (stdio) MCP servers** running on the server |
| **A browser** | Browser Run, paid by the hour | **Chromium with Playwright in the image**, profiles on the disk, Live View through the app (to design) |
| **Code, files, Build** | A container per session, fresh disk after sleep | **The server's disk:** clones and worktrees stay, toolchains stay installed, nothing is lost when idle |
| **Coding agents** (31) | No | Claude Code, Codex and Antigravity CLI, if their plans allow it on a server (PS7) |
| **Mac apps** | Through the Mac Bridge | The same Mac Bridge (30 §5): the Mac dials out to the server |
| **Channels** | Telegram, WhatsApp, Slack by webhook | Telegram **by polling** (no inbound port needed); WhatsApp and Slack by webhook, which needs public HTTPS (§5) |
| **Phone app** (30 §6) | The gateway on the Worker | The same gateway routes on the server |
| **What you look after** | Nothing | Disk, updates (one click, §6.3), backups (§6.4) |

**The Worker is still the "I don't want to run anything" choice.** The server is for people who want more of what
the Mac can do while the Mac is off, or want it on their own machine.

## 4. Deploying it: the options, weighed

**What "very simple" means here:**
- No terminal for the default path, no config file, no domain to buy, no DNS.
- At most one thing pasted (a token), as with Cloudflare today.
- About three minutes from "Set up" to a connected server.
- Updating is one button in the app, and removing it is one button that also stops the bill.

| | Option | What you do | What you need | Simple? | Verdict |
|---|---|---|---|---|---|
| **A** | **Rent one from the app** | Settings › This Mac & cloud › Cloud › Server › **Rent one…**: pick a provider, paste its API token (an Open button goes to the token page), keep the suggested region and size, wait. The app creates the machine, which installs itself on first boot (cloud-init), gets a certificate (§5) and pairs. | An account with a VPS provider; a few euros a month (to check) | **Most:** the same shape as the Cloudflare connect the user already knows | **The default.** Hetzner Cloud first (cheap, EU regions), DigitalOcean second |
| **B** | **Use a machine you have, over SSH** | **Add a machine…**: its address and user. The app uses your SSH keys (`~/.ssh`, the agent), checks the system, asks before installing Docker if it's missing, starts the image as a service and pairs. On a Mac it installs the engine natively with a launch agent. | A Linux box or a Mac you reach by SSH with a key; root or passwordless sudo | High for people who have a server; needs SSH | **Second.** Covers VPSs anywhere, VMs on AWS, Google and Azure, a home server, a Mac mini |
| **C** | **One command** | Copy the command the app shows (`docker run …` with the volume and ports), run it anywhere. The server prints a **pairing code and a QR code**; Connect a server › paste the address and the code. | Docker | Medium: one terminal step | **The base.** A and B use exactly this; it's also the path for NAS boxes (Synology, Unraid), PaaS and anything else |
| D | One-click PaaS templates (Railway, Render, Fly, DigitalOcean App Platform) | A Deploy button in the README | An account on that platform | High, but each platform differs: volumes, always-on pricing, some sleep when idle (which breaks "always on"), no shell for Build's toolchains | **Later**, and only if asked for. Each template is one more thing to keep working |
| E | Another Mac as the server | On a second Mac with Piopio: Settings › **Serve my other Macs** | A Mac that stays on | Very, for Mac owners | **Later**, as a setting over B's native install; reaching it from outside the home network needs §5's choices anyway |
| F | Marketplace images (AWS AMI, Google Cloud image, Azure template) | Launch from the marketplace | A big-cloud account, IAM | Low | **No.** B and C on a VM cover those clouds (§7) |

**Decided (PS3): build C first, then A, then B.** C is the image, the pairing code and Connect a server, which the
other two use as they are. A is what the app offers by default, because it's the only path with no terminal, no
server and no domain. B follows for people who already run a machine.

### 4.1 What Rent one does, step by step

1. **Token:** the provider's API token (read and write on servers), kept in the Keychain to update and remove the
   server later, like `CLOUD_CLOUDFLARE_TOKEN` today.
2. **Machine:** one recommended size (2 vCPU, 4 GB, 40 GB disk; enough for agents, chats and a Build session) and
   the region nearest to you. "Change" shows the others with their monthly price, read from the provider's API.
3. **First boot:** cloud-init installs Docker and runs C's command with a **one-time pairing secret**. The secret
   works once, expires after 15 minutes, and is replaced by the real owner token, which the server makes and the app
   keeps in the Keychain. Nothing else is in the machine's user data.
4. **Firewall:** the provider's firewall opens 443 and 80 (for the certificate) only, and SSH only if you ask.
5. **Connect:** the app waits for `/v1/health`, pairs and shows the card: where it is, what it costs a month, what
   runs there, and **Update**, **Back up** and **Remove**.
6. **Remove:** brings the agents and conversations back to the Mac first (like 30 §9's Disconnect), then deletes
   the machine, so the bill stops. The confirmation names the machine and says it can't be undone.
   *(30 §13 as built: Disconnect doesn't bring anything back; it is refused while an agent runs there. 30 §9's
   "Bring everything back to this Mac" is the target, not built.)*

### 4.2 What the other paths share

- **Pairing:** a short code (and QR code) printed by the server on first start and shown again with
  `piopio-server pair`; it works once and expires. The phone pairs from the Mac as in 30 §6, never by this code.
- **The same card** in Settings for every path. The only difference is that Remove deletes the machine only for A;
  for B and C it stops and uninstalls the service, or says what to delete by hand.

## 5. Reaching it

Only the Mac and the phone need to reach the server. Telegram is read by polling, so most agents need no inbound
traffic. WhatsApp's and Slack's webhooks, and OAuth callbacks for connectors, need a public HTTPS address.

| Option | How | Good | Not so good |
|---|---|---|---|
| **Public HTTPS on the IP address** | The server gets a certificate for its IP address (Let's Encrypt's short-lived IP certificates, renewed by the server; to check) | No domain, no DNS, nothing else installed; webhooks and OAuth work | One open port; the owner token is all that stands at the door |
| Public HTTPS on your domain | You point a name at the server and type it in Setup | A name you recognize; certificates as usual | A DNS step |
| **Private only (Tailscale)** | Paste a Tailscale auth key; the server joins your tailnet, and nothing is open to the internet | Nothing exposed | Tailscale on the Mac and phone; WhatsApp, Slack and OAuth callbacks need a public address (Tailscale Funnel, to check) |
| Cloudflare Tunnel | A tunnel token from your Cloudflare account | No open port, a name on your zone | A Cloudflare account and a domain on it |

**Decided (PS4):** public HTTPS on the IP address by default (A sets it up by itself), your domain as an option,
and **Private only** as one switch for people who want nothing open. Cloudflare Tunnel waits.

## 6. Running it

### 6.1 Secrets
- On the Mac the engine asks the app's Keychain (`SecretBroker`'s reverse requests). The server has no app around
  it, so it keeps **its own store**: one file in `/data`, encrypted with a key the server makes on first start.
- **Model keys** go up from the Mac at setup and on Update, as K1 does for the Worker's OpenRouter key, so the
  server's key never drifts from the Mac's.
- **Connectors** sign in separately for the server, with the OAuth callback on the server (30 CT2: nothing copied
  off the Mac's Keychain).

### 6.2 Who may use it
- The owner token (the Mac), a revocable device token per phone (30 §6), channel webhooks by their own secrets,
  OAuth callbacks by state. Everything else is closed.
- Repeated bad tokens slow down and then lock the source out for a while.
- The engine runs as a non-root user in the container. Build's shell runs inside the container too, so the worst a
  session can do is limited to the server, not your Mac. On B's native Mac install the shell runs as that Mac's user,
  and Setup says so.

### 6.3 Updates
- **The server's version follows the app's** (the Engine Protocol version must match). After the app updates, the
  card shows **Update**: the server downloads the engine for that version from the GitHub release, checks its
  signature, and restarts its own process.
- The image is a thin runtime plus a small supervisor, so this works the same on every path, with no Docker socket
  and nothing to run by hand. A new image (a new Node, a new Chromium) is rare, and the card says when one is needed.

### 6.4 Backups
- **Back up** saves `/data` as one file on the Mac. The engine already backs up and restores on the Mac, so this
  reuses it.
- On A, the provider's own backups can be turned on in Setup, with their price shown.
- Leaving always offers to bring everything back to this Mac first.

## 7. AWS, Google Cloud and Azure

They're covered by **a VM with C's command, or B over SSH**, with the data on the VM's own disk. SQLite wants a
local block disk, not a network file system, and that choice rules out each cloud's serverless containers:

| Cloud | Use | Don't use, and why |
|---|---|---|
| **AWS** | EC2 (`t4g.small` or larger) or Lightsail, EBS disk | ECS/Fargate with EFS: SQLite on NFS |
| **Google Cloud** | Compute Engine (`e2-small` or larger), persistent disk | Cloud Run: it scales to zero and its volumes are Cloud Storage or NFS |
| **Azure** | A VM (`B2s` or larger), managed disk | Container Apps with Azure Files: SQLite on SMB |

**Not planned:** native backends on Lambda and DynamoDB, Cloud Run and Firestore, or Durable Functions and Cosmos
DB. Revisit only if someone needs serverless on one of those clouds and the Worker's design maps onto it cleanly.
A "Rent one" provider on a big cloud (Lightsail, say) waits too: their API credentials are heavier than a
provider's single token.

## 8. Under the hood

- **One agent host, two adapters.** The AgentDO's method handling (`packages/cloud/src/agent-do.ts`: deploy,
  export, retire, sessions, runs, pause, decide, undo, status, inbox) moves into `@piopio/runtime` as a portable
  agent host. It gets a Durable Object adapter (alarm, `ctx.storage.sql`, hibernating sockets) and a Node adapter
  (timers, `node:sqlite`, `ws`). The Mac's `runtimes/agent.ts` already does most of what the Node adapter needs.
- **The front door:** a small HTTP and WebSocket server in `packages/engine` (or a `packages/server` around it)
  serving the Worker's routes with the same auth (`packages/cloud/src/auth.ts`'s rules).
- **Chats and Build sessions** (30's K2 and K7) are, on a server, the engine's own sessions, reached over the full
  Engine Protocol with `location: "cloud"` refs through CloudLink. That's where the server gets ahead of the Worker:
  no `ConversationDO` or container orchestration to build for it.
- **Tools say where they run** (30 §8): `engine.hello` from a server reports what it serves (`browser`, `shell`,
  `localMcp`, `subscriptions`…), so `AgentCore` offers the same tool list on the Mac, on the Worker and on a server,
  each with what it can reach.
- **The image:** Node with `node:sqlite`, git, Python, Chromium with Playwright, the engine and its supervisor.
  Language toolchains beyond those are installed by a session when a project needs them, and stay on the disk.
- **One cloud at a time** (PS6): the app connects either a Worker or a server.

## 9. What you see

- **Settings › This Mac & cloud › Cloud** offers two cards before anything is connected: **Cloudflare** ("Nothing to
  run. Agents and chats; free to try, $5 a month for daily use") and **Your own server** ("Also Build, a browser and
  local tools. A few euros a month, or a machine you have"). Each card says in one line what it can't do.
- **Your own server** opens on Rent one (A), with "Use a machine I have" (B) and "Run it myself" (C) beneath it.
- After connecting, the card from §4.1. The rest of the app (badges, the location chip, Keep it always on) is 30's,
  unchanged.

## 10. Phases

| Phase | What | Shows it works |
|---|---|---|
| **PS0** · the image and one command | `piopio-server`, the Worker's routes for agents (K1 parity), the agent host with its Node adapter, the secret store, pairing code, Connect a server, Update | An agent moved up to a server started with C keeps running its automations with the Mac off and answers on Telegram by polling |
| **PS1** · Rent one | Hetzner Cloud, then DigitalOcean; cloud-init, the IP certificate, the firewall, Remove, backups | From a fresh account: paste a token, and an agent runs on its own server about three minutes later |
| **PS2** · Over SSH | Linux with Docker, then macOS natively with a launch agent | A Mac mini at home becomes the cloud for a MacBook |
| **PS3** · More than agents | Chats and Build sessions on the server (K2 and K7 there), Chromium, local MCP, Private only (Tailscale) | A Build session continues on the server, keeps its worktree overnight and opens a PR |
| **Later** | Coding agents and subscriptions on the server (PS7), PaaS templates (D), Serve my other Macs (E), Cloudflare Tunnel, several clouds at once | |

**Where it fits:** PS0 needs only K1 (on the account) and the agent host extraction. PS0–PS1 go right after K1 on
the account, before K2 (PS8).

## 11. Decisions (2026-11-21)

The user accepted every recommendation as written.

| ID | Question | Decision |
|---|---|---|
| PS1 | Offer a Piopio Server next to the Cloudflare Worker? | **Yes**, as a second kind of cloud with the same routes |
| PS2 | Native backends on AWS, Google Cloud or Azure? | **No**: a VM with the image covers them (§7) |
| PS3 | Which deploy paths, in what order? | **C, then A, then B** (§4); D and E later; F never |
| PS4 | Default way to reach it? | **Public HTTPS on the IP address**; your domain as an option; Private only as a switch (§5) |
| PS5 | First provider for Rent one? | **Hetzner Cloud**, then DigitalOcean |
| PS6 | One cloud at a time, or a Worker and a server together? | **One at a time** for now |
| PS7 | Subscription sign-ins and coding agents on the server? | **After checking each plan's terms** for use on your own server; API keys until then |
| PS8 | Order next to 30's K2–K7? | PS0–PS1 **right after K1 on the account**, since PS3 then makes K7 cheaper than Cloudflare's containers |

## 12. Not verified

- Let's Encrypt's certificates for IP addresses: availability, lifetime, and whether Caddy or the engine renews them.
- Hetzner Cloud's and DigitalOcean's current prices, sizes and API (servers with user data, firewalls, backups).
- The image's size with Chromium and Playwright, on both architectures.
- Whether Claude, Codex and Antigravity plans allow their CLIs on a server you own for your own use (PS7).
- Tailscale Funnel for webhooks and OAuth callbacks in Private only mode.
- How much of `agent-do.ts` depends on the Agents SDK (`agents/harness/pi`, `agents/lifecycle`,
  `agents/websockets`) and how cleanly it splits into host and adapter.
- Live View for the server's Chromium (a stream to the app's pane and the phone), which Browser Run gives the
  Worker for free.
