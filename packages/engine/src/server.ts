/** Local Engine: Engine Protocol over a Unix domain socket. */
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { join, resolve } from "node:path";
import { appendFileSync, existsSync, unlinkSync, chmodSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { createServer, type Server } from "node:net";
import { CALL_TIMEOUT_MS, methods, PROTOCOL_VERSION, reverseMethods, SLOW_METHODS, type MethodName, type Params, type Result } from "@piopio/protocol";
import { Value } from "typebox/value";
import { EngineError, ModelHub } from "./models.js";
import { activity } from "./activity.js";
import type { PiopioRead } from "./app-manifest.js";
import { ensureDirs, loadOrCreateToken, type EnginePaths } from "./paths.js";
import { socketAnswers } from "./lock.js";
import { MethodNotFound, RpcConnection } from "./rpc/connection.js";
import { handlersFor } from "./handlers/index.js";
import type { AllHandlers, Handler } from "./handlers/types.js";
import { SecretBroker } from "./secrets.js";
import { LoginFlows } from "./providers.js";
import { ConnectorHub } from "./connectors/hub.js";
import { choices } from "./connectors/permissions.js";
import type { ConnectorEndpoints } from "./connectors/types.js";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { McpConfig, type RawServer } from "./mcp.js";
import { McpStatus } from "./mcp-probe.js";
import { Projects } from "./projects.js";
import { Sessions } from "./sessions.js";
import { AboutMe } from "./about-me.js";
import { Settings } from "./settings.js";
import { notInChat } from "./tools/mcp-chat.js";
import { ChatResources } from "./tools/chat-resources.js";
import { Packages } from "./packages.js";
import { MemoryProviders } from "./memory.js";
import { AgentFiles } from "./agent-files.js";
import { DEFAULT_HOOKS_PORT, Hooks } from "./hooks.js";
import type { SpendRange } from "@piopio/protocol";

import { AppServices } from "./app-services.js";
import { BrowserSites } from "./tools/browser-tools.js";
import { TelegramChannels } from "./channels/manager.js";
import { AgentWatchers } from "./watchers.js";
import { Automations } from "./automations/service.js";
import { Library } from "./library.js";
import { Apps } from "./apps.js";
import { fromProjects, REPORT_FILE as AUTOMATIONS_REPORT, reportOf as automationsReport, type LegacyPlace } from "./automations/migrate.js";
import { WorkRunner } from "./work/runner.js";
import { migrateTeams, needsMigration } from "./work/migrate.js";
import { Watchdog, type WatchdogOptions } from "./watchdog.js";
import { WakeWatch } from "./wake.js";
import { GitHub, type GitHubOptions } from "./github.js";

/** Set by the release bundle (scripts/bundle.mjs); "dev" when running from tsc output. */
declare const PIOPIO_ENGINE_VERSION: string | undefined;
export const ENGINE_VERSION = typeof PIOPIO_ENGINE_VERSION === "string" ? PIOPIO_ENGINE_VERSION : "dev";

export type EngineOptions = {
	/** Production process shutdown for offline backup/restore. */
	onShutdown?: () => void;
	paths: EnginePaths;
	faux?: boolean;
	piSessionDir?: string;
	piAgentDir?: string;
	/** Follow pi's model catalog on pi.dev (models newer than this pi). The app's engine turns it on; tests don't. */
	remoteCatalog?: boolean;
	/** Where deleted build session files go (tests); default ~/.Trash. */
	trashDir?: string;
	/** Where agent folders go (tests); default ~/Piopio/Agents or PIOPIO_AGENTS_DIR. */
	agentsDir?: string;
	/** How long ask_agent waits for another agent (tests); default 10 minutes. */
	agentAskTimeoutMs?: number;
	/** Tests: learned facts with a scripted utility model (docs/spec/14-memory M2). */
	agentLearn?: Sessions["agentLearn"];
	/** The webhook triggers' port (0: any free one, tests); default PIOPIO_HOOKS_PORT or 47615. */
	hooksPort?: number;
	/** Let web_fetch read localhost (tests). */
	allowPrivateFetch?: boolean;
	/** Where connected apps sign in and call their APIs (tests point them at a fake server). */
	connectorEndpoints?: ConnectorEndpoints;
	/** Where teams kept their folders before docs/spec/26, read once by the migration; default ~/Piopio/Teams or PIOPIO_TEAMS_DIR. */
	teamsDir?: string;
	/** The Watchdog's thresholds (tests: seconds, not minutes). */
	watchdog?: WatchdogOptions;
	/** GitHub (tests: a fake API and token, and how often PRs are polled; default every 2 minutes). */
	github?: GitHubOptions & { pollMs?: number };
	/** Event routines (tests: check mail and settle folders sooner). */
	watchers?: { mailEveryMs?: number; settleMs?: number };
	/** Telegram's API (tests: a fake one) and how long a poll waits. */
	telegram?: { fetch?: typeof fetch; pollSeconds?: number; retryMs?: number };
	/** Tests: how the engine reaches your cloud (a fake fetch, a WebSocket to Miniflare). */
	cloud?: { fetch?: typeof fetch; webSocket?: (url: string, token: string) => WebSocket; workerDir?: string; healthRetryMs?: number };
	log?: (line: string) => void;
};

import { InputReceipts } from "./requests.js";
import { CloudLink } from "./cloud.js";

export class Engine {
	private readonly inputReceipts: InputReceipts;
	readonly id = randomUUID();
	readonly secrets = new SecretBroker();
	cloud!: CloudLink;
	private cloudTick?: NodeJS.Timeout;
	readonly logins: LoginFlows;
	readonly hub: ModelHub;
	readonly connectors: ConnectorHub;
	readonly sessions: Sessions;
	readonly projects: Projects;
	readonly mcp: McpConfig;
	readonly browserSites: BrowserSites;
	readonly settings: Settings;
	readonly aboutMe: AboutMe;
	readonly mcpStatus = new McpStatus();
	readonly packages: Packages;
	readonly chatResources: ChatResources;
	readonly memory: MemoryProviders;
	readonly hooks: Hooks;
	readonly telegram: TelegramChannels;
	readonly watchers: AgentWatchers;
	readonly work: WorkRunner;
	readonly automations: Automations;
	/** Apps (docs/spec/35 §14): pages that read their data from files. */
	readonly apps: Apps;
	/** The apps each client has open, closed with it. */
	appOpens = new Map<RpcConnection, string[]>();
	readonly watchdog: Watchdog;
	/** Notices the Mac waking from sleep (wake.ts): what runs on timers or open connections catches up. */
	readonly wake = new WakeWatch();
	readonly github: GitHub;
	private prTimer?: NodeJS.Timeout;
	private readonly teamsDir: string;
	private readonly agentDir: string;
	readonly app = new AppServices();
	usageCache?: { at: number; value: Result<"usage.summary"> };
	private server?: Server;
	private token = "";
	subscriptions = new Map<string, () => void>();
	/** Subscriptions by conversation, so they follow it when its runtime is replaced (a switch to or from a coding agent, docs/spec/31). */
	rebinders = new Map<string, { refId: string; rebind: () => Promise<void> }>();
	authed = new Set<RpcConnection>();
	/** Resolves when older threads are indexed for search (tests wait on it). */
	backfill: Promise<number> = Promise.resolve(0);
	readonly startedAt = Date.now();
	private readonly log: (line: string) => void;

	constructor(readonly options: EngineOptions) {
		this.log = options.log ?? ((line) => process.stderr.write(`${line}\n`));
		ensureDirs(options.paths);
		this.inputReceipts = new InputReceipts(join(options.paths.home, "requests.db"));
		this.hub = new ModelHub(this.secrets, { faux: options.faux ?? false, home: options.paths.home, piAgentDir: options.piAgentDir ?? getAgentDir(), ...(options.remoteCatalog ? { remoteCatalog: true } : {}) });
		this.connectors = new ConnectorHub(this.secrets, {
			home: options.paths.home,
			...(options.connectorEndpoints ? { endpoints: options.connectorEndpoints } : {}),
			emit: (loginId, connector, event) => {
				for (const conn of this.authed) conn.notify("connectors.auth", { loginId, connector, event });
			},
		});
		this.connectors.onChange = () => {
			for (const conn of this.authed) conn.notify("connectors.changed", {});
			// An account gone or a permission changed: open apps show only what they may show now (docs/spec/35 §16).
			this.apps?.connectionsChanged();
		};
		this.hub.onProvidersChanged = () => {
			for (const conn of this.authed) conn.notify("providers.changed", {});
		};
		this.logins = new LoginFlows(() => this.hub.models, (loginId, provider, event) => {
			for (const conn of this.authed) conn.notify("providers.auth", { loginId, provider, event });
		}, {
			agentName: "Piopio",
			deviceId: () => this.hub.deviceId(),
			finished: (provider, ok) => {
				void (async () => {
					if (ok) await this.hub.signedIn(provider);
					for (const conn of this.authed) conn.notify("providers.changed", {});
				})();
			},
		});
		this.sessions = new Sessions(options.paths, this.hub, {
			...(options.piSessionDir ? { piSessionDir: options.piSessionDir } : {}),
			...(options.piAgentDir ? { piAgentDir: options.piAgentDir } : {}),
			...(options.trashDir ? { trashDir: options.trashDir } : {}),
		}, { allowPrivate: options.allowPrivateFetch ?? false });
		this.sessions.connectors = this.connectors;
		this.sessions.onChange((change) => {
			for (const conn of this.authed) conn.notify("catalog.changed", change);
		});
		this.sessions.onInbox = (change) => {
			for (const conn of this.authed) conn.notify("inbox.changed", change);
		};
		this.sessions.onWork = (project) => {
			for (const conn of this.authed) conn.notify("work.changed", { project });
		};
		this.sessions.onAttention = (change) => {
			// A Piopio run set to skip what needs your OK (docs/spec/27 AU8) stops there and ends as skipped.
			if (change.kind === "waiting" && this.automations?.runOf({ conversation: change.ref.id })?.automation?.approval === "skip") {
				void this.sessions.stopSession(change.ref.id).catch(() => undefined);
				this.automations.skipped({ conversation: change.ref.id }, `Skipped: it needed your OK (${change.message})`);
				return;
			}
			for (const conn of this.authed) conn.notify("session.attention", change);
		};
		// A test agent folder: pi's own lookups (MCP config, codemode) read it from the environment.
		if (options.piAgentDir) process.env.PI_CODING_AGENT_DIR = options.piAgentDir;
		const agentDir = options.piAgentDir ?? getAgentDir();
		this.projects = new Projects(options.paths.projectsIndex, agentDir, options.paths.projectsRoot, join(options.paths.home, "projects"));
		this.mcp = new McpConfig(agentDir);
		this.browserSites = new BrowserSites(join(options.paths.home, "browser-sites.json"));
		this.settings = new Settings(join(options.paths.home, "settings.json"));
		this.hub.utilityChoice = () => this.settings.get().models?.utility;
		this.memory = new MemoryProviders(
			join(options.paths.home, "memory.db"),
			this.mcp,
			this.settings,
			async (provider) => {
				const credential = await this.hub.credentials.read(provider).catch(() => undefined);
				return credential?.type === "api_key" ? credential.key : undefined;
			},
			// Search by meaning's embeddings, with the other spending outside conversations (Settings › Models › Costs).
			(model, usd) => this.hub.extraCosts.record("embeddings", model, usd),
		);
		// Records written before semantic search (or while offline) get their vectors in the background.
		setTimeout(() => this.memory.fill(), 15_000).unref();
		void this.notesFromMemory();
		this.aboutMe = new AboutMe(this.memory, this.settings, join(options.paths.home, "about-me.json"));
		this.packages = new Packages(agentDir);
		this.chatResources = new ChatResources(agentDir);
		this.packages.onChange(() => {
			void this.chatResources.reload();
			void this.sessions.reloadResources();
		});
		this.sessions.chat = { settings: this.settings, aboutMe: this.aboutMe, mcpOff: () => notInChat(this.mcp, (name, server) => this.inChat(name, server)), resources: this.chatResources };
		this.sessions.agentHost = { files: new AgentFiles(options.agentsDir), memory: this.memory, app: this.app };
		this.sessions.browserSites = this.browserSites;
		if (options.agentAskTimeoutMs) this.sessions.agentAskTimeoutMs = options.agentAskTimeoutMs;
		if (options.agentLearn) this.sessions.agentLearn = options.agentLearn;
		// Agents on Telegram from this Mac (docs/spec/19 S4): polling, so no webhook or cloud.
		this.telegram = new TelegramChannels({
			// A cloud agent's bot is read by the cloud, by webhook (docs/spec/30 K1).
			agents: () => this.sessions.agents.agentList().filter((a) => !this.sessions.agents.isCloud(a.id)),
			definition: (id) => this.sessions.agents.agentList().find((a) => a.id === id)?.definition,
			save: (id, change, message) => this.sessions.agents.changeAgent(id, change, message),
			submit: async (id, contactId, text) => {
				const view = await (await this.sessions.agent({ kind: "agent", id })).view(contactId);
				await view.submit(text, { whenBusy: "followUp" });
			},
			notice: async (id, text) => (await this.sessions.agent({ kind: "agent", id })).notice(text),
			// A visual for Telegram: the Mac app draws it and answers with a picture (docs/spec/25 §8).
			picture: async (visual) => {
				const r = await this.app.tool({ name: "show_visual", args: { ...visual, look: true }, groups: ["visuals"], shortcuts: [] });
				const image = r.images?.[0];
				return image ? Buffer.from(image.data, "base64") : undefined;
			},
			secrets: this.secrets,
			stateDir: join(options.paths.home, "channels", "telegram"),
			log: this.log,
			...(options.telegram?.fetch ? { fetch: options.telegram.fetch } : {}),
			...(options.telegram?.pollSeconds !== undefined ? { pollSeconds: options.telegram.pollSeconds } : {}),
			...(options.telegram?.retryMs !== undefined ? { retryMs: options.telegram.retryMs } : {}),
		});
		this.sessions.telegram = this.telegram;
		// Your cloud (docs/spec/30 K1): agents that keep going with the Mac off.
		this.cloud = new CloudLink({ file: join(options.paths.home, "cloud.json"), secrets: this.secrets, log: this.log, ...(options.cloud ?? {}) });
		this.sessions.cloud = this.cloud;
		// The Library (docs/spec/35 §4): it fills from what search reads, so it's set before the backfill below.
		let libraryNote: NodeJS.Timeout | undefined;
		this.sessions.library = new Library(join(options.paths.home, "library.json"), () => {
			clearTimeout(libraryNote);
			libraryNote = setTimeout(() => {
				for (const conn of this.authed) conn.notify("library.changed", {});
			}, 300);
			libraryNote.unref?.();
		});
		this.apps = new Apps({
			home: options.paths.home,
			appsDir: join(options.paths.projectsRoot, "Apps"),
			changed: (app) => {
				for (const conn of this.authed) conn.notify("apps.data", { app });
			},
			// Calendar sources (docs/spec/35 §16): every connected account, apart from what chats may use, and the
			// permission Settings › Connectors gives reading it.
			calendar: {
				accounts: () => this.connectors.calendars("agent").map((c) => ({ id: c.account.id, label: c.account.label, app: c.name })),
				permission: (id) => {
					const c = this.connectors.calendars("agent").find((x) => x.account.id === id);
					return c ? this.connectors.permission(c.account.connector, "calendar_events") : "off";
				},
				events: async (id, range) => {
					const c = this.connectors.calendars("agent").find((x) => x.account.id === id);
					if (!c) throw new Error("It isn't connected any more.");
					return c.calendar.events(range);
				},
			},
			// Piopio's own numbers (docs/spec/35 L4, 34's stats.*): the same reads Overview makes, no model.
			piopio: { read: (what, args) => this.piopioRead(what, args) },
		});
		this.sessions.apps = this.apps;
		this.sessions.secrets = this.secrets;
		// Automations (docs/spec/27): one list of what starts on its own, run as Piopio or as one of your agents.
		this.automations = new Automations({
			file: join(options.paths.home, "automations.json"),
			runsFile: join(options.paths.home, "automation-runs.json"),
			clockFile: join(options.paths.home, "automations-clock.sqlite"),
			log: this.log,
			agent: (id) => {
				const a = this.sessions.agents.agentList().find((x) => x.id === id);
				return a ? { id: a.id, name: a.name, telegram: Boolean(a.definition.channels?.telegram), ...(this.sessions.agents.isCloud(a.id) ? { cloud: true } : {}) } : undefined;
			},
			project: (id) => {
				try {
					const p = this.projects.get(id);
					return { id: p.id, name: p.name, path: p.path };
				} catch {
					return undefined;
				}
			},
			runAgent: async (agentId, a, prompt, key) => {
				const run = await (await this.sessions.agent({ kind: "agent", id: agentId })).runAutomation(a, prompt, key);
				return { runId: run.id, conversationId: run.conversationId, status: run.status, ...(run.summary ? { summary: run.summary } : {}) };
			},
			runPiopio: (a, text) => this.sessions.automationConversation(a, text, a.project ? this.projects.get(a.project).path : undefined),
			session: (id) => this.sessions.sessionState(id),
			stopSession: (id) => this.sessions.stopSession(id),
			hookUrl: (id) => (this.hooks?.port ? this.hooks.url("a", id) : undefined),
			mailboxes: () => this.connectors.mailboxes("agent").length,
			ready: () => (this.options.faux ? Promise.resolve() : this.secrets.whenConnected(60_000)),
			changed: () => {
				for (const conn of this.authed) conn.notify("automations.changed", {});
			},
			watchesChanged: () => void this.watchers?.sync().catch(() => undefined),
			hold: () => this.hub.budget.holdReason(),
			heldChanged: () => this.hub.budget.heldChanged(),
		});
		this.sessions.automations = this.automations;
		// Piopio this month (docs/spec/34 OV3): it holds automations past 100%, and says each level once.
		this.hub.budget.heldRuns = () => this.automations.heldRuns();
		this.hub.budget.releaseAll = () => void this.automations.release().catch((error) => this.log(`Held runs: ${(error as Error).message}`));
		this.hub.budget.onChange = (event) => {
			for (const conn of this.authed) conn.notify("budget.changed", event);
		};
		this.sessions.log = this.log;
		this.sessions.onAutomationsMigrated = (lines) => this.appendAutomationReport(lines);
		this.sessions.onRuntimeReplaced = (ref) => {
			for (const r of this.rebinders.values()) if (r.refId === ref.id) void r.rebind().catch(() => undefined);
		};
		// Folders and connected mail for automations that wait for them (docs/spec/27 §5); webhooks go through hooks.
		this.watchers = new AgentWatchers({
			watches: async () => this.automations.watches(),
			fire: async (_owner, id, happened, key) => void (await this.automations.fire(id, "event", happened, key)),
			mail: () => this.connectors.mailboxes("agent").map((b) => ({ name: b.name, search: (q: string, n: number) => b.mailbox.search(q, n) })),
			stateFile: join(options.paths.home, "watchers.json"),
			log: this.log,
			...(options.watchers?.mailEveryMs !== undefined ? { mailEveryMs: options.watchers.mailEveryMs } : {}),
			...(options.watchers?.settleMs !== undefined ? { settleMs: options.watchers.settleMs } : {}),
		});
		this.sessions.watchers = this.watchers;
		// Projects' work (docs/spec/26): the way of working, the board and the routines of each project.
		this.teamsDir = options.teamsDir ?? process.env.PIOPIO_TEAMS_DIR ?? join(homedir(), "Piopio", "Teams");
		this.agentDir = agentDir;
		this.work = new WorkRunner(
			this.sessions.workHost({
				stateFile: join(options.paths.home, "work.json"),
				worktreesDir: join(options.paths.home, "worktrees", "work"),
				log: this.log,
				// A project by id or by folder (a worktree's is its project's).
				project: (x) => {
					if (x.startsWith("prj_")) {
						try {
							const p = this.projects.get(x);
							return { id: p.id, path: p.path };
						} catch {
							return undefined;
						}
					}
					return this.projects.projectFor(x);
				},
			}),
		);
		this.sessions.work = this.work;
		// The Watchdog (docs/spec/17 §4): notes on conversations that look stuck or repeat themselves.
		this.watchdog = new Watchdog(
			{
				deliver: (ref, rule, text) => this.sessions.children.watchdogNote(ref, rule, text),
				title: (ref) => this.sessions.titleOf(ref),
				notify: (ref, title, message) => {
					for (const conn of this.authed) conn.notify("session.attention", { ref, title, kind: "notify", message });
				},
				changed: () => {
					for (const conn of this.authed) conn.notify("watchdog.changed", {});
				},
			},
			join(options.paths.home, "watchdog.json"),
			options.watchdog ?? {},
		);
		this.sessions.watchdog = this.watchdog;
		// A deleted conversation's notes go with it; the ones it left behind before this go on start.
		const known = new Set(this.sessions.list().map((s) => s.ref.id));
		this.watchdog.prune((id) => known.has(id));
		this.sessions.onChange((change) => {
			if (change.removed.length) this.watchdog.forget(change.removed.map((r) => r.id));
			// A deleted agent's automations, its Telegram bot, state and token go with it: they ran, or polled, for nobody.
			for (const ref of change.removed) {
				if (ref.kind !== "agent") continue;
				for (const a of this.automations?.list().filter((x) => x.runsAs === ref.id) ?? []) this.automations!.remove(a.id);
				void this.telegram?.forget(ref.id).catch(() => undefined);
			}
		});
		// GitHub (docs/spec/05-build G4–G8): pull requests linked to conversations, polled for what happens on them.
		// Its short-lived git sign-in file goes in this engine's data folder, not the default one.
		this.github = new GitHub(this.secrets, { home: options.paths.home, ...options.github });
		this.sessions.github = this.github;
		// The GitHub connector (docs/spec/12 C3) signs in with the same GitHub sign-in.
		this.connectors.tokens.github = { get: async () => (await this.github.token())?.token, help: "Sign in to GitHub in Settings › Git & GitHub (or with `gh auth login`), then connect GitHub again." };
		// Side conversations in another project (docs/spec/24 SCQ5, 26 CL11): by its name or id.
		this.sessions.projectNamed = (name) => {
			const p = this.projects.list().find((x) => x.missing !== true && (x.id === name || x.name.toLowerCase() === name.toLowerCase()));
			return p ? { id: p.id, path: p.path } : undefined;
		};
		this.sessions.projectNames = () => this.projects.list().filter((x) => x.missing !== true).map((x) => x.name);
		// Webhook automations: `/hooks/a/<id>/…`, or an address one had before (an agent's trigger, a project's routine).
		this.hooks = new Hooks(join(options.paths.home, "hooks.key"), (first, second, body, delivery) => this.automations.fireHook(first, second, body, delivery), this.log);
		this.sessions.hookUrl = (agent, trigger) => this.hooks.url(agent, trigger);
		this.sessions.policy = {
			networkFor: (cwd) => this.projects.networkFor(cwd),
			projectFor: (cwd) => this.projects.projectFor(cwd),
			modeFor: (cwd) => this.projects.modeFor(cwd),
			rulesFor: (cwd) => this.projects.rulesFor(cwd),
			foldersFor: (cwd) => this.projects.foldersFor(cwd),
			addRule: (cwd, rule) => this.projects.addRule(cwd, rule),
			prEventsFor: (cwd) => this.projects.prEventsFor(cwd),
			checkFor: (cwd) => this.projects.checkFor(cwd),
		};
		this.projects.onChange((projects) => {
			for (const conn of this.authed) conn.notify("projects.changed", { projects });
		});
	}

	async listen(): Promise<void> {
		const { socket } = this.options.paths;
		if (Buffer.byteLength(socket) > 103) {
			throw new Error(`Socket path is ${Buffer.byteLength(socket)} bytes; macOS allows 103. Use a shorter PIOPIO_HOME.`);
		}
		if (existsSync(socket)) {
			if (await socketAnswers(socket)) throw new Error(`Another engine is already listening on ${socket}`);
			unlinkSync(socket);
		}
		this.token = loadOrCreateToken(this.options.paths);
		await this.hub.ready();
		await this.aboutMe.migrate().catch((error) => this.log(`About me: couldn't bring in the old doc: ${(error as Error).message}`));
		// Chats from before one engine for conversations (2026-11-15) move to pi sessions first.
		const moved = await this.sessions.migrateChats(this.log);
		if (moved) this.log(`Moved ${moved} chat${moved === 1 ? "" : "s"} to the new engine.`);
		// The interim browser (Playwright MCP, 2026-11-14) is gone: take out what it left (docs/spec/22 §13).
		this.removeInterimBrowser();
		// Teams from before docs/spec/26 become their projects' ways of working, once.
		this.migrateTeams();
		// Project routines from before docs/spec/27 become automations, once (agents' schedules move when each opens).
		this.migrateRoutines();
		this.server = createServer((stream) => this.accept(new RpcConnectionFor(stream)));
		await new Promise<void>((resolve, reject) => {
			this.server!.once("error", reject);
			this.server!.listen(socket, () => resolve());
		});
		chmodSync(socket, 0o600);
		this.log(`piopio-engine ${ENGINE_VERSION} listening on ${socket}${this.options.faux ? " (faux models)" : ""}`);
		// Index older threads for search in the background.
		this.backfill = this.sessions.backfillSearch().catch(() => 0);
		// Pick up pi CLI sessions in project folders: what changed while the engine was off, then live.
		const folders = () => this.projects.list().filter((p) => !p.missing).map((p) => p.path);
		for (const cwd of folders()) void this.sessions.syncFolder(cwd);
		this.sessions.watchPiSessions(folders);
		// Agents: webhook triggers, then every agent's schedules (they run with the app closed).
		await this.hooks.listen(this.options.hooksPort ?? (Number(process.env.PIOPIO_HOOKS_PORT) || DEFAULT_HOOKS_PORT)).catch((error) => this.log(`Webhook triggers are off: ${(error as Error).message}`));
		// Automations' clock: what was due while the engine was off runs once (docs/spec/27 AU9).
		this.automations.start();
		// After a sleep: automations and agents' own sleeps due meanwhile run now (not as late as it slept), the time asleep doesn't count as
		// a conversation being stuck, and Telegram's polls and the cloud's sockets start again (they may be half-dead).
		this.wake.onWake((sleptMs) => {
			this.log(`Woke after about ${Math.round(sleptMs / 60_000)} min asleep: catching up.`);
			this.automations?.woke();
			void this.sessions.agents.woke();
			this.watchdog.slept(sleptMs);
			void this.telegram?.woke().catch(() => undefined);
			this.cloud?.woke();
		});
		this.wake.start();
		void this.sessions.agents.startAgents(this.log);
		// MCP apps (Linear): their servers' current tools, for conversations started from now on.
		void this.connectors.refreshMcpTools().catch(() => undefined);
		// Cloud agents' status (paused, spend, Inbox) and their approvals' notifications, every minute (docs/spec/30 K1).
		this.cloudTick = setInterval(() => void this.sessions.agents.refreshCloudAgents(), 60_000);
		this.cloudTick.unref?.();
		void this.sessions.agents.refreshCloudAgents();
		void this.work.resume().catch((error: unknown) => this.log(`Work: ${(error as Error).message}`));
		// Open pull requests: what happens on them goes to the conversation that owns them (docs/spec/17 §5).
		this.prTimer = setInterval(() => void this.sessions.prs.poll().catch((error: unknown) => this.log(`Pull requests: ${(error as Error).message}`)), this.options.github?.pollMs ?? 120_000);
		this.prTimer.unref?.();
	}

	/** Whether conversations use a global MCP server: chosen per server, else (before that) all that are on. */
	/** Projects without a folder became folders (CF4): what they remembered goes into their NOTES.md. */
	/** What an app's piopio source reads (docs/spec/35 §3.2): Overview's numbers, automation runs, agents. */
	private async piopioRead(what: PiopioRead, args: Record<string, unknown>): Promise<unknown> {
		const names = this.sessions.ledgerNames();
		switch (what) {
			case "stats.spend":
				await this.sessions.backfillLedger();
				return this.hub.ledger.spend(args as Params<"stats.spend">, names);
			case "stats.activity":
				await this.sessions.backfillLedger();
				return activity(args.range as SpendRange, { ledger: this.hub.ledger, sessions: this.sessions.list(), runs: this.automations.allRuns(), automationName: (id) => this.automations.find(id)?.name, agentName: (id) => this.sessions.titleOf({ kind: "agent", id }) });
			case "stats.budgets":
				return { budgets: this.sessions.budgets(), piopio: this.hub.budget.state() };
			case "automations.runs": {
				const runs = await this.automations.runsOf(args.automation as string | undefined, (args.limit as number | undefined) ?? 30);
				return runs.map((r) => ({ id: r.id, automation: r.automation, name: this.automations.find(r.automation)?.name ?? "Automation", firedAt: r.firedAt, status: r.status, ...(r.summary ? { summary: r.summary } : {}), ...(r.costUsd !== undefined ? { costUsd: r.costUsd } : {}) }));
			}
			case "agents": {
				const summaries = new Map(this.sessions.list("agent").map((s) => [s.ref.id, s]));
				return this.sessions.agents.agentList().map((a) => {
					const status = summaries.get(a.id)?.agent?.status;
					return {
						id: a.id,
						name: a.name,
						runsOn: this.sessions.agents.isCloud(a.id) ? "cloud" : "mac",
						model: a.definition.models.default,
						paused: status?.paused ?? false,
						spendUsd: status?.spendUsd ?? 0,
						...(status?.budgetUsd !== undefined ? { budgetUsd: status.budgetUsd } : {}),
						...(status?.nextRun ? { nextRun: status.nextRun } : {}),
						inbox: status?.inbox ?? 0,
					};
				});
			}
		}
	}

	private async notesFromMemory(): Promise<void> {
		for (const { id, notes } of this.projects.migrated) {
			const bank = `project:${id}`;
			const facts = (await this.memory.builtin.list(bank, { kinds: ["fact"], limit: 500 }).catch(() => undefined))?.records ?? [];
			if (facts.length) appendFileSync(notes, `\n${facts.map((f) => `- ${f.text}`).join("\n")}\n`);
			this.memory.builtin.wipe(bank);
		}
	}

	/** The interim browser's `browser` entry in pi's mcp.json (if it still points at its port), its chat switch and its folder. */
	private removeInterimBrowser(): void {
		const dir = join(this.options.paths.home, "browser");
		const stateFile = join(dir, "state.json");
		if (!existsSync(stateFile)) return;
		try {
			const { port } = JSON.parse(readFileSync(stateFile, "utf8")) as { port?: number };
			const entry = this.mcp.globalServers().find((s) => s.name === "browser");
			if (port && entry?.server.url === `http://127.0.0.1:${port}/mcp`) {
				this.mcp.remove("global", undefined, "browser");
				this.setChat("browser", false);
			}
			rmSync(dir, { recursive: true, force: true });
			this.log("Browser: removed the interim Playwright browser");
		} catch (error) {
			this.log(`Browser: couldn't remove the interim one: ${(error as Error).message}`);
		}
	}

	/** The known project a skill's file is in, if any. */
	projectOf(path: string): string | undefined {
		return this.projects.list().map((p) => p.path).find((root) => resolve(path).startsWith(`${resolve(root)}/`));
	}

	/** Chats read skills again now; Build sessions at their next message. */
	async skillsChanged(): Promise<void> {
		await this.chatResources.reload();
		await this.sessions.reloadResources();
	}

	inChat(name: string, server: RawServer): boolean {
		const chat = this.settings.get().chat;
		return chat.mcpServers ? chat.mcpServers.includes(name) : chat.mcp && server.enabled !== false;
	}

	setChat(name: string, on: boolean): void {
		const current = this.mcp.globalServers().filter((g) => this.inChat(g.name, g.server)).map((g) => g.name);
		const next = on ? [...new Set([...current, name])] : current.filter((n) => n !== name);
		this.settings.set({ chat: { mcpServers: next } });
	}

	/** Settings › Connectors: each app, its accounts, its settings and what its tools may do. */
	async connectorInfos(): Promise<Result<"connectors.list">["connectors"]> {
		return Promise.all(
			this.connectors.definitions.map(async (d) => {
				const settings = this.connectors.settings(d.id);
				const clientId = this.connectors.clientId(d.id);
				// MCP apps sign in through their own server: nothing to set up.
				const mcp = d.kind === "mcp";
				const ready = mcp || (Boolean(clientId) && (!d.oauth.needsSecret || (await this.connectors.hasClientSecret(d.id))));
				return {
					id: d.id,
					name: d.name,
					category: d.category,
					description: d.description,
					ready,
					ownClient: Boolean(settings.clientId),
					needsSecret: !mcp && d.oauth.needsSecret,
					setupHelp: d.setupHelp,
					connecting: this.connectors.connecting(d.id),
					chats: settings.chats,
					accounts: this.connectors.accounts(d.id).map((a) => ({ id: a.id, label: a.label, addedAt: a.addedAt, ...(this.connectors.problem(a.id) ? { problem: this.connectors.problem(a.id)! } : {}) })),
					capabilities: this.connectors.capabilities(d.id).map((g) => ({ id: g.id, label: g.label, tools: g.tools, access: g.access, permission: g.permission, choices: choices(g.access), ...(g.note ? { note: g.note } : {}) })),
				};
			}),
		);
	}

	/** docs/spec/26 §8: teams.json and team-definitions.json, read once, become projects' work and playbooks. */
	private migrateTeams(): void {
		if (!needsMigration(this.options.paths.home)) return;
		const agents = new Map(this.sessions.list("agent").map((a) => [a.ref.id, a.title]));
		const result = migrateTeams({
			home: this.options.paths.home,
			teamsDir: this.teamsDir,
			skillsDir: join(this.agentDir, "skills"),
			project: (cwd) => {
				const known = this.projects.projectFor(cwd);
				if (known) return known;
				try {
					const added = this.projects.add(cwd);
					return { id: added.id, path: added.path };
				} catch {
					return undefined;
				}
			},
			agent: (id) => {
				const name = agents.get(id);
				if (!name) return undefined;
				try {
					const model = this.sessions.agents.agentDefinition(id).definition.models.default;
					return { name, ...(model ? { model } : {}) };
				} catch {
					return { name };
				}
			},
			log: this.log,
		});
		this.work.adopt(result.work);
		// The teams' routines are automations run by Piopio in their projects (docs/spec/27 §6).
		if (result.routines.length) this.adoptRoutines(result.routines);
		this.sessions.migrateTeams((id) => result.projectOf.get(id));
		this.log(`Teams became ways of working in ${result.work.length} project${result.work.length === 1 ? "" : "s"} (docs/spec/26).`);
	}

	/** docs/spec/27 §6: project-routines.json, read once, becomes automations run by Piopio in their projects. */
	private migrateRoutines(): void {
		const file = join(this.options.paths.home, "project-routines.json");
		if (!existsSync(file)) return;
		let places: LegacyPlace[] = [];
		try {
			places = JSON.parse(readFileSync(file, "utf8")) as LegacyPlace[];
		} catch (error) {
			this.log(`Automations: couldn't read the project routines: ${(error as Error).message}`);
		}
		this.adoptRoutines(places);
		renameSync(file, join(this.options.paths.home, "project-routines.before-27.json"));
	}

	private adoptRoutines(places: LegacyPlace[]): void {
		const name = (id: string) => {
			try {
				return this.projects.get(id).name;
			} catch {
				return undefined;
			}
		};
		const migrated = fromProjects(places, name, Date.now());
		if (!migrated.automations.length) return;
		this.automations.adopt(migrated.automations, migrated.runs);
		this.appendAutomationReport(migrated.lines);
		this.log(`${migrated.automations.length} project routine${migrated.automations.length === 1 ? " is" : "s are"} now automations (docs/spec/27).`);
	}

	/** Lines for "What changed in your routines" (27 §6), shown in the app until you dismiss it. */
	private appendAutomationReport(lines: string[]): void {
		if (!lines.length) return;
		const file = join(this.options.paths.home, AUTOMATIONS_REPORT);
		const before = existsSync(file) ? readFileSync(file, "utf8").split("\n").filter((l) => l.startsWith("- ")) : [];
		writeFileSync(file, automationsReport([...before, ...lines]));
	}

	async stop(): Promise<void> {
		this.wake.stop();
		clearInterval(this.cloudTick);
		this.cloud?.close();
		this.telegram?.stop();
		this.watchers?.stop();
		await this.automations?.stop().catch(() => undefined);
		this.apps?.stop();
		this.work?.stop();
		this.watchdog?.stop();
		clearInterval(this.prTimer);
		for (const conn of this.authed) conn.close();
		await this.backfill;
		for (const off of this.subscriptions.values()) off();
		this.subscriptions.clear();
		await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
		await this.hooks.close();
		await this.sessions.closeAll();
		await this.connectors.close();
		this.inputReceipts.close();
		this.hub.extraCosts.close();
		this.hub.budget.close();
		this.hub.ledger.close();
		await this.memory.reset();
		if (existsSync(this.options.paths.socket)) unlinkSync(this.options.paths.socket);
	}

	/** A call that took more than half the app's wait, and isn't one that's slow by nature: worth knowing (protocol SLOW_METHODS). */
	private async timed<T>(method: MethodName, run: () => Promise<T>): Promise<T> {
		const started = Date.now();
		try {
			return await run();
		} finally {
			const ms = Date.now() - started;
			if (ms > CALL_TIMEOUT_MS / 2 && !(SLOW_METHODS as readonly string[]).includes(method)) {
				this.log(`${method} took ${Math.round(ms / 1000)} s; the app stops waiting at ${CALL_TIMEOUT_MS / 1000} s. If it's slow by nature, add it to SLOW_METHODS (packages/protocol).`);
			}
		}
	}

	private accept(holder: RpcConnectionFor): void {
		let authed = false;
		const owned = new Set<string>();
		let unregisterSecrets: (() => void) | undefined;
		let unregisterTools: (() => void) | undefined;

		const conn: RpcConnection = new RpcConnection(holder.stream, async (method, params): Promise<unknown> => {
			if (!(method in methods)) throw new MethodNotFound(`Unknown method ${method}`);
			const schema = methods[method as MethodName].params;
			if (!Value.Check(schema, params)) {
				const first = [...Value.Errors(schema, params)][0];
				throw new EngineError("INVALID", `Invalid params for ${method}${first ? `: ${first.instancePath || "/"} ${first.message}` : ""}`);
			}
			if (method === "engine.hello") {
				const p = params as Params<"engine.hello">;
				if (!sameToken(p.token, this.token)) throw new EngineError("AUTH", "Bad engine token.");
				authed = true;
				this.authed.add(conn);
				// Clients offering `secrets.set` also store sign-ins and refreshed tokens (docs/spec/10 §10).
				const writer = p.services?.includes("secrets.set")
					? {
							set: async (name: string, value: string) => void (await conn.request("secrets.set", { name, value })),
							delete: async (name: string) => void (await conn.request("secrets.delete", { name })),
						}
					: undefined;
				unregisterSecrets = this.secrets.addRequester(async (name, purpose) => {
					const res = (await conn.request("secrets.get", { name, purpose } satisfies Params<never> | object)) as { value: string | null };
					return Value.Check(reverseMethods["secrets.get"].result, res) ? res.value : null;
				}, writer);
				// The Mac app serves Apple app tools (§3.12); only a client that says so is asked.
				if (p.services?.includes("app.tool")) {
					unregisterTools = this.app.addToolServer(
						async (call) => {
							const res = await conn.request("app.tool", call);
							if (!Value.Check(reverseMethods["app.tool"].result, res)) throw new Error("The app's answer wasn't understood.");
							return res;
						},
						{ browser: p.services.includes("browser"), visuals: p.services.includes("visuals") },
					);
				}
				return this.hello();
			}
			if (!authed) throw new EngineError("AUTH", "Call engine.hello first.");
			const execute = () => this.timed(method as MethodName, () => this.handle(method as MethodName, params, conn, owned));
			if (method === "sessions.submit" || method === "sessions.edit") {
				const request = params as { clientRequestId?: string };
				if (request.clientRequestId) return this.inputReceipts.run(request.clientRequestId, { method, params }, execute);
			}
			return execute();
		});

		conn.onClose(() => {
			this.authed.delete(conn);
			for (const path of this.appOpens.get(conn) ?? []) this.apps.closeApp(path);
			this.appOpens.delete(conn);
			unregisterSecrets?.();
			unregisterTools?.();
			for (const id of owned) {
				this.subscriptions.get(id)?.();
				this.subscriptions.delete(id);
			}
		});
	}

	private hello(): Result<"engine.hello"> {
		return {
			engineId: this.id,
			kind: "local",
			version: ENGINE_VERSION,
			protocolVersion: PROTOCOL_VERSION,
			capabilities: { runtimes: ["thread", "build"], models: [`${this.hub.defaultModel.provider}/${this.hub.defaultModel.id}`] },
		};
	}

	/** The `cwd` of a git call, if it's a project or a session's worktree. */
	folder(params: unknown): string {
		const cwd = (params as { cwd: string }).cwd;
		if (!this.sessions.knowsFolder(cwd)) throw new EngineError("INVALID", "Git runs only in project folders and session worktrees.");
		return cwd;
	}

	/** Every method's handler (handlers/<prefix>.ts, through handlers/index.ts). */
	private readonly handlers: AllHandlers = handlersFor(this);

	private async handle(method: MethodName, params: unknown, conn: RpcConnection, owned: Set<string>): Promise<unknown> {
		const handler = this.handlers[method as keyof AllHandlers] as Handler<MethodName> | undefined;
		if (!handler) throw new MethodNotFound(`Unknown method ${method}`);
		return handler(params as never, { conn, owned });
	}
}

/** Small holder so the constructor can reference the stream before the connection exists. */
export type { ConnectorEndpoints };
class RpcConnectionFor {
	constructor(readonly stream: import("node:net").Socket) {}
}

/** The engine token, compared in constant time (hashed first, so lengths match). */
function sameToken(given: string, token: string): boolean {
	const digest = (s: string) => createHash("sha256").update(s).digest();
	return timingSafeEqual(digest(given), digest(token));
}
