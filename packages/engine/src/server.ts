/** Local Engine: Engine Protocol over a Unix domain socket. */
import { keepAttachments } from "./attachment-files.js";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { appendFileSync, existsSync, unlinkSync, chmodSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { createConnection, createServer, type Server } from "node:net";
import { methods, PROTOCOL_VERSION, reverseMethods, SECRET_OPENROUTER, type MethodName, type Params, type Result } from "@piopio/protocol";
import { Value } from "typebox/value";
import { EngineError, keyHint, ModelHub, providerUsage, verifyProviderKey } from "./models.js";
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
import { ChatMcp } from "./tools/mcp-chat.js";
import { ChatResources } from "./tools/chat-resources.js";
import { Packages } from "./packages.js";
import { exportMemory, MemoryProviders } from "./memory.js";
import { AgentFiles } from "./agent-files.js";
import { DEFAULT_HOOKS_PORT, Hooks } from "./hooks.js";
import { groupSteps, StepsView } from "./timeline/steps.js";
import { fitCheck } from "./teams/fit.js";
import { draftFor } from "./teams/draft-for.js";
import type { ToolItem } from "@piopio/protocol";

/** Subagents keep their own card (it opens their session). */
/** Tools that stay their own item when steps fold: subagent tasks, questions you answered, plans and files handed over (they read as part of the conversation). */
const keepAlone = (tool: ToolItem) => tool.tool === "task" || tool.tool === "ask_user" || tool.tool === "ask_owner" || tool.tool === "ask_agent" || tool.tool === "offer_team" || tool.tool === "offer_repeat" || tool.tool === "propose_plan" || tool.tool === "present_files";
import { AppServices } from "./app-services.js";
import { TelegramChannels } from "./channels/manager.js";
import { AgentWatchers } from "./watchers.js";
import { routineLabel, type TeamRoutine } from "./teams/routines.js";
import { TeamRunner, type Team } from "./teams/runner.js";
import { buildAgenda } from "./agenda.js";
import { systemZone } from "./teams/routines.js";
import { draftTeam, readTemplates } from "./teams/library.js";
import { TEAM_TEMPLATES } from "./teams/templates.js";
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
	/** Where teams keep their folders (NOTES.md, a non-software team's work); default ~/Piopio/Teams or PIOPIO_TEAMS_DIR. */
	teamsDir?: string;
	/** Event routines (tests: check mail and settle folders sooner). */
	watchers?: { mailEveryMs?: number; settleMs?: number };
	/** Telegram's API (tests: a fake one) and how long a poll waits. */
	telegram?: { fetch?: typeof fetch; pollSeconds?: number; retryMs?: number };
	log?: (line: string) => void;
};

import { InputReceipts } from "./requests.js";

