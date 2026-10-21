/** Local Engine: Engine Protocol over a Unix domain socket. */
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { existsSync, unlinkSync, chmodSync } from "node:fs";
import { createConnection, createServer, type Server } from "node:net";
import { methods, PROTOCOL_VERSION, reverseMethods, SECRET_OPENROUTER, type MethodName, type Params, type Result } from "@piopio/protocol";
import { Value } from "typebox/value";
import { EngineError, keyHint, ModelHub, providerUsage, verifyProviderKey } from "./models.js";
import { ensureDirs, loadOrCreateToken, type EnginePaths } from "./paths.js";
import { MethodNotFound, RpcConnection } from "./rpc/connection.js";
import { SecretBroker } from "./secrets.js";
import type { Runtime } from "./runtimes/runtime.js";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { listDir, readProjectFile, searchFiles, writeProjectFile } from "./files.js";
import { McpConfig } from "./mcp.js";
import * as gitOps from "./git.js";
import { Projects } from "./projects.js";
import { Sessions } from "./sessions.js";
import { AboutMe } from "./about-me.js";
import { Settings } from "./settings.js";
import { ChatMcp } from "./tools/mcp-chat.js";
import { ChatResources } from "./tools/chat-resources.js";
import { Packages } from "./packages.js";
import { MemoryProviders } from "./memory.js";
import { AgentFiles } from "./agent-files.js";
import { DEFAULT_HOOKS_PORT, Hooks } from "./hooks.js";
import { groupSteps, StepsView } from "./timeline/steps.js";
import type { ToolItem } from "@piopio/protocol";

/** Subagents keep their own card (it opens their session). */
const keepAlone = (tool: ToolItem) => tool.tool === "task";
import { AppServices } from "./app-services.js";
import { TEMPLATES } from "@piopio/runtime";

/** Set by the release bundle (scripts/bundle.mjs); "dev" when running from tsc output. */
declare const PIOPIO_ENGINE_VERSION: string | undefined;
export const ENGINE_VERSION = typeof PIOPIO_ENGINE_VERSION === "string" ? PIOPIO_ENGINE_VERSION : "dev";

export type EngineOptions = {
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
	/** The webhook triggers' port (0: any free one, tests); default PIOPIO_HOOKS_PORT or 47615. */
	hooksPort?: number;
	/** Let web_fetch read localhost (tests). */
	allowPrivateFetch?: boolean;
	log?: (line: string) => void;
};

