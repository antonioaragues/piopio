/** Local Engine: Engine Protocol over a Unix domain socket. */
import { keepAttachments } from "./attachment-files.js";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { appendFileSync, existsSync, mkdirSync, unlinkSync, chmodSync, statSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { createConnection, createServer, type Server } from "node:net";
import { methods, PROTOCOL_VERSION, reverseMethods, SECRET_OPENROUTER, type MethodName, type Params, type Result } from "@piopio/protocol";
import { Value } from "typebox/value";
import { EngineError, keyHint, ModelHub, providerUsage } from "./models.js";
import { ensureDirs, loadOrCreateToken, type EnginePaths } from "./paths.js";
import { MethodNotFound, RpcConnection } from "./rpc/connection.js";
import { SecretBroker } from "./secrets.js";
import { connectMethods, LoginFlows } from "./providers.js";
import { detectLocalServers } from "./endpoints.js";
import { ConnectorHub } from "./connectors/hub.js";
import { choices } from "./connectors/permissions.js";
import type { ConnectorEndpoints } from "./connectors/types.js";
import type { Runtime } from "./runtimes/runtime.js";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { listDir, readProjectFile, searchFiles, writeProjectFile } from "./files.js";
import { McpConfig, type RawServer } from "./mcp.js";
import { detectOtherApps, McpStatus, probe } from "./mcp-probe.js";
import * as gitOps from "./git.js";
import { Projects } from "./projects.js";
import { Sessions } from "./sessions.js";
import { ABOUT_ME_BANK, AboutMe } from "./about-me.js";
import { Settings } from "./settings.js";
import { notInChat } from "./tools/mcp-chat.js";
import { ChatResources } from "./tools/chat-resources.js";
import { Packages } from "./packages.js";
import { exportMemory, MemoryProviders } from "./memory.js";
import { AgentFiles } from "./agent-files.js";
import { DEFAULT_HOOKS_PORT, Hooks } from "./hooks.js";
import { groupSteps, StepsView } from "./timeline/steps.js";
import { DeltaBatcher } from "./timeline/delta-batcher.js";
import { replacedVisuals } from "./tools/visuals.js";
import { fitCheck } from "./work/fit.js";
import type { TimelineItem, ToolItem } from "@piopio/protocol";

/** Subagents keep their own card (it opens their session). */
/** Tools that stay their own item when steps fold: subagent tasks, questions you answered, plans, files handed over and visuals (they read as part of the conversation). */
const keepAlone = (tool: ToolItem) => tool.tool === "task" || tool.tool === "ask_user" || tool.tool === "ask_owner" || tool.tool === "ask_agent" || tool.tool === "offer_parallel" || tool.tool === "side_offer" || tool.tool === "side_start" || tool.tool === "side_propose" || tool.tool === "automate" || tool.tool === "change_automation" || tool.tool === "propose_plan" || tool.tool === "present_files" || tool.tool === "show_visual";
/** Folds a turn's tool calls into steps lines; a visual that a later one replaced (docs/spec/25 §3.4) folds in too. */
const fold = (items: readonly TimelineItem[]): TimelineItem[] => {
	const replaced = replacedVisuals(items);
	return groupSteps(items, (tool) => keepAlone(tool) && !replaced.has(tool.id));
};
import { AppServices } from "./app-services.js";
import { BrowserSites } from "./tools/browser-tools.js";
import { TelegramChannels } from "./channels/manager.js";
import { AgentWatchers } from "./watchers.js";
import { Automations } from "./automations/service.js";
import { PIOPIO, systemZone, type Automation } from "./automations/model.js";
import { fromProjects, REPORT_FILE as AUTOMATIONS_REPORT, reportOf as automationsReport, type LegacyPlace } from "./automations/migrate.js";
import type { Automation as AutomationView } from "@piopio/protocol";
import { WorkRunner, type ProjectWork } from "./work/runner.js";
import { migrateTeams, needsMigration, REPORT_FILE } from "./work/migrate.js";
import { buildAgenda } from "./agenda.js";
import { Watchdog, type WatchdogOptions } from "./watchdog.js";
import { GitHub, type GitHubOptions } from "./github.js";
import { TEMPLATES } from "@piopio/runtime";

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
	private readonly logins: LoginFlows;
	readonly hub: ModelHub;
	readonly connectors: ConnectorHub;
	readonly sessions: Sessions;
	readonly projects: Projects;
	readonly mcp: McpConfig;
	private readonly browserSites: BrowserSites;
	readonly settings: Settings;
	readonly aboutMe: AboutMe;
	private readonly mcpStatus = new McpStatus();
	readonly packages: Packages;
	readonly chatResources: ChatResources;
	readonly memory: MemoryProviders;
	readonly hooks: Hooks;
	readonly telegram: TelegramChannels;
	readonly watchers: AgentWatchers;
	readonly work: WorkRunner;
	readonly automations: Automations;
	readonly watchdog: Watchdog;
	readonly github: GitHub;
	private prTimer?: NodeJS.Timeout;
	private readonly teamsDir: string;
	private readonly agentDir: string;
	readonly app = new AppServices();
	private usageCache?: { at: number; value: Result<"usage.summary"> };
	private server?: Server;
	private token = "";
	private subscriptions = new Map<string, () => void>();
	/** Subscriptions by conversation, so they follow it when its runtime is replaced (a switch to or from a coding agent, docs/spec/31). */
	private rebinders = new Map<string, { refId: string; rebind: () => Promise<void> }>();
	private authed = new Set<RpcConnection>();
	/** Resolves when older threads are indexed for search (tests wait on it). */
	backfill: Promise<number> = Promise.resolve(0);
	private readonly startedAt = Date.now();
	private readonly log: (line: string) => void;

	constructor(private readonly options: EngineOptions) {
		this.log = options.log ?? ((line) => process.stderr.write(`${line}\n`));
		ensureDirs(options.paths);
		this.inputReceipts = new InputReceipts(join(options.paths.home, "requests.db"));
		this.hub = new ModelHub(this.secrets, { faux: options.faux ?? false, home: options.paths.home });
		this.connectors = new ConnectorHub(this.secrets, {
			home: options.paths.home,
			...(options.connectorEndpoints ? { endpoints: options.connectorEndpoints } : {}),
			emit: (loginId, connector, event) => {
				for (const conn of this.authed) conn.notify("connectors.auth", { loginId, connector, event });
			},
		});
		this.connectors.onChange = () => {
			for (const conn of this.authed) conn.notify("connectors.changed", {});
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
		this.memory = new MemoryProviders(join(options.paths.home, "memory.db"), this.mcp, this.settings, async (provider) => {
			const credential = await this.hub.credentials.read(provider).catch(() => undefined);
			return credential?.type === "api_key" ? credential.key : undefined;
		});
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
			agents: () => this.sessions.agentList().filter((a) => !this.sessions.isCloud(a.id)),
			definition: (id) => this.sessions.agentList().find((a) => a.id === id)?.definition,
			save: (id, change, message) => this.sessions.changeAgent(id, change, message),
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
		this.sessions.secrets = this.secrets;
		// Automations (docs/spec/27): one list of what starts on its own, run as Piopio or as one of your agents.
		this.automations = new Automations({
			file: join(options.paths.home, "automations.json"),
			runsFile: join(options.paths.home, "automation-runs.json"),
			log: this.log,
			agent: (id) => {
				const a = this.sessions.agentList().find((x) => x.id === id);
				return a ? { id: a.id, name: a.name, telegram: Boolean(a.definition.channels?.telegram), ...(this.sessions.isCloud(a.id) ? { cloud: true } : {}) } : undefined;
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
		});
		this.sessions.automations = this.automations;
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
				deliver: (ref, rule, text) => this.sessions.watchdogNote(ref, rule, text),
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
		});
		// GitHub (docs/spec/05-build G4–G8): pull requests linked to conversations, polled for what happens on them.
		this.github = new GitHub(this.secrets, options.github ?? {});
		this.sessions.github = this.github;
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
			projectFor: (cwd) => this.projects.projectFor(cwd),
			modeFor: (cwd) => this.projects.modeFor(cwd),
			rulesFor: (cwd) => this.projects.rulesFor(cwd),
			foldersFor: (cwd) => this.projects.foldersFor(cwd),
			addRule: (cwd, rule) => this.projects.addRule(cwd, rule),
			prEventsFor: (cwd) => this.projects.prEventsFor(cwd),
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
			if (await isAlive(socket)) throw new Error(`Another engine is already listening on ${socket}`);
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
		void this.sessions.startAgents(this.log);
		// Cloud agents' status (paused, spend, Inbox) and their approvals' notifications, every minute (docs/spec/30 K1).
		this.cloudTick = setInterval(() => void this.sessions.refreshCloudAgents(), 60_000);
		this.cloudTick.unref?.();
		void this.sessions.refreshCloudAgents();
		void this.work.resume().catch((error: unknown) => this.log(`Work: ${(error as Error).message}`));
		// Open pull requests: what happens on them goes to the conversation that owns them (docs/spec/17 §5).
		this.prTimer = setInterval(() => void this.sessions.pollPrs().catch((error: unknown) => this.log(`Pull requests: ${(error as Error).message}`)), this.options.github?.pollMs ?? 120_000);
		this.prTimer.unref?.();
	}

	/** Whether conversations use a global MCP server: chosen per server, else (before that) all that are on. */
	/** Projects without a folder became folders (CF4): what they remembered goes into their NOTES.md. */
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

	private inChat(name: string, server: RawServer): boolean {
		const chat = this.settings.get().chat;
		return chat.mcpServers ? chat.mcpServers.includes(name) : chat.mcp && server.enabled !== false;
	}

	private setChat(name: string, on: boolean): void {
		const current = this.mcp.globalServers().filter((g) => this.inChat(g.name, g.server)).map((g) => g.name);
		const next = on ? [...new Set([...current, name])] : current.filter((n) => n !== name);
		this.settings.set({ chat: { mcpServers: next } });
	}

	/** Settings › Connectors: each app, its accounts, its settings and what its tools may do. */
	private async connectorInfos(): Promise<Result<"connectors.list">["connectors"]> {
		return Promise.all(
			this.connectors.definitions.map(async (d) => {
				const settings = this.connectors.settings(d.id);
				const clientId = this.connectors.clientId(d.id);
				const ready = Boolean(clientId) && (!d.oauth.needsSecret || (await this.connectors.hasClientSecret(d.id)));
				return {
					id: d.id,
					name: d.name,
					category: d.category,
					description: d.description,
					ready,
					ownClient: Boolean(settings.clientId),
					needsSecret: d.oauth.needsSecret,
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
					const model = this.sessions.agentDefinition(id).definition.models.default;
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

	/** A project's work as the app sees it. */
	private workView(work: ProjectWork) {
		return { project: work.project, cwd: work.cwd, way: work.way, ...(work.git ? { git: work.git } : {}), tasks: work.tasks, createdAt: work.createdAt };
	}

	/** An automation as the app sees it: the record, and its words. */
	private automationView(a: Automation): AutomationView {
		const s = this.automations.summary(a);
		const last = this.automations.lastRun(a.id);
		return {
			...a,
			label: s.when,
			runnerName: s.runsAs,
			resultLabel: s.tellsYou,
			...(s.url ? { url: s.url } : {}),
			...(last ? { lastStatus: last.status, ...(last.summary ? { lastSummary: last.summary } : {}) } : {}),
		};
	}

	async stop(): Promise<void> {
		clearInterval(this.cloudTick);
		this.cloud?.close();
		this.telegram?.stop();
		this.watchers?.stop();
		this.automations?.stop();
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
		this.inputReceipts.close();
		this.hub.extraCosts.close();
		await this.memory.reset();
		if (existsSync(this.options.paths.socket)) unlinkSync(this.options.paths.socket);
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
				if (p.token !== this.token) throw new EngineError("AUTH", "Bad engine token.");
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
			const execute = () => this.handle(method as MethodName, params, conn, owned);
			if (method === "sessions.submit" || method === "sessions.edit") {
				const request = params as { clientRequestId?: string };
				if (request.clientRequestId) return this.inputReceipts.run(request.clientRequestId, { method, params }, execute);
			}
			return execute();
		});

		conn.onClose(() => {
			this.authed.delete(conn);
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

	private async capability(ref: Params<"sessions.open">["ref"], name: "edit" | "regenerate" | "switchBranch" | "removeQueued"): Promise<Runtime> {
		const runtime = await this.sessions.runtime(ref);
		if (!runtime[name]) throw new EngineError("INVALID", `${ref.kind} sessions don't support ${name} yet.`);
		return runtime;
	}

	/** The `cwd` of a git call, if it's a project or a session's worktree. */
	private folder(params: unknown): string {
		const cwd = (params as { cwd: string }).cwd;
		if (!this.sessions.knowsFolder(cwd)) throw new EngineError("INVALID", "Git runs only in project folders and session worktrees.");
		return cwd;
	}

	private async handle(method: MethodName, params: unknown, conn: RpcConnection, owned: Set<string>): Promise<unknown> {
		switch (method) {
			case "engine.status":
				return {
					uptimeMs: Date.now() - this.startedAt,
					openSessions: this.sessions.openCount,
					subscriptions: this.subscriptions.size,
					runtime: `Node ${process.versions.node}`,
					memoryMB: Math.round(process.memoryUsage().rss / 1_048_576),
					dataPath: this.options.paths.home,
				} satisfies Result<"engine.status">;
			case "sessions.list": {
				const p = params as Params<"sessions.list">;
				return { sessions: this.sessions.list(p.kind) } satisfies Result<"sessions.list">;
			}
			case "sessions.continueIn": {
				const p = params as Params<"sessions.continueIn">;
				return { ref: await this.sessions.continueIn(p.ref, p.cwd, p.approvalMode) } satisfies Result<"sessions.continueIn">;
			}
			case "sessions.create": {
				const p = params as Params<"sessions.create">;
				return { ref: await this.sessions.create(p) } satisfies Result<"sessions.create">;
			}
			case "sessions.open": {
				const p = params as Params<"sessions.open">;
				const snapshot = (await this.sessions.runtime(p.ref)).snapshot();
				return (p.fold ? { ...snapshot, items: fold(snapshot.items) } : snapshot) satisfies Result<"sessions.open">;
			}
			case "sessions.subscribe": {
				const p = params as Params<"sessions.subscribe">;
				const runtime = await this.sessions.runtime(p.ref);
				const subscriptionId = `sub_${randomUUID().slice(0, 8)}`;
				let seq = 0;
				// Folded: this subscription sees a turn's tool calls as one steps item.
				const steps = p.fold ? new StepsView(fold) : undefined;
				const snapshot = runtime.snapshot();
				const first = steps ? { ...snapshot, items: steps.snapshot(snapshot.items) } : snapshot;
				// A notification per token is a JSON line and a main-thread hop on the Mac per token: deltas go out a frame at a time.
				const batcher = new DeltaBatcher((events) => conn.notify("session.events", { subscriptionId, seq: ++seq, events }));
				let current = runtime;
				let unsubscribe = runtime.onEvents((events) => {
					batcher.push(steps ? steps.events(events, () => current.snapshot().items) : events);
				});
				const off = () => {
					unsubscribe();
					batcher.dispose();
					this.rebinders.delete(subscriptionId);
				};
				this.subscriptions.set(subscriptionId, off);
				// The conversation's runtime was replaced: listen to the new one, starting from its snapshot.
				if (!p.ref.conversationId) {
					this.rebinders.set(subscriptionId, {
						refId: p.ref.id,
						rebind: async () => {
							const next = await this.sessions.runtime(p.ref);
							if (next === current || !this.subscriptions.has(subscriptionId)) return;
							unsubscribe();
							current = next;
							const snap = next.snapshot();
							batcher.push([{ type: "resnapshot", snapshot: steps ? { ...snap, items: steps.snapshot(snap.items) } : snap }]);
							unsubscribe = next.onEvents((events) => batcher.push(steps ? steps.events(events, () => current.snapshot().items) : events));
						},
					});
				}
				owned.add(subscriptionId);
				return { subscriptionId, snapshot: first } satisfies Result<"sessions.subscribe">;
			}
			case "sessions.unsubscribe": {
				const p = params as Params<"sessions.unsubscribe">;
				this.subscriptions.get(p.subscriptionId)?.();
				this.subscriptions.delete(p.subscriptionId);
				owned.delete(p.subscriptionId);
				return {};
			}
			case "engine.shutdown": {
				if (!this.options.onShutdown) throw new EngineError("INVALID", "This engine cannot be shut down remotely.");
				setTimeout(this.options.onShutdown, 100);
				return {};
			}
			case "sessions.submit": {
				const p = params as Params<"sessions.submit">;
				const runtime = await this.sessions.runtime(p.ref);
				const isFirst = runtime.snapshot().items.length === 0;
				// Your own words (docs/spec/24 §5): side conversations may wake this one again; one you drive doesn't wake its parent.
				this.sessions.youWrote(p.ref);
				const { disposition } = await runtime.submit(p.input.text, {
					whenBusy: p.whenBusy ?? "followUp",
					...(p.clientRequestId ? { requestId: p.clientRequestId } : {}),
					...(p.input.attachments ? { attachments: keepAttachments(this.options.paths.home, p.ref.id, p.input.attachments) } : {}),
				});
				this.sessions.touch(p.ref, isFirst ? p.input.text : undefined);
				return { accepted: true, disposition } satisfies Result<"sessions.submit">;
			}
			case "sessions.abort": {
				const p = params as Params<"sessions.abort">;
				await (await this.sessions.runtime(p.ref)).abort();
				return {};
			}
			case "sessions.edit": {
				const p = params as Params<"sessions.edit">;
				await this.capability(p.ref, "edit").then((r) => r.edit!(p.itemId, p.text));
				this.sessions.touch(p.ref);
				return {};
			}
			case "sessions.regenerate": {
				const p = params as Params<"sessions.regenerate">;
				await this.capability(p.ref, "regenerate").then((r) => r.regenerate!(p.itemId));
				this.sessions.touch(p.ref);
				return {};
			}
			case "sessions.switchBranch": {
				const p = params as Params<"sessions.switchBranch">;
				await this.capability(p.ref, "switchBranch").then((r) => r.switchBranch!(p.branch));
				return {};
			}
			case "sessions.fork": {
				const p = params as Params<"sessions.fork">;
				return { ref: await this.sessions.fork(p.ref, p.itemId) } satisfies Result<"sessions.fork">;
			}
			case "sessions.queue.remove": {
				const p = params as Params<"sessions.queue.remove">;
				await this.capability(p.ref, "removeQueued").then((r) => r.removeQueued!(p.queueId));
				return {};
			}
			case "sessions.configure": {
				const p = params as Params<"sessions.configure">;
				await this.sessions.configure(p.ref, { ...(p.model ? { model: p.model } : {}), ...(p.thinking ? { thinking: p.thinking } : {}), ...(p.web !== undefined ? { web: p.web } : {}), ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.planMode !== undefined ? { planMode: p.planMode } : {}), ...(p.toolsOff ? { toolsOff: p.toolsOff } : {}) });
				return {};
			}
			case "sessions.rename": {
				const p = params as Params<"sessions.rename">;
				this.sessions.rename(p.ref, p.title);
				return {};
			}
			case "sessions.delete": {
				const p = params as Params<"sessions.delete">;
				await this.sessions.delete(p.ref);
				return {};
			}
			case "sessions.export": {
				const p = params as Params<"sessions.export">;
				return (await this.sessions.export(p.ref, p.format)) satisfies Result<"sessions.export">;
			}
			case "projects.list":
				return { projects: this.projects.list() } satisfies Result<"projects.list">;
			case "projects.add": {
				const p = params as Params<"projects.add">;
				const project = this.projects.add(p.path, p.lens);
				await this.sessions.syncFolder(project.path);
				return { project } satisfies Result<"projects.add">;
			}
			case "projects.configure": {
				const p = params as Params<"projects.configure">;
				const change = { ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.removeRule ? { removeRule: p.removeRule } : {}), ...(p.trust !== undefined ? { trust: p.trust } : {}), ...(p.linkFolder ? { linkFolder: p.linkFolder } : {}), ...(p.unlinkFolder ? { unlinkFolder: p.unlinkFolder } : {}), ...(p.prEvents ? { prEvents: p.prEvents } : {}) };
				return { project: this.projects.configure(p.id, change) } satisfies Result<"projects.configure">;
			}
			case "projects.create": {
				const p = params as Params<"projects.create">;
				return { project: this.projects.create(p.name, p.instructions) } satisfies Result<"projects.create">;
			}
			case "sessions.agentDraft": {
				const p = params as Params<"sessions.agentDraft">;
				return (await this.sessions.agentDraft(p.ref)) satisfies Result<"sessions.agentDraft">;
			}
			case "sessions.changes": {
				const p = params as Params<"sessions.changes">;
				return (await (await this.sessions.build(p.ref)).changes(p.since)) satisfies Result<"sessions.changes">;
			}
			case "sessions.diff": {
				const p = params as Params<"sessions.diff">;
				return { patch: await (await this.sessions.build(p.ref)).diff(p.path, p.since) } satisfies Result<"sessions.diff">;
			}
			case "sessions.restore": {
				const p = params as Params<"sessions.restore">;
				return { files: await (await this.sessions.build(p.ref)).restore(p.checkpointId, p.paths, p.dryRun ?? false) } satisfies Result<"sessions.restore">;
			}
			case "sessions.commands": {
				const p = params as Params<"sessions.commands">;
				if (p.ref.kind === "agent") return { commands: await this.sessions.chatCommands() } satisfies Result<"sessions.commands">;
				return { commands: (await this.sessions.build(p.ref)).commands() } satisfies Result<"sessions.commands">;
			}
			case "sessions.rewind": {
				const p = params as Params<"sessions.rewind">;
				return (await (await this.sessions.build(p.ref)).rewind(p.itemId, p.files, p.dryRun ?? false)) satisfies Result<"sessions.rewind">;
			}
			case "sessions.tree": {
				const p = params as Params<"sessions.tree">;
				return { nodes: (await this.sessions.build(p.ref)).tree() } satisfies Result<"sessions.tree">;
			}
			case "sessions.navigate": {
				const p = params as Params<"sessions.navigate">;
				return (await (await this.sessions.build(p.ref)).navigate(p.entryId)) satisfies Result<"sessions.navigate">;
			}
			case "sessions.compact": {
				const p = params as Params<"sessions.compact">;
				await (await this.sessions.build(p.ref)).compact();
				return {};
			}
			case "projects.files": {
				const p = params as Params<"projects.files">;
				const limit = p.limit ?? 30;
				const own = await searchFiles(this.folder(p), p.query, limit);
				// Linked folders (18 §18): their matches too, as absolute paths, once something is typed.
				const linked = p.query.trim() ? (await Promise.all(this.projects.foldersFor(p.cwd).map(async (f) => (await searchFiles(f.path, p.query, 8)).map((m) => ({ ...m, path: join(f.path, m.path) }))))).flat() : [];
				const room = Math.max(limit - Math.min(linked.length, Math.ceil(limit / 2)), 0);
				return { files: [...own.slice(0, room), ...linked].slice(0, limit) } satisfies Result<"projects.files">;
			}
			case "projects.listDir": {
				const p = params as Params<"projects.listDir">;
				return { entries: await listDir(this.folder(p), p.dir) } satisfies Result<"projects.listDir">;
			}
			case "projects.readFile": {
				const p = params as Params<"projects.readFile">;
				return (await readProjectFile(this.folder(p), p.path)) satisfies Result<"projects.readFile">;
			}
			case "projects.writeFile": {
				const p = params as Params<"projects.writeFile">;
				await writeProjectFile(this.folder(p), p.path, p.content);
				return {};
			}
			case "browser.sites":
				return { sites: this.browserSites.list() } satisfies Result<"browser.sites">;
			case "browser.setSite": {
				const p = params as Params<"browser.setSite">;
				this.browserSites.set(p.site, p.level);
				return {};
			}
			case "mcp.list": {
				const p = params as Params<"mcp.list">;
				const list = this.mcp.list(p.cwd ? this.folder(p) : undefined);
				const global = new Map(this.mcp.globalServers().map((g) => [g.name, g.server]));
				return { ...list, servers: list.servers.map((s) => (s.scope === "global" && global.has(s.name) ? { ...s, chat: this.inChat(s.name, global.get(s.name)!) } : s)) } satisfies Result<"mcp.list">;
			}
			case "mcp.add": {
				const p = params as Params<"mcp.add">;
				const { scope, cwd, name, chat, ...server } = p;
				this.mcp.add(scope, cwd ? this.folder({ cwd }) : undefined, name, server);
				if (scope === "global") {
					if (chat !== undefined) this.setChat(name, chat);
				}
				return {};
			}
			case "mcp.probe": {
				const p = params as Params<"mcp.probe">;
				if (!p.command === !p.url) throw new EngineError("INVALID", "Give either a command or a URL.");
				return (await probe(p)) satisfies Result<"mcp.probe">;
			}
			case "mcp.status": {
				const p = params as Params<"mcp.status">;
				const cwd = p.cwd ? this.folder(p) : undefined;
				return (await this.mcpStatus.get(`${p.scope}:${cwd ?? ""}:${p.name}`, this.mcp.resolve(p.scope, cwd, p.name), p.refresh)) satisfies Result<"mcp.status">;
			}
			case "mcp.setChat": {
				const p = params as Params<"mcp.setChat">;
				this.setChat(p.name, p.chat);
				return {};
			}
			case "mcp.setTool": {
				const p = params as Params<"mcp.setTool">;
				this.mcp.setTool(p.scope, p.cwd ? this.folder(p) : undefined, p.name, p.tool, p.enabled);
				return {};
			}
			case "mcp.detect":
				return { found: detectOtherApps(new Set(this.mcp.list().servers.map((s) => s.name))) } satisfies Result<"mcp.detect">;
			case "mcp.remove": {
				const p = params as Params<"mcp.remove">;
				this.mcp.remove(p.scope, p.cwd ? this.folder(p) : undefined, p.name);
				return {};
			}
			case "mcp.setEnabled": {
				const p = params as Params<"mcp.setEnabled">;
				this.mcp.setEnabled(p.scope, p.cwd ? this.folder(p) : undefined, p.name, p.enabled);
				return {};
			}
			case "packages.preview":
				return (await this.packages.preview((params as Params<"packages.preview">).source)) satisfies Result<"packages.preview">;
			case "packages.setResource": {
				const p = params as Params<"packages.setResource">;
				await this.packages.setResource(p.source, p.kind, p.path, p.enabled);
				return {};
			}
			case "packages.list":
				return { packages: await this.packages.list() } satisfies Result<"packages.list">;
			case "packages.install": {
				const p = params as Params<"packages.install">;
				await this.packages.install(p.source);
				return {};
			}
			case "packages.remove": {
				const p = params as Params<"packages.remove">;
				await this.packages.remove(p.source);
				return {};
			}
			case "packages.update": {
				const p = params as Params<"packages.update">;
				await this.packages.update(p.source);
				return {};
			}
			case "packages.setEnabled": {
				const p = params as Params<"packages.setEnabled">;
				await this.packages.setEnabled(p.source, p.enabled, p.kinds);
				return {};
			}
			case "settings.get":
				return this.settings.get() satisfies Result<"settings.get">;
			case "settings.set": {
				const p = params as Params<"settings.set">;
				return this.settings.set(p) satisfies Result<"settings.set">;
			}
			case "aboutMe.get":
				return (await this.aboutMe.info()) satisfies Result<"aboutMe.get">;
			case "aboutMe.set": {
				const p = params as Params<"aboutMe.set">;
				await this.aboutMe.set(p.text);
				return {};
			}
			case "aboutMe.undo": {
				const p = params as Params<"aboutMe.undo">;
				await this.aboutMe.undo(p.revisionId);
				return {};
			}
			case "agents.templates":
				return { templates: TEMPLATES.map(({ id, name, avatar, description, instructions, definition }) => ({ id, name, avatar, description, instructions, ...(definition.schedules?.[0] ? { schedule: definition.schedules[0].cron } : {}) })) } satisfies Result<"agents.templates">;
			case "agents.create": {
				const p = params as Params<"agents.create">;
				return { ref: await this.sessions.createAgent(p) } satisfies Result<"agents.create">;
			}
			case "agents.get": {
				const p = params as Params<"agents.get">;
				return (await this.sessions.getAgent(p.ref)) satisfies Result<"agents.get">;
			}
			case "agents.save": {
				const p = params as Params<"agents.save">;
				return (await this.sessions.saveAgent(p.ref, p.definition, p.instructions, p.message)) satisfies Result<"agents.save">;
			}
			case "agents.conversations": {
				const p = params as Params<"agents.conversations">;
				return { people: await this.sessions.agentConversations(p.ref) } satisfies Result<"agents.conversations">;
			}
			case "home.agenda": {
				const p = params as Params<"home.agenda">;
				// Messages held by quiet hours or limits, across agents.
				let held = 0;
				for (const a of this.sessions.list("agent")) held += (await this.sessions.agentRuns(a.ref).catch(() => undefined))?.outbox.length ?? 0;
				const all = this.projects.list();
				const agents = new Map(this.sessions.agentList().map((a) => [a.id, a.name]));
				const automations = this.automations.list().map((a) => ({
					id: a.id,
					name: a.name,
					on: a.on,
					label: this.automations.summary(a).when,
					...(a.next ? { next: a.next } : {}),
					enabled: a.enabled,
					source:
						a.runsAs !== PIOPIO
							? { kind: "agent" as const, id: a.runsAs, name: agents.get(a.runsAs) ?? "An agent" }
							: a.project
								? { kind: "project" as const, id: a.project, name: all.find((x) => x.id === a.project)?.name ?? "A project" }
								: { kind: "piopio" as const, id: PIOPIO, name: "Piopio" },
				}));
				const runs = await this.automations.runsOf(undefined, 500);
				const boards = this.work.list().flatMap((w) => {
					const name = all.find((x) => x.id === w.project)?.name;
					return name ? [{ project: { id: w.project, name }, tasks: w.tasks }] : [];
				});
				return buildAgenda({ now: Date.now(), tz: systemZone(), ...(p.since ? { since: Date.parse(p.since) } : {}), automations, runs, boards, held }) satisfies Result<"home.agenda">;
			}
			case "github.status":
				return (await this.github.status()) satisfies Result<"github.status">;
			case "github.setToken": {
				const p = params as Params<"github.setToken">;
				return { login: await this.github.setToken(p.token) } satisfies Result<"github.setToken">;
			}
			case "github.signOut":
				await this.github.signOut();
				return {} satisfies Result<"github.signOut">;
			case "github.repos":
				return { repos: await this.github.repos() } satisfies Result<"github.repos">;
			case "github.clone": {
				const p = params as Params<"github.clone">;
				const name = p.repo.replace(/\.git$/, "").split("/").pop() || "repo";
				let dest = p.path?.trim() || join(this.options.paths.projectsRoot, name);
				if (!p.path) for (let n = 2; existsSync(dest); n++) dest = join(this.options.paths.projectsRoot, `${name}-${n}`);
				else if (existsSync(dest)) throw new EngineError("INVALID", `${dest} already exists.`);
				mkdirSync(this.options.paths.projectsRoot, { recursive: true });
				await this.github.clone(p.repo, dest);
				const project = this.projects.add(dest);
				await this.sessions.syncFolder(project.path);
				return { project } satisfies Result<"github.clone">;
			}
			case "sessions.pr.draft": {
				const p = params as Params<"sessions.pr.draft">;
				return (await this.sessions.prDraft(p.ref)) satisfies Result<"sessions.pr.draft">;
			}
			case "sessions.pr.create": {
				const p = params as Params<"sessions.pr.create">;
				return { pr: await this.sessions.createPr(p.ref, { title: p.title, body: p.body, ...(p.base ? { base: p.base } : {}), ...(p.draft ? { draft: true } : {}) }) } satisfies Result<"sessions.pr.create">;
			}
			case "sessions.pr.get": {
				const p = params as Params<"sessions.pr.get">;
				return { pr: await this.sessions.prStatus(p.ref) } satisfies Result<"sessions.pr.get">;
			}
			case "sessions.pr.address": {
				const p = params as Params<"sessions.pr.address">;
				await this.sessions.addressPr(p.ref, p.what);
				return {} satisfies Result<"sessions.pr.address">;
			}
			case "sessions.side.answer": {
				const p = params as Params<"sessions.side.answer">;
				return (await this.sessions.answerSide(p.ref, p.id, p.choice)) satisfies Result<"sessions.side.answer">;
			}
			case "sessions.side.start": {
				const p = params as Params<"sessions.side.start">;
				const child = await this.sessions.startSide(p.ref, { brief: p.brief, ...(p.title ? { title: p.title } : {}) }, "manual");
				return { ref: child.ref } satisfies Result<"sessions.side.start">;
			}
			case "work.list":
				return { work: this.work.list().map((w) => this.workView(w)) } satisfies Result<"work.list">;
			case "work.get": {
				const p = params as Params<"work.get">;
				const work = this.work.find(this.projects.get(p.project).id);
				return (work ? { work: this.workView(work) } : {}) satisfies Result<"work.get">;
			}
			case "work.configure": {
				const p = params as Params<"work.configure">;
				const { project, ...change } = p;
				return { work: this.workView(await this.work.configure(project, change)) } satisfies Result<"work.configure">;
			}
			case "work.accept": {
				const p = params as Params<"work.accept">;
				this.sessions.plannerIn({ kind: "build", id: p.sessionId }, this.projects.get(p.project).path);
				const work = await this.work.configure(p.project, { parallel: true });
				await this.sessions.planInParallel({ kind: "build", id: p.sessionId });
				return { work: this.workView(work) } satisfies Result<"work.accept">;
			}
			case "work.playbooks": {
				const p = params as Params<"work.playbooks">;
				return { playbooks: this.work.playbooks(this.projects.get(p.project).path).map((x) => ({ id: x.id, name: x.name, description: x.description, source: x.source })) } satisfies Result<"work.playbooks">;
			}
			case "work.fitCheck": {
				const p = params as Params<"work.fitCheck">;
				return fitCheck(p.cwd) satisfies Result<"work.fitCheck">;
			}
			case "work.job": {
				const p = params as Params<"work.job">;
				return (await this.work.jobCost(p.project, p.conversationId)) satisfies Result<"work.job">;
			}
			case "work.addTask": {
				const p = params as Params<"work.addTask">;
				const task = await this.work.createTask(p.project, { title: p.title, brief: p.brief, ...(p.done ? { done: p.done } : {}) }, "you");
				return { task } satisfies Result<"work.addTask">;
			}
			case "work.updateTask": {
				const p = params as Params<"work.updateTask">;
				await this.work.updateTask(p.project, p.taskId, { ...(p.state ? { state: p.state } : {}), ...(p.title ? { title: p.title } : {}), ...(p.brief ? { brief: p.brief } : {}) });
				return {} satisfies Result<"work.updateTask">;
			}
			case "work.landing": {
				const p = params as Params<"work.landing">;
				return (await this.work.landing(p.project)) satisfies Result<"work.landing">;
			}
			case "work.land": {
				const p = params as Params<"work.land">;
				return (await this.work.land(p.project, p.action)) satisfies Result<"work.land">;
			}
			case "work.createPR": {
				const p = params as Params<"work.createPR">;
				const work = this.work.get(this.projects.get(p.project).id);
				if (!work.git) throw new EngineError("INVALID", "This project's work isn't on a branch.");
				const pr = await this.github.createPullRequest(work.cwd, { head: work.git.branch, base: work.git.base, title: p.title, body: p.body, ...(p.draft ? { draft: true } : {}) });
				return { pr: await this.github.pullRequest(pr.repo, pr.number) } satisfies Result<"work.createPR">;
			}
			case "work.migrationReport": {
				const file = join(this.options.paths.home, REPORT_FILE);
				return (existsSync(file) ? { report: readFileSync(file, "utf8").trim() } : {}) satisfies Result<"work.migrationReport">;
			}
			case "work.dismissMigrationReport": {
				const file = join(this.options.paths.home, REPORT_FILE);
				if (existsSync(file)) renameSync(file, join(this.options.paths.home, `${REPORT_FILE.replace(/\.md$/, "")}.seen.md`));
				return {} satisfies Result<"work.dismissMigrationReport">;
			}
			case "automations.list": {
				const p = params as Params<"automations.list">;
				// Runs still going are read again first, so "Running now" doesn't outlast them.
				await this.automations.runsOf(undefined, 200);
				const list = this.automations.list().filter((a) => (!p.runsAs || a.runsAs === p.runsAs) && (!p.project || a.project === p.project));
				return { automations: list.map((a) => this.automationView(a)) } satisfies Result<"automations.list">;
			}
			case "automations.get": {
				const p = params as Params<"automations.get">;
				const a = this.automations.get(p.id);
				this.automations.opened(a.id);
				return { automation: this.automationView(a), runs: await this.automations.runsOf(a.id, 20), summary: this.automations.summary(a) } satisfies Result<"automations.get">;
			}
			case "automations.add": {
				const { id: _ignored, ...p } = params as Params<"automations.add"> & { id?: string };
				const a = this.automations.add(p, "you");
				this.automations.opened(a.id);
				return { automation: this.automationView(a) } satisfies Result<"automations.add">;
			}
			case "automations.update": {
				const { id, ...change } = params as Params<"automations.update">;
				return { automation: this.automationView(this.automations.update(id, change)) } satisfies Result<"automations.update">;
			}
			case "automations.remove": {
				const p = params as Params<"automations.remove">;
				this.automations.remove(p.id);
				return {} satisfies Result<"automations.remove">;
			}
			case "automations.restore": {
				const p = params as Params<"automations.restore">;
				return { automation: this.automationView(this.automations.restoreRemoved(p.id)) } satisfies Result<"automations.restore">;
			}
			case "automations.run": {
				const p = params as Params<"automations.run">;
				const run = await this.automations.fire(p.id, "now", "Run now, by the user.");
				if (!run) throw new EngineError("INVALID", "It didn't run.");
				return { run } satisfies Result<"automations.run">;
			}
			case "automations.runs": {
				const p = params as Params<"automations.runs">;
				return { runs: await this.automations.runsOf(p.id, p.limit ?? 50) } satisfies Result<"automations.runs">;
			}
			case "automations.migrationReport": {
				const file = join(this.options.paths.home, AUTOMATIONS_REPORT);
				return (existsSync(file) ? { report: readFileSync(file, "utf8").trim() } : {}) satisfies Result<"automations.migrationReport">;
			}
			case "automations.dismissMigrationReport": {
				const file = join(this.options.paths.home, AUTOMATIONS_REPORT);
				if (existsSync(file)) renameSync(file, join(this.options.paths.home, `${AUTOMATIONS_REPORT.replace(/\.md$/, "")}.seen.md`));
				return {} satisfies Result<"automations.dismissMigrationReport">;
			}
			case "agents.runs": {
				const p = params as Params<"agents.runs">;
				return (await this.sessions.agentRuns(p.ref)) satisfies Result<"agents.runs">;
			}
			case "agents.runNow": {
				const p = params as Params<"agents.runNow">;
				if (this.sessions.isCloud(p.ref.id)) return (await this.sessions.cloudAgentCall(p.ref.id, "agents.runNow", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.runNow">;
				const run = await (await this.sessions.agent(p.ref)).runNow(p.scheduleId, p.prompt, p.trial ?? false);
				return { runId: run.id } satisfies Result<"agents.runNow">;
			}
			case "agents.triggers": {
				const p = params as Params<"agents.triggers">;
				const def = this.sessions.agentDefinition(p.ref.id).definition;
				if (!this.hooks.port) throw new EngineError("INTERNAL", "Webhook triggers are off (the port couldn't be opened).");
				return { triggers: (def.triggers ?? []).map((t) => ({ id: t.id, url: this.hooks.url(p.ref.id, t.id) })) } satisfies Result<"agents.triggers">;
			}
			case "agents.decide": {
				const p = params as Params<"agents.decide">;
				if (this.sessions.isCloud(p.ref.id)) return (await this.sessions.cloudAgentCall(p.ref.id, "agents.decide", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.decide">;
				const runtime = await this.sessions.agent(p.ref);
				try {
					const a = await runtime.core.safety.decide(p.approvalId, { approve: p.approve, ...(p.args && typeof p.args === "object" ? { args: p.args as never } : {}), ...(p.always ? { always: true } : {}), ...(p.reason ? { reason: p.reason } : {}) });
					return { status: a.status } satisfies Result<"agents.decide">;
				} catch (error) {
					throw new EngineError("CONFLICT", (error as Error).message);
				}
			}
			case "agents.undo": {
				const p = params as Params<"agents.undo">;
				if (this.sessions.isCloud(p.ref.id)) return (await this.sessions.cloudAgentCall(p.ref.id, "agents.undo", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.undo">;
				const runtime = await this.sessions.agent(p.ref);
				try {
					await runtime.core.safety.undo(p.undoId);
				} catch (error) {
					throw new EngineError("CONFLICT", (error as Error).message);
				}
				return {} satisfies Result<"agents.undo">;
			}
			case "agents.pause": {
				const p = params as Params<"agents.pause">;
				if (this.sessions.isCloud(p.ref.id)) return (await this.sessions.cloudAgentCall(p.ref.id, "agents.pause", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.pause">;
				await (await this.sessions.agent(p.ref)).core.safety.setPaused(p.paused);
				return {} satisfies Result<"agents.pause">;
			}
			case "usage.extras": {
				const p = params as Params<"usage.extras">;
				return this.hub.extraCosts.summary(p.ref?.id) satisfies Result<"usage.extras">;
			}
			case "usage.summary": {
				const p = params as Params<"usage.summary">;
				if (this.usageCache && !p.refresh && Date.now() - this.usageCache.at < 60_000) return this.usageCache.value;
				const key = await this.secrets.get(SECRET_OPENROUTER, "Show what your provider has billed").catch(() => null);
				const usage = key ? await providerUsage(key) : undefined;
				const value: Result<"usage.summary"> = { connected: Boolean(key), ...(key ? { keyHint: keyHint(key) } : {}), ...(usage ?? {}) };
				this.usageCache = { at: Date.now(), value };
				return value;
			}
			case "agents.trace": {
				const p = params as Params<"agents.trace">;
				return (await this.sessions.agentTrace(p.traceId)) satisfies Result<"agents.trace">;
			}
			case "inbox.list":
				return (await this.sessions.inbox()) satisfies Result<"inbox.list">;
			case "watchdog.list":
				return { notes: this.watchdog.list() } satisfies Result<"watchdog.list">;
			case "watchdog.dismiss": {
				const p = params as Params<"watchdog.dismiss">;
				this.watchdog.dismiss(p.id);
				return {} satisfies Result<"watchdog.dismiss">;
			}
			case "inbox.read": {
				const p = params as Params<"inbox.read">;
				await this.sessions.inboxRead(p.items);
				return {} satisfies Result<"inbox.read">;
			}
			case "agents.move": {
				const p = params as Params<"agents.move">;
				return { lines: await this.sessions.moveAgent(p.ref, p.to) } satisfies Result<"agents.move">;
			}
			case "cloud.status":
				return (await this.cloud.status()) satisfies Result<"cloud.status">;
			case "cloud.setup": {
				const p = params as Params<"cloud.setup">;
				const r = await this.cloud.setup(p.apiToken, p.accountId);
				if (r.status) void this.sessions.refreshCloudAgents();
				return r satisfies Result<"cloud.setup">;
			}
			case "cloud.update":
				return (await this.cloud.update()) satisfies Result<"cloud.update">;
			case "cloud.connect": {
				const p = params as Params<"cloud.connect">;
				return (await this.cloud.connect(p.url, p.token)) satisfies Result<"cloud.connect">;
			}
			case "cloud.disconnect": {
				const up = this.sessions.agentList().filter((a) => this.sessions.isCloud(a.id));
				if (up.length) throw new EngineError("INVALID", `${up.map((a) => a.name).join(", ")} ${up.length === 1 ? "runs" : "run"} in your cloud. Move ${up.length === 1 ? "it" : "them"} to this Mac first.`);
				await this.cloud.disconnect();
				return {} satisfies Result<"cloud.disconnect">;
			}
			case "agents.memory": {
				const p = params as Params<"agents.memory">;
				return this.sessions.agentMemory(p.ref) satisfies Result<"agents.memory">;
			}
			case "memory.list": {
				const p = params as Params<"memory.list">;
				const provider = this.memory.get(p.provider);
				if (!provider.list || !provider.capabilities.list) return { records: [], limited: true } satisfies Result<"memory.list">;
				if (p.query?.trim()) {
					const hits = await provider.recall([p.bank], p.query, { budgetTokens: 20_000, limit: 100, ...(p.kinds ? { kinds: p.kinds as never } : {}) });
					return { records: hits.map(({ bank: _b, tags: _t, confidence: _c, score: _s, ...r }) => r), limited: false } satisfies Result<"memory.list">;
				}
				const page = await provider.list(p.bank, { ...(p.cursor ? { cursor: p.cursor } : {}), ...(p.kinds ? { kinds: p.kinds as never } : {}), ...(p.includeEnded ? { includeEnded: true } : {}) } as never);
				return { records: page.records.map(({ bank: _b, tags: _t, confidence: _c, ...r }) => r), ...(page.cursor ? { cursor: page.cursor } : {}), limited: false } satisfies Result<"memory.list">;
			}
			case "memory.add": {
				const p = params as Params<"memory.add">;
				await this.memory.get(p.provider).retain(p.bank, { content: p.text, kind: "fact", createdBy: "user", ...(p.replaces ? { replaces: p.replaces } : {}) });
				return {};
			}
			case "memory.forget": {
				const p = params as Params<"memory.forget">;
				const provider = this.memory.get(p.provider);
				if (!provider.forget) throw new EngineError("INVALID", "This memory provider can't forget from here.");
				await provider.forget(p.bank, p.id, "user");
				return {};
			}
			case "memory.update": {
				const p = params as Params<"memory.update">;
				const provider = this.memory.get(p.provider);
				if (!provider.update) throw new EngineError("INVALID", "This memory provider can't edit from here.");
				await provider.update(p.bank, p.id, { ...(p.text !== undefined ? { text: p.text } : {}), ...(p.pinned !== undefined ? { pinned: p.pinned } : {}) }, "user");
				return {};
			}
			case "memory.tools": {
				const p = params as Params<"memory.tools">;
				if (!p.server === !p.url) throw new EngineError("INVALID", "Give an MCP server's name or a URL.");
				return { tools: await this.memory.tools(p) } satisfies Result<"memory.tools">;
			}
			case "memory.status":
				return (await this.memory.status()) satisfies Result<"memory.status">;
			case "memory.banks": {
				const owners = this.sessions.memoryOwners();
				const labels = new Map(owners.agents.flatMap((a) => a.partitions.map((p) => [p.bank, { label: p.label, agent: a }] as const)));
				const banks = this.memory.builtin.banks().map((b) => {
					const owner = labels.get(b.bank);
					const area = b.bank === ABOUT_ME_BANK ? "about-me" : owner ? "agent" : "other";
					return {
						...b,
						label: b.bank === ABOUT_ME_BANK ? "About me" : (owner?.label ?? b.bank),
						area,
						...(owner ? { agent: { id: owner.agent.id, name: owner.agent.name, ...(owner.agent.avatar ? { avatar: owner.agent.avatar } : {}), learns: owner.agent.learns } } : {}),
					};
				});
				const bytes = ["memory.db", "memory.db-wal"].reduce((n, f) => n + (existsSync(join(this.options.paths.home, f)) ? statSync(join(this.options.paths.home, f)).size : 0), 0);
				return { banks, agents: owners.agents.map(({ partitions: _p, ...a }) => a), bytes } satisfies Result<"memory.banks">;
			}
			case "memory.history": {
				const p = params as Params<"memory.history">;
				const provider = this.memory.get(p.provider);
				const events = provider.history ? await provider.history(p.bank, { limit: p.limit ?? 200 }) : [];
				return { events: events.map((e) => ({ id: e.id, at: e.at, action: e.action, recordId: e.recordId, text: e.text, by: e.by })) } satisfies Result<"memory.history">;
			}
			case "memory.export": {
				const p = params as Params<"memory.export">;
				return exportMemory(this.memory.builtin, p.folder, (bank) => (bank === ABOUT_ME_BANK ? "About me" : bank)) satisfies Result<"memory.export">;
			}
			case "memory.wipe": {
				const p = params as Params<"memory.wipe">;
				return { records: this.memory.builtin.wipe(p.bank === "*" ? undefined : p.bank) } satisfies Result<"memory.wipe">;
			}
			case "memory.reindex":
				return { pending: this.memory.reindex() } satisfies Result<"memory.reindex">;
			case "memory.setLearning": {
				const p = params as Params<"memory.setLearning">;
				await this.sessions.setLearning(p.ref, p.learn);
				return {} satisfies Result<"memory.setLearning">;
			}
			case "memory.recall": {
				const p = params as Params<"memory.recall">;
				const hits = await this.memory.get(p.provider).recall([p.bank], p.query, { budgetTokens: 2000 });
				return { hits: hits.map((h) => ({ id: h.id, text: h.text, score: h.score, ...(h.at ? { at: h.at } : {}) })) } satisfies Result<"memory.recall">;
			}
			case "sessions.finish": {
				const p = params as Params<"sessions.finish">;
				await this.sessions.finish(p.ref, p.action);
				return {};
			}
			case "git.status":
				return (await gitOps.status(this.folder(params))) satisfies Result<"git.status">;
			case "git.branches":
				return { branches: await gitOps.branches(this.folder(params)) } satisfies Result<"git.branches">;
			case "git.log": {
				const p = params as Params<"git.log">;
				return { commits: await gitOps.log(this.folder(p), p.since, p.limit ?? 20) } satisfies Result<"git.log">;
			}
			case "git.checkout": {
				const p = params as Params<"git.checkout">;
				await gitOps.checkout(this.folder(p), p.branch, p.create ?? false, p.base);
				this.projects.touch();
				return {};
			}
			case "git.commit": {
				const p = params as Params<"git.commit">;
				return { commit: await gitOps.commit(this.folder(p), p.message, { ...(p.paths ? { paths: p.paths } : {}), ...(p.amend ? { amend: true } : {}) }) } satisfies Result<"git.commit">;
			}
			case "git.message": {
				const p = params as Params<"git.message">;
				return { message: await gitOps.commitMessage(this.folder(p), p.paths, (system, prompt) => this.hub.utility(system, prompt)) } satisfies Result<"git.message">;
			}
			case "git.sync": {
				const p = params as Params<"git.sync">;
				const cwd = this.folder(p);
				const output = p.action === "push" ? await gitOps.push(cwd) : p.action === "pull" ? await gitOps.pull(cwd) : await gitOps.fetchAll(cwd);
				this.projects.touch();
				return { output } satisfies Result<"git.sync">;
			}
			case "git.suggestBranch": {
				const p = params as Params<"git.suggestBranch">;
				return { branch: gitOps.branchName(p.prompt) } satisfies Result<"git.suggestBranch">;
			}
			case "sessions.processOutput": {
				const p = params as Params<"sessions.processOutput">;
				return (await this.sessions.build(p.ref)).processOutput(p.id, p.since ?? 0) satisfies Result<"sessions.processOutput">;
			}
			case "sessions.processStop": {
				const p = params as Params<"sessions.processStop">;
				return (await (await this.sessions.build(p.ref)).processStop(p.id)) satisfies Result<"sessions.processStop">;
			}
			case "sessions.review": {
				const p = params as Params<"sessions.review">;
				return { ref: await this.sessions.review(p.ref, p.pr) } satisfies Result<"sessions.review">;
			}
			case "sessions.reviewFinding": {
				const p = params as Params<"sessions.reviewFinding">;
				this.sessions.reviewFinding(p.ref, p.id, p.state);
				return {} satisfies Result<"sessions.reviewFinding">;
			}
			case "sessions.respond": {
				const p = params as Params<"sessions.respond">;
				await this.sessions.respond(p.ref, p.promptId, p.response);
				return {};
			}
			case "projects.remove": {
				const p = params as Params<"projects.remove">;
				const project = this.projects.remove(p.id);
				await this.sessions.forgetFolder(project.path);
				return {};
			}
			case "catalog.search": {
				const p = params as Params<"catalog.search">;
				return { results: await this.sessions.find(p.query, p.limit ?? 30, p.kind) } satisfies Result<"catalog.search">;
			}
			case "models.onDevice":
				return (await this.hub.onDevice.status()) satisfies Result<"models.onDevice">;
			case "models.list": {
				const p = params as Params<"models.list">;
				return { models: await this.hub.listModels(p.refresh ?? false), defaultModel: this.hub.defaultModel } satisfies Result<"models.list">;
			}
			case "secrets.changed": {
				const p = params as Params<"secrets.changed">;
				await this.hub.forgetSecret(p.name);
				await this.hub.connected();
				for (const c of this.authed) c.notify("providers.changed", {});
				return {};
			}
			case "providers.list":
				return { providers: await this.hub.listProviders((id) => this.logins.connecting(id)) } satisfies Result<"providers.list">;
			case "providers.login": {
				const p = params as Params<"providers.login">;
				const provider = this.hub.models.getProvider(p.provider);
				if (!provider) throw new EngineError("NOT_FOUND", `Unknown provider ${p.provider}`);
				if (!connectMethods(provider).some((m) => m.type === p.method)) throw new EngineError("INVALID", `${provider.name} can't be connected that way.`);
				const loginId = this.logins.start(p.provider, p.method);
				for (const c of this.authed) c.notify("providers.changed", {});
				return { loginId } satisfies Result<"providers.login">;
			}
			case "providers.answer": {
				const p = params as Params<"providers.answer">;
				this.logins.answer(p.loginId, p.promptId, p.value);
				return {};
			}
			case "providers.cancelLogin": {
				const p = params as Params<"providers.cancelLogin">;
				this.logins.cancel(p.loginId);
				return {};
			}
			case "connectors.list":
				return { connectors: await this.connectorInfos() } satisfies Result<"connectors.list">;
			case "connectors.connect": {
				const p = params as Params<"connectors.connect">;
				try {
					return { loginId: this.connectors.connect(p.connector) } satisfies Result<"connectors.connect">;
				} catch (error) {
					throw new EngineError("INVALID", (error as Error).message);
				}
			}
			case "connectors.cancel": {
				this.connectors.cancel((params as Params<"connectors.cancel">).loginId);
				return {};
			}
			case "connectors.disconnect": {
				await this.connectors.disconnect((params as Params<"connectors.disconnect">).accountId);
				return {};
			}
			case "connectors.configure": {
				const p = params as Params<"connectors.configure">;
				await this.connectors.configure(p.connector, p);
				return {};
			}
			case "connectors.calendars": {
				const p = params as Params<"connectors.calendars">;
				try {
					return { calendars: (await this.connectors.calendarList(p.accountId)).map((c) => ({ id: c.id, name: c.name, primary: c.primary, enabled: c.enabled, ...(c.color ? { color: c.color } : {}) })) } satisfies Result<"connectors.calendars">;
				} catch (error) {
					throw new EngineError("INVALID", (error as Error).message);
				}
			}
			case "connectors.setCalendar": {
				const p = params as Params<"connectors.setCalendar">;
				this.connectors.setCalendar(p.accountId, p.calendarId, p.enabled);
				return {};
			}
			case "sessions.decide": {
				const p = params as Params<"sessions.decide">;
				return { status: await this.sessions.decide(p.ref, p.approvalId, { approve: p.approve, ...(p.always ? { always: true } : {}), ...(p.reason ? { reason: p.reason } : {}) }) } satisfies Result<"sessions.decide">;
			}
			case "endpoints.check": {
				const p = params as Params<"endpoints.check">;
				const check = await this.hub.checkEndpoint(p.baseUrl, p.key, p.id, { ...(p.format ? { format: p.format } : {}), ...(p.headers ? { headers: p.headers } : {}) });
				return (check.ok ? { ok: true, baseUrl: check.baseUrl, models: check.models, latencyMs: check.latencyMs } : { ok: false, models: [], message: check.message, error: check.error }) satisfies Result<"endpoints.check">;
			}
			case "providers.verifyKey": {
				const p = params as Params<"providers.verifyKey">;
				return (await this.hub.verifyProviderKey(p.provider, p.key)) satisfies Result<"providers.verifyKey">;
			}
			case "providers.saveKey": {
				const p = params as Params<"providers.saveKey">;
				await this.hub.saveKey(p.provider, p.key);
				for (const c of this.authed) c.notify("providers.changed", {});
				return {};
			}
			case "providers.models": {
				const p = params as Params<"providers.models">;
				return { models: await this.hub.providerModels(p.provider) } satisfies Result<"providers.models">;
			}
			case "providers.setHidden": {
				const p = params as Params<"providers.setHidden">;
				this.hub.setHidden(p.provider, p.hidden);
				for (const c of this.authed) c.notify("providers.changed", {});
				return {};
			}
			case "endpoints.save": {
				const p = params as Params<"endpoints.save">;
				const endpoint = await this.hub.saveEndpoint(p);
				for (const c of this.authed) c.notify("providers.changed", {});
				return { id: endpoint.id } satisfies Result<"endpoints.save">;
			}
			case "endpoints.remove": {
				const p = params as Params<"endpoints.remove">;
				await this.hub.removeEndpoint(p.id);
				for (const c of this.authed) c.notify("providers.changed", {});
				return {};
			}
			case "endpoints.detect": {
				const added = new Set(this.hub.endpoints.list().map((e) => e.baseUrl));
				return { found: (await detectLocalServers()).filter((f) => !added.has(f.baseUrl)) } satisfies Result<"endpoints.detect">;
			}
			case "providers.logout": {
				const p = params as Params<"providers.logout">;
				await this.hub.logout(p.provider);
				for (const c of this.authed) c.notify("providers.changed", {});
				return {};
			}
			default:
				throw new MethodNotFound(`Unknown method ${method}`);
		}
	}
}

/** Small holder so the constructor can reference the stream before the connection exists. */
export type { ConnectorEndpoints };
class RpcConnectionFor {
	constructor(readonly stream: import("node:net").Socket) {}
}

function isAlive(socket: string): Promise<boolean> {
	return new Promise((resolve) => {
		const s = createConnection(socket);
		s.once("connect", () => (s.destroy(), resolve(true)));
		s.once("error", () => resolve(false));
	});
}