export class Engine {
	private readonly inputReceipts: InputReceipts;
	readonly id = randomUUID();
	readonly secrets = new SecretBroker();
	private readonly logins: LoginFlows;
	readonly hub: ModelHub;
	readonly connectors: ConnectorHub;
	readonly sessions: Sessions;
	readonly projects: Projects;
	readonly mcp: McpConfig;
	readonly settings: Settings;
	readonly aboutMe: AboutMe;
	readonly chatMcp: ChatMcp;
	private readonly mcpStatus = new McpStatus();
	readonly packages: Packages;
	readonly chatResources: ChatResources;
	readonly memory: MemoryProviders;
	readonly hooks: Hooks;
	readonly telegram: TelegramChannels;
	readonly watchers: AgentWatchers;
	readonly teams: TeamRunner;
	private readonly teamsDir: string;
	readonly app = new AppServices();
	private usageCache?: { at: number; value: Result<"usage.summary"> };
	private server?: Server;
	private token = "";
	private subscriptions = new Map<string, () => void>();
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
		this.sessions.onTeams = (id) => {
			for (const conn of this.authed) conn.notify("teams.changed", { id });
		};
		this.sessions.onAttention = (change) => {
			for (const conn of this.authed) conn.notify("session.attention", change);
		};
		// A test agent folder: pi's own lookups (MCP config, codemode) read it from the environment.
		if (options.piAgentDir) process.env.PI_CODING_AGENT_DIR = options.piAgentDir;
		const agentDir = options.piAgentDir ?? getAgentDir();
		this.projects = new Projects(options.paths.projectsIndex, agentDir, options.paths.projectsRoot, join(options.paths.home, "projects"));
		this.mcp = new McpConfig(agentDir);
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
		this.chatMcp = new ChatMcp(this.mcp, (name, server) => this.inChat(name, server));
		this.packages = new Packages(agentDir);
		this.chatResources = new ChatResources(agentDir);
		this.packages.onChange(() => void this.chatResources.reload());
		this.sessions.chat = { settings: this.settings, aboutMe: this.aboutMe, mcp: this.chatMcp, resources: this.chatResources };
		this.sessions.agentHost = { files: new AgentFiles(options.agentsDir), memory: this.memory, app: this.app };
		if (options.agentAskTimeoutMs) this.sessions.agentAskTimeoutMs = options.agentAskTimeoutMs;
		if (options.agentLearn) this.sessions.agentLearn = options.agentLearn;
		// Agents on Telegram from this Mac (docs/spec/19 S4): polling, so no webhook or cloud.
		this.telegram = new TelegramChannels({
			agents: () => this.sessions.agentList(),
			definition: (id) => this.sessions.agentList().find((a) => a.id === id)?.definition,
			save: (id, change, message) => this.sessions.changeAgent(id, change, message),
			submit: async (id, contactId, text) => {
				const view = await (await this.sessions.agent({ kind: "agent", id })).view(contactId);
				await view.submit(text, { whenBusy: "followUp" });
			},
			notice: async (id, text) => (await this.sessions.agent({ kind: "agent", id })).notice(text),
			secrets: this.secrets,
			stateDir: join(options.paths.home, "channels", "telegram"),
			log: this.log,
			...(options.telegram?.fetch ? { fetch: options.telegram.fetch } : {}),
			...(options.telegram?.pollSeconds !== undefined ? { pollSeconds: options.telegram.pollSeconds } : {}),
			...(options.telegram?.retryMs !== undefined ? { retryMs: options.telegram.retryMs } : {}),
		});
		this.sessions.telegram = this.telegram;
		// Event routines agents set themselves (docs/spec/19 S3): folders and connected mail; webhooks go through hooks.
		this.watchers = new AgentWatchers({
			// Agents' watches, and teams' folder and email routines (keyed by the team's id).
			watches: async () => [...(await this.sessions.agentWatches()), ...this.teams.routineWatches()],
			fire: async (id, watchId, happened, key) => {
				if (this.teams.hasProject(id)) await this.teams.fireRoutine(id, watchId, happened, key);
				else await (await this.sessions.agent({ kind: "agent", id })).fireWatch(watchId, happened, key);
			},
			mail: () => this.connectors.mailboxes("agent").map((b) => ({ name: b.name, search: (q: string, n: number) => b.mailbox.search(q, n) })),
			stateFile: join(options.paths.home, "watchers.json"),
			log: this.log,
			...(options.watchers?.mailEveryMs !== undefined ? { mailEveryMs: options.watchers.mailEveryMs } : {}),
			...(options.watchers?.settleMs !== undefined ? { settleMs: options.watchers.settleMs } : {}),
		});
		this.sessions.watchers = this.watchers;
		// Teams (docs/spec/19): a lead and members working through a board.
		this.teamsDir = options.teamsDir ?? process.env.PIOPIO_TEAMS_DIR ?? join(homedir(), "Piopio", "Teams");
		this.teams = new TeamRunner(
			this.sessions.teamHost({
				stateFile: join(options.paths.home, "teams.json"),
				worktreesDir: join(options.paths.home, "worktrees", "teams"),
				log: this.log,
				// A project by id or by folder (routines are a project's, docs/spec/21 AD5).
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
		this.sessions.teams = this.teams;
		// Your templates live beside your teams, as folders (docs/spec/20 P4).
		this.teams.templatesDir = join(this.teamsDir, "Templates");
		this.teams.templates = () => [...TEAM_TEMPLATES.map((t) => ({ ...t, source: "builtin" as const })), ...readTemplates(join(this.teamsDir, "Templates"))];
		// A team's webhook routine has the same kind of URL as an agent's trigger, with the team's id.
		this.hooks = new Hooks(join(options.paths.home, "hooks.key"), (agent, trigger, body, delivery) => (this.teams.hasProject(agent) ? this.teams.fireRoutine(agent, trigger, `Its URL was called. Body:\n${body}`, delivery ?? `${Date.now()}`) : this.sessions.fireTrigger(agent, trigger, body, delivery)), this.log);
		this.teams.hookUrl = (team, routine) => (this.hooks.port ? this.hooks.url(team, routine) : undefined);
		this.teams.onRoutines = () => void this.watchers.sync().catch(() => undefined);
		this.sessions.hookUrl = (agent, trigger) => this.hooks.url(agent, trigger);
		this.settings.onChange((next, previous) => {
			if (next.chat.mcp !== previous.chat.mcp || JSON.stringify(next.chat.mcpServers) !== JSON.stringify(previous.chat.mcpServers)) void this.chatMcp.reset();
		});
		this.sessions.policy = {
			projectFor: (cwd) => this.projects.projectFor(cwd),
			modeFor: (cwd) => this.projects.modeFor(cwd),
			rulesFor: (cwd) => this.projects.rulesFor(cwd),
			addRule: (cwd, rule) => this.projects.addRule(cwd, rule),
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
		void this.sessions.startAgents(this.log);
		// Teams that worked in their own folder become projects there (docs/spec/20 PT2).
		for (const team of this.teams.list()) {
			if (this.projects.projectFor(team.cwd)) continue;
			try {
				this.projects.add(team.cwd);
			} catch (error) {
				this.log(`Team ${team.name}: its folder couldn't become a project: ${(error as Error).message}`);
			}
		}
		void this.teams.resume().catch((error: unknown) => this.log(`Teams: ${(error as Error).message}`));
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

	/** A team definition with the projects it works in. */
	private definitionView(id: string) {
		const def = this.teams.definition(id);
		return { ...def, projects: this.teams.usedBy(id).map((t) => ({ teamId: t.id, cwd: t.cwd })) };
	}

	/** A team as the app sees it: its routines with a label, and a webhook's URL. */
	private teamView(team: Team): Team {
		return team.routines?.length ? { ...team, routines: team.routines.map((r) => this.routineView(team.id, r)) } : team;
	}

	private routineView(teamId: string, r: TeamRoutine): TeamRoutine & { label: string; url?: string } {
		const url = r.on === "webhook" && this.hooks.port ? this.hooks.url(teamId, r.id) : undefined;
		return { ...r, label: routineLabel(r), ...(url ? { url } : {}) };
	}

	async stop(): Promise<void> {
		this.telegram?.stop();
		this.watchers?.stop();
		this.teams?.stop();
		for (const conn of this.authed) conn.close();
		await this.backfill;
		for (const off of this.subscriptions.values()) off();
		this.subscriptions.clear();
		await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
		await this.hooks.close();
		await this.sessions.closeAll();
		this.inputReceipts.close();
		this.hub.extraCosts.close();
		await this.chatMcp.close();
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
					unregisterTools = this.app.addToolServer(async (call) => {
						const res = await conn.request("app.tool", call);
						if (!Value.Check(reverseMethods["app.tool"].result, res)) throw new Error("The app's answer wasn't understood.");
						return res;
					});
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

	private async capability(ref: Params<"sessions.open">["ref"], name: "edit" | "regenerate" | "switchBranch" | "removeQueued" | "clearQueue"): Promise<Runtime> {
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
				return (p.fold ? { ...snapshot, items: groupSteps(snapshot.items, keepAlone) } : snapshot) satisfies Result<"sessions.open">;
			}
			case "sessions.subscribe": {
				const p = params as Params<"sessions.subscribe">;
				const runtime = await this.sessions.runtime(p.ref);
				const subscriptionId = `sub_${randomUUID().slice(0, 8)}`;
				let seq = 0;
				// Folded: this subscription sees a turn's tool calls as one steps item.
				const steps = p.fold ? new StepsView((items) => groupSteps(items, keepAlone)) : undefined;
				const snapshot = runtime.snapshot();
				const first = steps ? { ...snapshot, items: steps.snapshot(snapshot.items) } : snapshot;
				const off = runtime.onEvents((events) => {
					const out = steps ? steps.events(events, () => runtime.snapshot().items) : events;
					if (out.length) conn.notify("session.events", { subscriptionId, seq: ++seq, events: out });
				});
				this.subscriptions.set(subscriptionId, off);
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
				const { disposition } = await runtime.submit(p.input.text, {
					whenBusy: p.whenBusy ?? "followUp",
					...(p.clientRequestId ? { requestId: p.clientRequestId } : {}),
					...(p.input.attachments ? { attachments: p.ref.kind === "build" ? p.input.attachments : keepAttachments(this.options.paths.home, p.ref.id, p.input.attachments) } : {}),
				});
				this.sessions.touch(p.ref, isFirst ? p.input.text : undefined);
				return { accepted: true, disposition } satisfies Result<"sessions.submit">;
			}
			case "sessions.abort": {
				const p = params as Params<"sessions.abort">;
				await (await this.sessions.runtime(p.ref)).abort();
				return {};
			}
			case "sessions.debate.continue": {
				const p = params as Params<"sessions.debate.continue">;
				await (await this.sessions.debate(p.ref)).continueDebate(p.rounds);
				return {};
			}
			case "sessions.debate.stop": {
				const p = params as Params<"sessions.debate.stop">;
				await (await this.sessions.debate(p.ref)).stopDebate();
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
			case "sessions.queue.clear": {
				const p = params as Params<"sessions.queue.clear">;
				await this.capability(p.ref, "clearQueue").then((r) => r.clearQueue!());
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
				const change = { ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.removeRule ? { removeRule: p.removeRule } : {}), ...(p.trust !== undefined ? { trust: p.trust } : {}), ...(p.lenses ? { lenses: p.lenses } : {}) };
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
				if (p.ref.kind !== "build") return { commands: await this.sessions.chatCommands() } satisfies Result<"sessions.commands">;
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
				return { files: await searchFiles(this.folder(p), p.query, p.limit ?? 30) } satisfies Result<"projects.files">;
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
					void this.chatMcp.reset();
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
				if (p.scope === "global") void this.chatMcp.reset();
				return {};
			}
			case "mcp.detect":
				return { found: detectOtherApps(new Set(this.mcp.list().servers.map((s) => s.name))) } satisfies Result<"mcp.detect">;
			case "mcp.remove": {
				const p = params as Params<"mcp.remove">;
				this.mcp.remove(p.scope, p.cwd ? this.folder(p) : undefined, p.name);
				if (p.scope === "global") void this.chatMcp.reset();
				return {};
			}
			case "mcp.setEnabled": {
				const p = params as Params<"mcp.setEnabled">;
				this.mcp.setEnabled(p.scope, p.cwd ? this.folder(p) : undefined, p.name, p.enabled);
				if (p.scope === "global") void this.chatMcp.reset();
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
				const agents = [];
				for (const a of this.sessions.list("agent")) {
					const runs = await this.sessions.agentRuns(a.ref).catch(() => undefined);
					if (!runs) continue;
					// Its own schedules read as the agent ("8:00 · Morning briefing").
					const upcoming = runs.upcoming.map((u) => (u.kind === "schedule" ? { ...u, label: "" } : u));
					agents.push({ id: a.ref.id, name: a.title, runs: runs.runs, upcoming, held: runs.outbox.length });
				}
				const projects = this.projects.list().map((x) => ({ id: x.id, name: x.name, routines: this.teams.routines(x.id) }));
				const teams = this.teams.list().map((t) => {
					const place = this.projects.projectFor(t.cwd);
					const name = place ? this.projects.list().find((x) => x.id === place.id)?.name : undefined;
					return { id: t.id, name: t.name, ...(place && name ? { project: { id: place.id, name } } : {}), tasks: t.tasks };
				});
				return buildAgenda({ now: Date.now(), tz: systemZone(), ...(p.since ? { since: Date.parse(p.since) } : {}), agents, projects, teams }) satisfies Result<"home.agenda">;
			}
			case "teams.templates":
				return { templates: this.teams.templates().map((t) => ({ id: t.id, name: t.name, description: t.description, workplace: t.workplace, roles: t.roles, ...(t.source ? { source: t.source } : {}), ...(t.folder ? { folder: t.folder } : {}) })) } satisfies Result<"teams.templates">;
			case "teams.list":
				return { teams: this.teams.list().map((t) => this.teamView(t)) } satisfies Result<"teams.list">;
			case "teams.get": {
				const p = params as Params<"teams.get">;
				return { team: this.teamView(this.teams.get(p.id)) } satisfies Result<"teams.get">;
			}
			case "teams.create": {
				const p = params as Params<"teams.create">;
				const slug = (p.name.trim() || TEAM_TEMPLATES.find((t) => t.id === p.template)?.name || "team").toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";
				let folder = join(this.teamsDir, slug);
				for (let n = 2; existsSync(folder); n++) folder = join(this.teamsDir, `${slug}-${n}`);
				// Every team works in a project (docs/spec/20 PT2): the folder you chose, or a new one named after the team.
				const project = p.cwd ? this.projects.add(p.cwd) : this.projects.create(p.name.trim() || TEAM_TEMPLATES.find((t) => t.id === p.template)?.name || "Team");
				await this.sessions.syncFolder(project.path);
				const team = await this.teams.create({
					name: p.name,
					template: p.template,
					folder,
					cwd: project.path,
					...(p.goal ? { goal: p.goal } : {}),
					...(p.testCommand ? { testCommand: p.testCommand } : {}),
					...(p.memberMode ? { memberMode: p.memberMode } : {}),
					...(p.maxParallel ? { maxParallel: p.maxParallel } : {}),
					...(p.initGit ? { initGit: true } : {}),
					...(p.definition ? { definition: p.definition } : {}),
					...(p.roles?.length ? { roles: p.roles } : {}),
					...(p.style ? { style: p.style } : {}),
					...(p.model ? { model: p.model.provider === "openrouter" ? p.model.id : `${p.model.provider}:${p.model.id}` } : {}),
				});
				return { team: this.teamView(team) } satisfies Result<"teams.create">;
			}
			case "teams.addTask": {
				const p = params as Params<"teams.addTask">;
				const task = await this.teams.createTask(p.id, { title: p.title, brief: p.brief, ...(p.done ? { done: p.done } : {}), ...(p.role ? { role: p.role } : {}) }, "you");
				return { task } satisfies Result<"teams.addTask">;
			}
			case "teams.draft": {
				const p = params as Params<"teams.draft">;
				if (!p.description.trim()) throw new EngineError("INVALID", "Describe the team: who's on it and what it does.");
				return { draft: await draftTeam(p.description, (system, prompt) => this.hub.utility(system, prompt, "team-draft")) } satisfies Result<"teams.draft">;
			}
			case "teams.createDefinition": {
				const p = params as Params<"teams.createDefinition">;
				const name = p.name?.trim() || this.teams.templates().find((t) => t.id === p.template)?.name || "Team";
				const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";
				let folder = join(this.teamsDir, slug);
				for (let n = 2; existsSync(folder); n++) folder = join(this.teamsDir, `${slug}-${n}`);
				const def = this.teams.createDefinition({ ...(p.template ? { template: p.template } : {}), ...(p.name ? { name: p.name } : {}), ...(p.style ? { style: p.style } : {}), ...(p.instructions !== undefined ? { instructions: p.instructions } : {}), ...(p.roles ? { roles: p.roles } : {}) }, folder);
				for (const conn of this.authed) conn.notify("teams.changed", { id: def.id });
				return { definition: this.definitionView(def.id) } satisfies Result<"teams.createDefinition">;
			}
			case "teams.saveTemplate": {
				const p = params as Params<"teams.saveTemplate">;
				return this.teams.saveTemplate(p.id, { ...(p.name ? { name: p.name } : {}), ...(p.description ? { description: p.description } : {}) }) satisfies Result<"teams.saveTemplate">;
			}
			case "teams.definitions":
				return { definitions: this.teams.definitions().map((d) => this.definitionView(d.id)) } satisfies Result<"teams.definitions">;
			case "teams.updateDefinition": {
				const p = params as Params<"teams.updateDefinition">;
				const def = this.teams.updateDefinition(p.id, { ...(p.name !== undefined ? { name: p.name } : {}), ...(p.roles ? { roles: p.roles } : {}), ...(p.model !== undefined ? { model: p.model } : {}), ...(p.saved !== undefined ? { saved: p.saved } : {}), ...(p.reviewLimit !== undefined ? { reviewLimit: p.reviewLimit } : {}), ...(p.budgetPerJob !== undefined ? { budgetPerJob: p.budgetPerJob } : {}), ...(p.memberMode ? { memberMode: p.memberMode } : {}) });
				return { definition: this.definitionView(def.id) } satisfies Result<"teams.updateDefinition">;
			}
			case "teams.removeDefinition": {
				const p = params as Params<"teams.removeDefinition">;
				this.teams.removeDefinition(p.id);
				for (const conn of this.authed) conn.notify("teams.changed", { id: p.id });
				return {} satisfies Result<"teams.removeDefinition">;
			}
			case "teams.update": {
				const p = params as Params<"teams.update">;
				return { team: this.teamView(await this.teams.update(p.id, { ...(p.testCommand !== undefined ? { testCommand: p.testCommand } : {}), ...(p.maxParallel !== undefined ? { maxParallel: p.maxParallel } : {}) })) } satisfies Result<"teams.update">;
			}
			case "teams.remove": {
				const p = params as Params<"teams.remove">;
				await this.teams.remove(p.id);
				this.sessions.detachTeam(p.id);
				return {} satisfies Result<"teams.remove">;
			}
			case "routines.list": {
				const p = params as Params<"routines.list">;
				return { routines: this.teams.routines(p.project).map((r) => this.routineView(p.project, r)) } satisfies Result<"routines.list">;
			}
			case "routines.add": {
				const p = params as Params<"routines.add">;
				this.projects.get(p.project);
				const routine = await this.teams.addRoutine(p.project, { on: p.on, prompt: p.prompt, ...(p.when ? { when: p.when } : {}), ...(p.folder ? { folder: p.folder } : {}), ...(p.from ? { from: p.from } : {}), ...(p.subject ? { subject: p.subject } : {}) }, "you");
				return { routine: this.routineView(p.project, routine) } satisfies Result<"routines.add">;
			}
			case "routines.remove": {
				const p = params as Params<"routines.remove">;
				await this.teams.removeRoutine(p.project, p.routineId);
				return {} satisfies Result<"routines.remove">;
			}
			case "routines.run": {
				const p = params as Params<"routines.run">;
				return (await this.teams.fireRoutine(p.project, p.routineId, "Run by the user.")) satisfies Result<"routines.run">;
			}
			case "teams.promoteMember": {
				const p = params as Params<"teams.promoteMember">;
				const agent = await this.teams.promoteMember(p.id, p.roleId);
				return { agent: { kind: "agent", id: agent } } satisfies Result<"teams.promoteMember">;
			}
			case "teams.draftFor": {
				const p = params as Params<"teams.draftFor">;
				return (await draftFor(p.cwd, p.request ?? "", (system, prompt) => this.hub.utility(system, prompt, "team-draft"), this.sessions.consultAgents())) satisfies Result<"teams.draftFor">;
			}
			case "teams.adopt": {
				const p = params as Params<"teams.adopt">;
				await this.sessions.adoptLead({ kind: "build", id: p.sessionId }, p.id);
				return {} satisfies Result<"teams.adopt">;
			}
			case "teams.fitCheck": {
				const p = params as Params<"teams.fitCheck">;
				return fitCheck(p.cwd) satisfies Result<"teams.fitCheck">;
			}
			case "teams.job": {
				const p = params as Params<"teams.job">;
				return (await this.teams.jobCost(p.id, p.conversationId)) satisfies Result<"teams.job">;
			}
			case "teams.landing": {
				const p = params as Params<"teams.landing">;
				return (await this.teams.landing(p.id)) satisfies Result<"teams.landing">;
			}
			case "teams.land": {
				const p = params as Params<"teams.land">;
				return (await this.teams.land(p.id, p.action)) satisfies Result<"teams.land">;
			}
			case "teams.updateTask": {
				const p = params as Params<"teams.updateTask">;
				await this.teams.updateTask(p.id, p.taskId, { ...(p.state ? { state: p.state } : {}), ...(p.role ? { role: p.role } : {}), ...(p.title ? { title: p.title } : {}), ...(p.brief ? { brief: p.brief } : {}) });
				return {} satisfies Result<"teams.updateTask">;
			}
			case "agents.runs": {
				const p = params as Params<"agents.runs">;
				return (await this.sessions.agentRuns(p.ref)) satisfies Result<"agents.runs">;
			}
			case "agents.runNow": {
				const p = params as Params<"agents.runNow">;
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
			case "inbox.read": {
				const p = params as Params<"inbox.read">;
				await this.sessions.inboxRead(p.items);
				return {} satisfies Result<"inbox.read">;
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
			case "models.verifyKey": {
				const p = params as Params<"models.verifyKey">;
				return (await verifyProviderKey(p.provider, p.key)) satisfies Result<"models.verifyKey">;
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