export class Engine {
	readonly id = randomUUID();
	readonly secrets = new SecretBroker();
	readonly hub: ModelHub;
	readonly sessions: Sessions;
	readonly projects: Projects;
	readonly mcp: McpConfig;
	readonly settings: Settings;
	readonly aboutMe: AboutMe;
	readonly chatMcp: ChatMcp;
	readonly packages: Packages;
	readonly chatResources: ChatResources;
	readonly memory: MemoryProviders;
	readonly hooks: Hooks;
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
		this.hub = new ModelHub(this.secrets, { faux: options.faux ?? false });
		this.sessions = new Sessions(options.paths, this.hub, {
			...(options.piSessionDir ? { piSessionDir: options.piSessionDir } : {}),
			...(options.piAgentDir ? { piAgentDir: options.piAgentDir } : {}),
			...(options.trashDir ? { trashDir: options.trashDir } : {}),
		}, { allowPrivate: options.allowPrivateFetch ?? false });
		this.sessions.onChange((change) => {
			for (const conn of this.authed) conn.notify("catalog.changed", change);
		});
		this.sessions.onInbox = (change) => {
			for (const conn of this.authed) conn.notify("inbox.changed", change);
		};
		this.sessions.onAttention = (change) => {
			for (const conn of this.authed) conn.notify("session.attention", change);
		};
		// A test agent folder: pi's own lookups (MCP config, codemode) read it from the environment.
		if (options.piAgentDir) process.env.PI_CODING_AGENT_DIR = options.piAgentDir;
		const agentDir = options.piAgentDir ?? getAgentDir();
		this.projects = new Projects(options.paths.projectsIndex, agentDir);
		this.mcp = new McpConfig(agentDir);
		this.settings = new Settings(join(options.paths.home, "settings.json"));
		this.memory = new MemoryProviders(join(options.paths.home, "memory.db"), this.mcp, this.settings);
		this.aboutMe = new AboutMe(this.memory, this.settings, join(options.paths.home, "about-me.json"));
		this.chatMcp = new ChatMcp(this.mcp, () => this.settings.get().chat.mcp);
		this.packages = new Packages(agentDir);
		this.chatResources = new ChatResources(agentDir);
		this.packages.onChange(() => void this.chatResources.reload());
		this.sessions.chat = { settings: this.settings, aboutMe: this.aboutMe, mcp: this.chatMcp, resources: this.chatResources };
		this.sessions.agentHost = { files: new AgentFiles(options.agentsDir), memory: this.memory, app: this.app };
		if (options.agentAskTimeoutMs) this.sessions.agentAskTimeoutMs = options.agentAskTimeoutMs;
		this.hooks = new Hooks(join(options.paths.home, "hooks.key"), (agent, trigger, body, delivery) => this.sessions.fireTrigger(agent, trigger, body, delivery), this.log);
		this.settings.onChange((next, previous) => {
			if (next.chat.mcp !== previous.chat.mcp) void this.chatMcp.reset();
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
	}

	async stop(): Promise<void> {
		await this.backfill;
		for (const off of this.subscriptions.values()) off();
		this.subscriptions.clear();
		await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
		await this.hooks.close();
		await this.sessions.closeAll();
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
				unregisterSecrets = this.secrets.addRequester(async (name, purpose) => {
					const res = (await conn.request("secrets.get", { name, purpose } satisfies Params<never> | object)) as { value: string | null };
					return Value.Check(reverseMethods["secrets.get"].result, res) ? res.value : null;
				});
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
			return this.handle(method as MethodName, params, conn, owned);
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

	/** A topic's conversation id, from its ref. */
	private topicOf(ref: Params<"sessions.open">["ref"]): string {
		if (ref.kind !== "space" || !ref.conversationId) throw new EngineError("INVALID", "Give a topic (a Notebook ref with its conversationId).");
		return ref.conversationId;
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
			case "sessions.submit": {
				const p = params as Params<"sessions.submit">;
				const runtime = await this.sessions.runtime(p.ref);
				const isFirst = runtime.snapshot().items.length === 0;
				const { disposition } = await runtime.submit(p.input.text, {
					whenBusy: p.whenBusy ?? "followUp",
					...(p.clientRequestId ? { requestId: p.clientRequestId } : {}),
					...(p.input.attachments ? { attachments: p.input.attachments } : {}),
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
			case "sessions.queue.clear": {
				const p = params as Params<"sessions.queue.clear">;
				await this.capability(p.ref, "clearQueue").then((r) => r.clearQueue!());
				return {};
			}
			case "sessions.configure": {
				const p = params as Params<"sessions.configure">;
				await this.sessions.configure(p.ref, { ...(p.model ? { model: p.model } : {}), ...(p.thinking ? { thinking: p.thinking } : {}), ...(p.web !== undefined ? { web: p.web } : {}), ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.planMode !== undefined ? { planMode: p.planMode } : {}) });
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
				return this.mcp.list(p.cwd ? this.folder(p) : undefined) satisfies Result<"mcp.list">;
			}
			case "mcp.add": {
				const p = params as Params<"mcp.add">;
				const { scope, cwd, name, ...server } = p;
				this.mcp.add(scope, cwd ? this.folder({ cwd }) : undefined, name, server);
				if (scope === "global") void this.chatMcp.reset();
				return {};
			}
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
				return { templates: TEMPLATES.map(({ id, name, avatar, description }) => ({ id, name, avatar, description })) } satisfies Result<"agents.templates">;
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
			case "agents.runs": {
				const p = params as Params<"agents.runs">;
				return (await this.sessions.agentRuns(p.ref)) satisfies Result<"agents.runs">;
			}
			case "agents.runNow": {
				const p = params as Params<"agents.runNow">;
				const run = await (await this.sessions.agent(p.ref)).runNow(p.scheduleId, p.prompt);
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
				const page = await provider.list(p.bank, { ...(p.cursor ? { cursor: p.cursor } : {}), ...(p.kinds ? { kinds: p.kinds as never } : {}) });
				return { records: page.records.map(({ bank: _b, tags: _t, confidence: _c, ...r }) => r), ...(page.cursor ? { cursor: page.cursor } : {}), limited: false } satisfies Result<"memory.list">;
			}
			case "memory.add": {
				const p = params as Params<"memory.add">;
				await this.memory.get(p.provider).retain(p.bank, { content: p.text, kind: "fact", createdBy: "user" });
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
			case "memory.recall": {
				const p = params as Params<"memory.recall">;
				const hits = await this.memory.get(p.provider).recall([p.bank], p.query, { budgetTokens: 2000 });
				return { hits: hits.map((h) => ({ id: h.id, text: h.text, score: h.score, ...(h.at ? { at: h.at } : {}) })) } satisfies Result<"memory.recall">;
			}
			case "threads.dismissSuggestion": {
				const p = params as Params<"threads.dismissSuggestion">;
				this.sessions.dismissSuggestion(p.ref);
				return {};
			}
			case "spaces.importThreads": {
				const p = params as Params<"spaces.importThreads">;
				return { topicIds: await this.sessions.importThreads(p.ref, p.threads, { ...(p.topicId ? { topicId: p.topicId } : {}), keep: p.keepThreads ?? false }) } satisfies Result<"spaces.importThreads">;
			}
			case "spaces.topics.promote": {
				const p = params as Params<"spaces.topics.promote">;
				return { ref: await this.sessions.promoteTopic(p.ref) } satisfies Result<"spaces.topics.promote">;
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
			case "spaces.reroute": {
				const p = params as Params<"spaces.reroute">;
				if (!p.toTopicId === !p.newTopic) throw new EngineError("INVALID", "Give a topic or a new topic's title.");
				await (await this.sessions.space(p.ref)).moveRoute(p.itemId, { ...(p.toTopicId ? { topicId: p.toTopicId } : {}), ...(p.newTopic ? { newTopic: p.newTopic } : {}) });
				return {};
			}
			case "spaces.markRead": {
				const p = params as Params<"spaces.markRead">;
				this.sessions.markRead(p.ref);
				return {};
			}
			case "spaces.configure": {
				const { ref, ...change } = params as Params<"spaces.configure">;
				await this.sessions.configureSpace(ref, change);
				return {};
			}
			case "spaces.memory.get": {
				const p = params as Params<"spaces.memory.get">;
				return (await this.sessions.space(p.ref)).memoryInfo() satisfies Result<"spaces.memory.get">;
			}
			case "spaces.memory.set": {
				const p = params as Params<"spaces.memory.set">;
				await (await this.sessions.space(p.ref)).setMemory(p.text);
				return {};
			}
			case "spaces.memory.undo": {
				const p = params as Params<"spaces.memory.undo">;
				await (await this.sessions.space(p.ref)).undoMemory(p.revisionId);
				return {};
			}
			case "spaces.memory.restore": {
				const p = params as Params<"spaces.memory.restore">;
				await (await this.sessions.space(p.ref)).restoreMemory(p.revisionId);
				return {};
			}
			case "spaces.memory.decide": {
				const p = params as Params<"spaces.memory.decide">;
				await (await this.sessions.space(p.ref)).decideProposal(p.proposalId, p.accept);
				return {};
			}
			case "spaces.topics.rename": {
				const p = params as Params<"spaces.topics.rename">;
				await (await this.sessions.space(p.ref)).renameTopic(this.topicOf(p.ref), p.title);
				return {};
			}
			case "spaces.topics.archive": {
				const p = params as Params<"spaces.topics.archive">;
				await (await this.sessions.space(p.ref)).archiveTopic(this.topicOf(p.ref), p.archived);
				return {};
			}
			case "spaces.topics.merge": {
				const p = params as Params<"spaces.topics.merge">;
				return { summary: await (await this.sessions.space(p.ref)).mergeTopics(this.topicOf(p.ref), p.into) } satisfies Result<"spaces.topics.merge">;
			}
			case "spaces.files.list": {
				const p = params as Params<"spaces.files.list">;
				return { files: (await this.sessions.space(p.ref)).files.list() } satisfies Result<"spaces.files.list">;
			}
			case "spaces.files.add": {
				const { ref, ...file } = params as Params<"spaces.files.add">;
				const space = await this.sessions.space(ref);
				space.files.add(file);
				space.filesChanged();
				return {};
			}
			case "spaces.files.remove": {
				const p = params as Params<"spaces.files.remove">;
				const space = await this.sessions.space(p.ref);
				space.files.remove(p.name);
				space.filesChanged();
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
				return { results: this.sessions.find(p.query, p.limit ?? 30) } satisfies Result<"catalog.search">;
			}
			case "models.verifyKey": {
				const p = params as Params<"models.verifyKey">;
				return (await verifyProviderKey(p.provider, p.key)) satisfies Result<"models.verifyKey">;
			}
			case "models.list": {
				const p = params as Params<"models.list">;
				return { models: await this.hub.listModels(p.refresh ?? false), defaultModel: this.hub.defaultModel } satisfies Result<"models.list">;
			}
			case "secrets.changed": {
				const p = params as Params<"secrets.changed">;
				await this.hub.forgetSecret(p.name);
				return {};
			}
			default:
				throw new MethodNotFound(`Unknown method ${method}`);
		}
	}
}

/** Small holder so the constructor can reference the stream before the connection exists. */
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
