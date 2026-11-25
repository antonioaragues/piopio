/**
 * Agents (docs/spec/06-agents): making one from a template, its definition and Setup, its conversations and runs, its
 * Inbox, memory and trace, agents consulting each other, and moving one to your cloud and back (docs/spec/30 K1).
 * An agent is a catalog entry of kind "agent" whose definition lives in its folder; its runtime is AgentRuntime, which
 * Sessions opens (`host.agent`). Everything this needs from the conversations and the engine comes through
 * `AgentsHost`, which Sessions implements.
 */
import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { CloudMemory, ContainerRef, ModelRef, Params, Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Runtime } from "../runtimes/runtime.js";
import { AgentRuntime } from "../runtimes/agent.js";
import { alwaysLabel, type Envelope, type PeerLog, newDefinition, modelOf, nextFire, validate, TEMPLATES, type AgentDefinition, type DefinitionError, type Watch } from "@piopio/runtime";
import { exportTranscript } from "../export.js";
import type { ConsultBridge } from "../consult.js";
import { type Automation } from "../automations/model.js";
import { CloudAgentView, type CloudLink } from "../cloud.js";
import { TelegramChannels as TelegramSecrets } from "../channels/manager.js";
import type { CatalogEntry } from "./catalog-entry.js";
import type { Sessions } from "../sessions.js";

export interface AgentsHost {
	get(id: string): CatalogEntry | undefined;
	has(id: string): boolean;
	set(id: string, entry: CatalogEntry): void;
	all(): Iterable<CatalogEntry>;
	entry(ref: ContainerRef): CatalogEntry;
	/** The agent's runtime, opened if it isn't (an error for a cloud agent). */
	agent(ref: ContainerRef): Promise<AgentRuntime>;
	/** Runtimes open now, by conversation id; `forgetOpen` drops one (it was closed or moved). */
	isOpen(id: string): boolean;
	opened(id: string): Promise<Runtime> | undefined;
	forgetOpen(id: string): void;
	/** Entries changed: write the catalog; `changed` tells clients about one. */
	save(): void;
	changed(entry: CatalogEntry): void;
	log(line: string): void;
	/** Piopio's data folder. */
	home(): string;
	defaultModel(): ModelRef;
	getModel(provider: string, id: string): unknown;
	onInbox(change: Parameters<NonNullable<Sessions["onInbox"]>>[0]): void;
	onAutomationsMigrated(lines: string[]): void;
	askTimeoutMs(): number | undefined;
	// The engine's services, set after Sessions is made (each may be missing in tests).
	agentHost(): Sessions["agentHost"];
	automations(): Sessions["automations"];
	telegram(): Sessions["telegram"];
	watchers(): Sessions["watchers"];
	secrets(): Sessions["secrets"];
	cloud(): Sessions["cloud"];
}

export class Agents {
	/** Each agent's last valid definition, as the runtime uses it. */
	private readonly definitions = new Map<string, { definition: AgentDefinition; instructions: string }>();
	/** A cloud agent's open conversations, by `<agent>|<conversation>`. */
	private readonly cloudViews = new Map<string, Promise<CloudAgentView>>();

	constructor(private readonly host: AgentsHost) {}

	/** Agent folders and memory: an error if the engine didn't set them up. */
	private get services(): NonNullable<ReturnType<AgentsHost["agentHost"]>> {
		const services = this.host.agentHost();
		if (!services) throw new EngineError("INTERNAL", "Agents aren't set up in this engine.");
		return services;
	}

	/** A conversation left the catalog: its definition goes from the cache. */
	forget(id: string): void {
		this.definitions.delete(id);
	}

	// ── Agents (docs/spec/06-agents) ──

	/** A new local agent from a template (or from scratch): its folder, its git repo, its catalog entry. */
	async createAgent(params: { name: string; template?: string; avatar?: string; model?: ModelRef; owner?: string; instructions?: string; schedule?: string | null }): Promise<ContainerRef> {
		const name = params.name.trim();
		if (!name) throw new EngineError("INVALID", "The agent needs a name.");
		if (params.template && !TEMPLATES.some((t) => t.id === params.template)) throw new EngineError("INVALID", `No template “${params.template}”.`);
		const id = `agt_${randomUUID().replaceAll("-", "").slice(0, 16)}`;
		const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "agent";
		const model = params.model ?? this.host.defaultModel();
		const folder = this.services.files.folderFor(slug);
		// Nothing said yet (no template, no instructions): it interviews the owner and sets itself up (docs/spec/19 S2).
		const interview = !params.template && !params.instructions?.trim();
		const made = newDefinition({ id, slug: basename(folder), name, owner: params.owner?.trim() || "Owner", model: model.provider === "openrouter" ? model.id : `${model.provider}:${model.id}`, ...(params.template ? { template: params.template } : {}), ...(params.avatar ? { avatar: params.avatar } : {}), ...(params.instructions !== undefined ? { instructions: params.instructions } : {}), ...(params.schedule !== undefined ? { schedule: params.schedule } : {}), ...(interview ? { interview: true } : {}) });
		// A template's schedule is an automation the agent runs (docs/spec/27 AU2), not part of who it is.
		const scheduled = this.host.automations() && made.definition.schedules?.length ? (await import("../automations/migrate.js")).fromAgent({ id, name, definition: made.definition }, { reminders: [], watches: [], runs: [] }, Date.now()).automations : [];
		if (this.host.automations()) delete made.definition.schedules;
		await this.services.files.create(folder, made);
		this.definitions.set(id, made);
		const now = new Date().toISOString();
		const entry: CatalogEntry = { ref: { kind: "agent", id }, title: name, createdAt: now, updatedAt: now, file: join(this.host.home(), "agents", `${id}.sqlite`), agentFolder: folder };
		mkdirSync(dirname(entry.file!), { recursive: true });
		this.setAgentInfo(entry, made.definition);
		this.host.set(id, entry);
		this.host.save();
		this.host.changed(entry);
		if (scheduled.length) this.host.automations()!.adopt(scheduled.map((a) => ({ ...a, fresh: true })), []);
		if (interview) {
			const owner = made.definition.contacts[0]!.name;
			const hi = owner && owner !== "Owner" ? `Hi ${owner}!` : "Hi!";
			// "What should I do for you?" with three ideas to tap (docs/spec/21 D4, design 5a); or their own words.
			await (await this.host.agent(entry.ref)).greet(`${hi} What should I do for you? Pick an idea, or tell me in your own words.`, [
				"Every morning, tell me what's ahead",
				"Watch my email and warn me about bills",
				"Keep a shared list for the family",
			]);
		}
		return entry.ref;
	}

	/** `set_up` from the agent itself (docs/spec/19 S2): saved like an edit, and the interview ends once it has instructions. */
	async updateAgentSelf(id: string, change: { name?: string; description?: string; avatar?: string; instructions?: string }) {
		const { definition, instructions } = this.agentDefinition(id);
		const body = instructions.replace(/^#[^\n]*\n+/, "").trim();
		const previous = { name: definition.name, ...(definition.description ? { description: definition.description } : {}), ...(definition.avatar ? { avatar: definition.avatar } : {}), instructions: body };
		const next = structuredClone(definition);
		if (change.name) next.name = change.name;
		if (change.description) next.description = change.description;
		if (change.avatar) next.avatar = change.avatar;
		if (change.instructions) delete next.interview;
		const text = `# ${next.name}\n\n${change.instructions ?? body}\n`;
		const result = await this.saveAgent({ kind: "agent", id }, next, text, change.instructions ? "Set itself up" : "Change its name or line");
		if (!result.saved && result.errors.length) throw new Error(result.errors.map((e) => e.message).join(" "));
		return previous;
	}

	/** The definition as it is on disk, its errors and history. */
	async getAgent(ref: ContainerRef): Promise<{ definition: unknown; instructions: string; folder: string; errors: DefinitionError[]; history: { commit: string; at: string; message: string }[] }> {
		const entry = this.host.entry({ kind: "agent", id: ref.id });
		const folder = entry.agentFolder!;
		let definition: unknown;
		let instructions = "";
		let errors: DefinitionError[];
		try {
			const read = this.services.files.read(folder);
			definition = read.definition;
			instructions = read.instructions;
			errors = this.validateAgent(definition, ref.id);
		} catch (error) {
			definition = this.definitions.get(ref.id)?.definition ?? {};
			errors = [{ path: "/", message: `agent.json can't be read: ${(error as Error).message}` }];
		}
		return { definition, instructions, folder, errors, history: await this.services.files.history(folder) };
	}

	/** Validates; with no errors, writes, commits and reconfigures the running agent. */
	async saveAgent(ref: ContainerRef, definition: unknown, instructions: string, message?: string): Promise<{ errors: DefinitionError[]; saved: boolean }> {
		const entry = this.host.entry({ kind: "agent", id: ref.id });
		const def = definition as AgentDefinition;
		const errors = this.validateAgent(definition, ref.id);
		if (!errors.length && def.id !== ref.id) errors.push({ path: "/id", message: "The id can't change." });
		if (errors.length) return { errors, saved: false };
		const saved = await this.services.files.save(entry.agentFolder!, { definition: def, instructions }, message?.trim() || "Edit the definition");
		const toolsBefore = this.definitions.get(ref.id)?.definition.tools;
		this.definitions.set(ref.id, { definition: def, instructions });
		entry.title = def.name;
		this.setAgentInfo(entry, def);
		entry.updatedAt = new Date().toISOString();
		this.host.save();
		this.host.changed(entry);
		if (entry.cloud) {
			// It runs in your cloud: the change goes up as data (its schedules there stay unless this one has some).
			await this.cloudLink().call(ref.id, "agents.deploy", { ref: { kind: "agent", id: ref.id }, definition: def, instructions });
			return { errors: [], saved };
		}
		if (this.host.isOpen(ref.id)) await (await this.host.agent(ref)).reconfigure();
		// Tools switched on or off: a note in the owner's chat, so the agent stops going by what it said before.
		if (toolsBefore && JSON.stringify(toolsBefore) !== JSON.stringify(def.tools)) await (await this.host.agent(ref)).core.switchesChanged(toolsBefore).catch((error: unknown) => this.host.log(`Agents: couldn't note ${def.name}'s tool change: ${(error as Error).message}`));
		// Schedules, a heartbeat or webhook triggers written into the definition become its automations (docs/spec/27);
		// opening the agent hands them over.
		if (this.host.automations() && (def.schedules?.length || def.heartbeat || def.triggers?.length)) {
			if (this.host.isOpen(ref.id)) await this.handOverToAutomations(ref.id, await this.host.agent(ref));
			else await this.host.agent(ref);
		}
		await this.host.telegram()?.sync();
		return { errors: [], saved };
	}

	async agentConversations(ref: ContainerRef) {
		if (this.host.get(ref.id)?.cloud) return (await this.cloudLink().call(ref.id, "agents.conversations", { ref: { kind: "agent", id: ref.id } })).people;
		const def = this.agentDefinition(ref.id).definition;
		const runtime = await this.host.agent(ref);
		const people = await runtime.people();
		const humans = def.contacts.map((c) => {
			const p = people.find((x) => x.contactId === c.id);
			return { contactId: c.id, name: c.name, role: c.role, conversationId: `person:${c.id}`, started: p?.started ?? false, ...(p?.lastAt ? { lastAt: p.lastAt } : {}), ...(p?.preview ? { preview: p.preview } : {}) };
		});
		const agents = (await runtime.peers()).map((a) => ({ contactId: `agent:${a.id}`, name: a.name, role: "agent" as const, conversationId: `agent:${a.id}`, started: true, ...(a.lastAt ? { lastAt: a.lastAt } : {}), ...(a.preview ? { preview: a.preview } : {}) }));
		return [...humans, ...agents];
	}

	/** Runs, held messages and what fires next (the Runs tab). */
	async agentRuns(ref: ContainerRef) {
		if (this.host.get(ref.id)?.cloud) return this.cloudLink().call(ref.id, "agents.runs", { ref: { kind: "agent", id: ref.id } });
		const { runs, outbox, upcoming } = await (await this.host.agent(ref)).runs();
		const iso = (t: number) => new Date(t).toISOString();
		// A schedule the runtime hasn't armed yet has no next time: it comes from its cron (Home, the agent page).
		const schedules = (() => {
			try {
				return this.agentDefinition(ref.id).definition.schedules ?? [];
			} catch {
				return [];
			}
		})();
		for (const u of upcoming) {
			if (u.next || u.kind !== "schedule") continue;
			const s = schedules.find((x) => x.id === u.id);
			try {
				if (s) u.next = nextFire(s.cron, s.tz ?? Intl.DateTimeFormat().resolvedOptions().timeZone, Date.now());
			} catch {
				// a cron that never fires
			}
		}
		return {
			runs: runs.map(({ conversationId: _c, deliverTo: _d, ...r }) => r),
			outbox: outbox.map((o) => ({ id: o.id, to: o.to, text: o.text, notBefore: iso(o.notBefore), reason: o.reason })),
			upcoming: upcoming.map((u) => ({ id: u.id, kind: u.kind, label: u.label, ...(u.next ? { next: iso(u.next) } : {}), ...(u.cron ? { cron: u.cron } : {}) })),
		};
	}

	/**
	 * An agent's schedules, heartbeat and webhook triggers (its definition), and the reminders and watches it set itself,
	 * become automations it runs (docs/spec/27 §6), once. The definition keeps a copy beside it as it was.
	 */
	async handOverToAutomations(id: string, agent: AgentRuntime): Promise<void> {
		const automations = this.host.automations();
		if (!automations) return;
		const { definition } = this.agentDefinition(id);
		const fromDefinition = Boolean(definition.schedules?.length || definition.heartbeat || definition.triggers?.length);
		const legacy = await agent.handOver();
		if (!fromDefinition && !legacy.reminders.length && !legacy.watches.length) return;
		const { fromAgent } = await import("../automations/migrate.js");
		const migrated = fromAgent({ id, name: definition.name, definition }, legacy, Date.now());
		automations.adopt(migrated.automations, migrated.runs);
		if (fromDefinition) {
			// Written here, not through saveAgent: this runs while the agent opens, and saveAgent would wait for it.
			const entry = this.host.entry({ kind: "agent", id });
			const { instructions } = this.agentDefinition(id);
			const next = structuredClone(definition);
			delete next.schedules;
			delete next.heartbeat;
			delete next.triggers;
			if (entry.agentFolder) {
				writeFileSync(join(entry.agentFolder, "definition.before-27.json"), JSON.stringify(definition, null, "\t"));
				await this.services.files.save(entry.agentFolder, { definition: next, instructions }, "Schedules became automations");
			}
			this.definitions.set(id, { definition: next, instructions });
			this.setAgentInfo(entry, next);
			this.host.save();
			this.host.changed(entry);
			await agent.reconfigure();
		}
		this.host.onAutomationsMigrated(migrated.lines);
	}

	/** After the Mac slept: every open agent runs what fell due meanwhile. */
	async woke(): Promise<void> {
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent" && !e.cloud && this.host.isOpen(e.ref.id))) {
			await this.host
				.agent(entry.ref)
				.then((agent) => agent.woke())
				.catch((error: unknown) => this.host.log(`Agent ${entry.title}: couldn't catch up after sleep: ${(error as Error).message}`));
		}
	}

	/** Opens every agent, so their schedules, reminders and held messages run while the app is closed (06 §6). */
	async startAgents(log: (line: string) => void): Promise<void> {
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent" && !e.cloud)) {
			await this.host.agent(entry.ref).catch((error: unknown) => log(`Agent ${entry.title}: couldn't start: ${(error as Error).message}`));
			await this.agentStatus(entry);
		}
		await this.host.telegram()?.sync().catch((error: unknown) => log(`Telegram: ${(error as Error).message}`));
		await this.host.watchers()?.sync().catch((error: unknown) => log(`Routines: ${(error as Error).message}`));
	}

	/** Every open agent's event routines (watchers.ts). */
	async agentWatches(): Promise<{ agentId: string; watches: Watch[] }[]> {
		const out = [];
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent" && this.host.isOpen(e.ref.id))) {
			out.push({ agentId: entry.ref.id, watches: await (await this.host.agent(entry.ref)).watches() });
		}
		return out;
	}

	/** Local agents and their definitions (channels). */
	agentList(): { id: string; name: string; definition: AgentDefinition }[] {
		return [...this.host.all()]
			.filter((e) => e.ref.kind === "agent")
			.flatMap((e) => {
				try {
					return [{ id: e.ref.id, name: e.title, definition: this.agentDefinition(e.ref.id).definition }];
				} catch {
					return [];
				}
			});
	}

	// ── Your cloud (docs/spec/30 K1) ──

	isCloud(id: string): boolean {
		return Boolean(this.host.get(id)?.cloud);
	}

	/** Approvals already announced from the cloud, by agent (so each notifies once). */
	private cloudApprovals = new Map<string, Set<string>>();

	/**
	 * A cloud agent's status into the catalog (paused, spend, Inbox, next run), as `agentStatus` does for the Mac's,
	 * and a notification for each approval it asks for. The engine calls it every minute and after anything you do to it.
	 */
	async refreshCloudAgent(id: string): Promise<void> {
		const entry = this.host.get(id);
		const cloud = this.host.cloud();
		if (!entry?.cloud || !entry.agent || !cloud?.connected) return;
		const ref: ContainerRef = { kind: "agent", id };
		const status = await cloud.call(id, "agents.status", { ref }).catch(() => undefined);
		if (!status || !this.host.get(id)?.cloud) return;
		const changed = JSON.stringify(status) !== JSON.stringify(entry.agent.status);
		entry.agent.status = status;
		if (changed) {
			this.host.save();
			this.host.changed(entry);
		}
		let fresh: { approvalId: string; title: string } | undefined;
		if (status.inbox > 0) {
			const inbox = await cloud.call(id, "inbox.list", {}).catch(() => undefined);
			const seen = this.cloudApprovals.get(id) ?? new Set<string>();
			for (const item of inbox?.items ?? []) {
				const a = item.approval;
				if (!a || a.status !== "pending" || seen.has(a.approvalId)) continue;
				seen.add(a.approvalId);
				fresh ??= { approvalId: a.approvalId, title: a.title };
			}
			this.cloudApprovals.set(id, seen);
		}
		this.host.onInbox({ count: this.inboxCount(), ...(fresh ? { approval: { agent: ref, agentName: entry.title, ...fresh } } : {}) });
	}

	/** Every cloud agent's status (the engine's minute tick). */
	async refreshCloudAgents(): Promise<void> {
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent" && e.cloud)) await this.refreshCloudAgent(entry.ref.id).catch(() => undefined);
	}

	/** Calls a cloud agent's object, then reads its status again (Run now, pause, an approval, Undo). */
	async cloudAgentCall<M extends "agents.runNow" | "agents.pause" | "agents.decide" | "agents.undo">(id: string, method: M, params: Params<M>): Promise<Result<M>> {
		const result = await this.cloudLink().call(id, method, params);
		await this.refreshCloudAgent(id);
		return result;
	}

	private cloudLink(): CloudLink {
		const cloud = this.host.cloud();
		if (!cloud?.connected) throw new EngineError("INVALID", "No cloud is connected. Connect one in Settings › This Mac & cloud.");
		return cloud;
	}

	/** A cloud agent's conversation, opened through its socket (one per conversation, shared by subscribers). */
	cloudView(ref: ContainerRef): Promise<CloudAgentView> {
		const key = `${ref.id}|${ref.conversationId ?? ""}`;
		let view = this.cloudViews.get(key);
		if (!view) {
			view = CloudAgentView.open(this.cloudLink(), ref);
			view.catch(() => this.cloudViews.delete(key));
			this.cloudViews.set(key, view);
		}
		return view;
	}

	private async closeCloudViews(id: string): Promise<void> {
		for (const [key, view] of [...this.cloudViews]) {
			if (!key.startsWith(`${id}|`)) continue;
			this.cloudViews.delete(key);
			await (await view.catch(() => undefined))?.close();
		}
	}

	/** Moves an agent to your cloud or back to this Mac (docs/spec/30 §3.2). What moved, in lines. */
	async moveAgent(ref: ContainerRef, to: "cloud" | "local"): Promise<string[]> {
		const cloud = this.cloudLink();
		const entry = this.host.entry({ kind: "agent", id: ref.id });
		if (to === "cloud") {
			if (entry.cloud) throw new EngineError("INVALID", `${entry.title} already runs in your cloud.`);
			return this.moveUp(entry, cloud);
		}
		if (!entry.cloud) throw new EngineError("INVALID", `${entry.title} already runs on this Mac.`);
		return this.moveDown(entry, cloud);
	}

	private async moveUp(entry: CatalogEntry, cloud: CloudLink): Promise<string[]> {
		const id = entry.ref.id;
		const ref: ContainerRef = { kind: "agent", id };
		const local = await this.host.agent(ref);
		if (local.snapshot().state.status === "running" || (await local.runs()).runs.some((r) => r.status === "running")) throw new EngineError("BUSY", `${entry.title} is working. Move it when it's done.`);
		const { definition, instructions } = this.agentDefinition(id);
		const def = structuredClone(definition);
		const lines: string[] = [];

		// Its model: the cloud reaches API-key providers through OpenRouter; anything else needs this Mac.
		const socket = cloud.agent(id);
		const hello = await socket.hello();
		const model = modelOf(def.models.default);
		if (model.provider !== "openrouter") {
			const fallback = hello.capabilities.models[0] ?? "openrouter/anthropic/claude-haiku-5.5";
			const slash = fallback.indexOf("/");
			const [provider, modelId] = [fallback.slice(0, slash), fallback.slice(slash + 1)];
			def.models.default = provider === "openrouter" ? modelId : `${provider}:${modelId}`;
			lines.push(`Its model (${model.modelId}) needs this Mac, so in the cloud it uses ${modelId}. Change it in its definition.`);
		}

		// Automations at a time go up as its schedules and reminders; the ones that watch something here stay, off.
		const mine = this.host.automations()?.list().filter((a) => a.runsAs === id) ?? [];
		const schedules: NonNullable<AgentDefinition["schedules"]> = [];
		const reminders: { id: string; prompt: string; at: number; tz?: string; deliverTo?: string; createdAt: string; by: string }[] = [];
		const parked: Automation[] = [];
		for (const a of mine) {
			if (a.on === "time" && a.enabled && a.cron) schedules.push({ id: a.id.toLowerCase().replace(/[^a-z0-9_-]/g, "") || "schedule", cron: a.cron, ...(a.tz ? { tz: a.tz } : {}), prompt: a.prompt, ...(a.deliverTo ? { deliverTo: a.deliverTo } : {}) });
			else if (a.on === "time" && a.enabled && a.at !== undefined) reminders.push({ id: a.id, prompt: a.prompt, at: a.at, ...(a.tz ? { tz: a.tz } : {}), ...(a.deliverTo ? { deliverTo: a.deliverTo } : {}), createdAt: a.createdAt, by: a.by === "you" ? "owner" : a.by });
			else {
				parked.push(a);
				lines.push(a.on === "time" ? `“${a.name}” is off, so it stays on this Mac.` : `“${a.name}” watches ${a.on === "folder" ? "a folder" : a.on === "email" ? "your email" : "a URL"} on this Mac, so it stays here, off, until ${entry.title} comes back.`);
			}
		}
		def.schedules = schedules;
		if (schedules.length || reminders.length) lines.push(`Automations: ${schedules.length + reminders.length} now run in the cloud.`);

		// Memory, from the built-in provider (the others aren't reachable from the cloud yet).
		const provider = def.memory?.provider ?? "builtin";
		const memory: CloudMemory[] = [];
		const prefix = `${id}/`;
		const builtin = this.services.memory.builtin;
		if (provider === "builtin") {
			for (const { bank } of builtin.banks().filter((b) => b.bank.startsWith(prefix))) {
				let cursor: string | undefined;
				do {
					const page = await builtin.list(bank, { limit: 200, ...(cursor ? { cursor } : {}) });
					for (const r of page.records) if (!r.endedAt) memory.push({ partition: bank.slice(prefix.length), text: r.text, kind: r.kind, createdBy: r.createdBy, at: r.at, ...(r.tags?.length ? { tags: r.tags } : {}), ...(r.pinned ? { pinned: true } : {}) });
					cursor = page.cursor;
				} while (cursor);
			}
		} else lines.push(`Its memory is in ${provider}, which the cloud can't reach yet: there it starts with none.`);

		// Telegram: the cloud reads the bot by webhook; this Mac stops polling it.
		const bot = def.channels?.telegram?.bot;
		const token = bot?.startsWith("secret:") ? await this.host.secrets()?.get(bot.slice("secret:".length), `Telegram for ${entry.title}`) : undefined;

		const deployed = await cloud.call(id, "agents.deploy", { ref, definition: def, instructions, memory, reminders, ...(token ? { telegram: { token } } : {}) });
		lines.push(...deployed.lines.filter((l) => !l.startsWith("Reminders:")));

		// Up there now: nothing of it runs here.
		for (const a of mine) this.host.automations()!.remove(a.id);
		if (provider === "builtin") for (const { bank } of builtin.banks().filter((b) => b.bank.startsWith(prefix))) builtin.wipe(bank);
		this.host.forgetOpen(id);
		await local.close();
		if (def.models.default !== definition.models.default) {
			const next = { ...structuredClone(definition), models: { ...definition.models, default: def.models.default } };
			await this.services.files.save(entry.agentFolder!, { definition: next, instructions }, "Moved to the cloud: a model it can use there");
			this.definitions.set(id, { definition: next, instructions });
		}
		entry.cloud = { deployedAt: deployed.deployedAt, ...(parked.length ? { parked } : {}) };
		this.setAgentInfo(entry, this.agentDefinition(id).definition);
		this.host.save();
		this.host.changed(entry);
		await this.host.telegram()?.sync();
		await this.refreshCloudAgent(id);
		return [`${entry.title} runs in your cloud now: it keeps going with your Mac off.`, ...lines];
	}

	private async moveDown(entry: CatalogEntry, cloud: CloudLink): Promise<string[]> {
		const id = entry.ref.id;
		const ref: ContainerRef = { kind: "agent", id };
		const exported = await cloud.call(id, "agents.export", { ref });
		const cloudDef = exported.definition as AgentDefinition;
		const lines: string[] = [];

		// Its conversations up there are kept as text in its folder (the Mac shows the ones from before it went up).
		const people = await this.agentConversations(ref).catch(() => []);
		const kept: string[] = [];
		for (const person of people.filter((p) => p.started)) {
			const view = await this.cloudView({ ...ref, conversationId: person.conversationId }).catch(() => undefined);
			const items = view?.snapshot().items ?? [];
			if (!items.length) continue;
			const file = exportTranscript(`${entry.title} with ${person.name} (cloud)`, items, "markdown", { what: "conversation", speaker: entry.title });
			const dir = join(entry.agentFolder!, "cloud-conversations");
			mkdirSync(dir, { recursive: true });
			writeFileSync(join(dir, `${new Date().toISOString().slice(0, 10)} ${file.filename}`), file.content);
			kept.push(person.name);
		}
		if (kept.length) lines.push(`Its conversations in the cloud (with ${kept.join(", ")}) are saved as text in its folder, under cloud-conversations.`);

		// The definition as the cloud had it; its schedules and reminders become automations here again.
		const { fromAgent } = await import("../automations/migrate.js");
		const migrated = fromAgent({ id, name: cloudDef.name, definition: cloudDef }, { reminders: exported.reminders as never[], watches: [], runs: [] }, Date.now());
		const next = structuredClone(cloudDef);
		delete next.schedules;
		delete next.heartbeat;
		delete next.triggers;
		const secrets = this.host.secrets();
		if (exported.telegram && secrets) {
			const name = TelegramSecrets.secretName(id);
			await secrets.set(name, exported.telegram.token);
			next.channels = { ...next.channels, telegram: { bot: `secret:${name}` } };
		}
		await this.services.files.save(entry.agentFolder!, { definition: next, instructions: exported.instructions }, "Moved back from the cloud");
		this.definitions.set(id, { definition: next, instructions: exported.instructions });

		const builtin = this.services.memory.builtin;
		if ((next.memory?.provider ?? "builtin") === "builtin") {
			for (const r of exported.memory) await builtin.retain(`${id}/${r.partition}`, { content: r.text, kind: r.kind as never, createdBy: r.createdBy, at: r.at, ...(r.tags ? { tags: r.tags } : {}), ...(r.pinned ? { pinned: true } : {}) });
			if (exported.memory.length) lines.push(`Memory: ${exported.memory.length} ${exported.memory.length === 1 ? "record" : "records"}.`);
		}
		const parked = entry.cloud?.parked ?? [];
		const automations = this.host.automations();
		if (automations && (migrated.automations.length || parked.length)) {
			automations.adopt([...migrated.automations, ...parked], []);
			lines.push(`Automations: ${migrated.automations.length + parked.length} run on this Mac again.`);
		}

		await cloud.call(id, "agents.retire", { ref });
		this.cloudApprovals.delete(id);
		await this.closeCloudViews(id);
		cloud.drop(id);
		delete entry.cloud;
		this.setAgentInfo(entry, next);
		this.host.save();
		this.host.changed(entry);
		await this.host.agent(ref);
		await this.host.telegram()?.sync();
		return [`${entry.title} runs on this Mac again: it stops while your Mac sleeps or is off.`, ...lines];
	}

	/** Changes an agent's definition in code (channels pairing), saved like an edit. */
	async changeAgent(id: string, change: (def: AgentDefinition) => void, message: string): Promise<void> {
		const { definition, instructions } = this.agentDefinition(id);
		const next = structuredClone(definition);
		change(next);
		const result = await this.saveAgent({ kind: "agent", id }, next, instructions, message);
		if (!result.saved && result.errors.length) throw new EngineError("INVALID", result.errors.map((e) => e.message).join(" "));
	}

	/** Your agents, for drafts that suggest them (docs/spec/21 D7). */
	consultAgents() {
		return this.consultBridge().agents();
	}

	/** Answers your conversations wait for (docs/spec/21 D6), by request id. */
	private readonly consulting = new Map<string, (reply: string) => void>();

	/** Your agents, asked from a conversation: each answers in its conversation with Piopio. */
	consultBridge(): ConsultBridge {
		return {
			agents: () =>
				[...this.host.all()].flatMap((e) => {
					if (e.ref.kind !== "agent") return [];
					try {
						const def = this.agentDefinition(e.ref.id).definition;
						return def.interview ? [] : [{ id: e.ref.id, name: def.name, ...(def.description ? { description: def.description } : {}) }];
					} catch {
						return [];
					}
				}),
			ask: async (agentId, message, from) => {
				const def = this.agentDefinition(agentId).definition;
				const requestId = `amsg_${randomUUID().slice(0, 12)}`;
				const envelope: Envelope = {
					id: requestId,
					mode: "ask",
					from: { id: "piopio", name: "Piopio" },
					to: { id: agentId, name: def.name },
					text: `For the user, from their conversation “${from}”:\n\n${message}`,
					traceId: `tr_${randomUUID().slice(0, 12)}`,
					hop: 1,
					requestId,
					at: new Date().toISOString(),
				};
				let timer: ReturnType<typeof setTimeout> | undefined;
				const answer = new Promise<string | undefined>((resolve) => {
					this.consulting.set(requestId, resolve);
					timer = setTimeout(() => resolve(undefined), this.host.askTimeoutMs() ?? 10 * 60_000);
				});
				try {
					await (await this.host.agent({ kind: "agent", id: agentId })).core.peers.receive(envelope);
					return await answer;
				} finally {
					clearTimeout(timer);
					this.consulting.delete(requestId);
				}
			},
		};
	}

	/** Agents reaching each other in this engine (06 §7 AA7): who they are, delivery, a trace's cost, shared memory. */
	peerHost() {
		const agents = () => [...this.host.all()].filter((e) => e.ref.kind === "agent");
		const defOf = (id: string) => {
			try {
				return this.agentDefinition(id).definition;
			} catch {
				return undefined;
			}
		};
		return {
			directory: async () =>
				agents().flatMap((e) => {
					const def = defOf(e.ref.id);
					return def ? [{ id: def.id, slug: def.slug, name: def.name, ...(def.acceptFrom ? { acceptFrom: def.acceptFrom } : {}) }] : [];
				}),
			deliver: async (to: string, envelope: Envelope) => {
				// An answer to one of your conversations (consultBridge).
				if (to === "piopio" && envelope.mode === "reply") {
					this.consulting.get(envelope.requestId ?? "")?.(envelope.text);
					return;
				}
				if (this.host.get(to)?.ref.kind !== "agent") throw new Error("No such agent.");
				await (await this.host.agent({ kind: "agent", id: to })).core.peers.receive(envelope);
			},
			traceCost: async (traceId: string) => (await this.traceLogs(traceId)).reduce((n, l) => n + (l.costUsd ?? 0), 0),
			sharedBanks: async (agentId: string) => {
				const me = defOf(agentId);
				return agents().flatMap((e) => {
					const share = defOf(e.ref.id)?.shareMemory;
					const parts = share?.[agentId] ?? (me ? share?.[me.slug] : undefined) ?? [];
					return e.ref.id === agentId ? [] : parts.map((p) => `${e.ref.id}/${p}`);
				});
			},
		};
	}

	/** A trace's messages from every agent's log: the receiver's entry (with its answer and cost) wins. */
	private async traceLogs(traceId: string): Promise<PeerLog[]> {
		const byId = new Map<string, PeerLog>();
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent")) {
			const runtime = await this.host.agent(entry.ref).catch(() => undefined);
			for (const l of (await runtime?.core.peers.logs()) ?? []) {
				if (l.traceId !== traceId) continue;
				const had = byId.get(l.id);
				if (!had || l.side === "in") byId.set(l.id, had && l.side === "in" ? { ...had, ...l, reply: l.reply ?? had.reply } : l);
			}
		}
		return [...byId.values()].sort((a, b) => a.at.localeCompare(b.at));
	}

	/** The trace view (AA5). */
	async agentTrace(traceId: string) {
		const logs = await this.traceLogs(traceId);
		if (!logs.length) throw new EngineError("NOT_FOUND", "No such trace.");
		return {
			traceId,
			costUsd: logs.reduce((n, l) => n + (l.costUsd ?? 0), 0),
			hops: logs
				.filter((l) => l.mode !== "reply")
				.map((l) => ({ id: l.id, ...(l.parent ? { parent: l.parent } : {}), hop: l.hop, mode: l.mode, from: l.from, to: l.to, text: l.text, ...(l.reply ? { reply: l.reply } : {}), at: l.at, status: l.status, ...(l.costUsd !== undefined ? { costUsd: l.costUsd } : {}), ...(l.error ? { error: l.error } : {}) })),
		};
	}

	/** Pause, spend and the Inbox count, from the running agent into the catalog (sidebar, header, badges). */
	async agentStatus(entry: CatalogEntry): Promise<void> {
		const runtime = await this.host.opened(entry.ref.id)?.catch(() => undefined);
		if (!(runtime instanceof AgentRuntime) || !entry.agent) return;
		const safety = await runtime.core.safety.status().catch(() => undefined);
		if (!safety || !this.host.has(entry.ref.id)) return;
		// What fires next (the sidebar's "Next run tomorrow 7:00").
		const next = (await runtime.runs().catch(() => undefined))?.upcoming.map((u) => u.next).filter((n): n is number => typeof n === "number").sort((a, b) => a - b)[0];
		const status = { ...safety, ...(next && !safety.paused ? { nextRun: new Date(next).toISOString() } : {}) };
		const changed = JSON.stringify(status) !== JSON.stringify(entry.agent.status);
		entry.agent.status = status;
		if (changed) {
			this.host.save();
			this.host.changed(entry);
		}
		this.host.onInbox({ count: this.inboxCount() });
	}

	/** What waits for you across agents. */
	inboxCount(): number {
		return [...this.host.all()].reduce((n, e) => n + (e.ref.kind === "agent" ? (e.agent?.status?.inbox ?? 0) : 0), 0);
	}

	/** The Inbox (06 §12): every agent's entries, newest first. */
	async inbox() {
		const items = [];
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent")) {
			const runtime = await this.host.agent(entry.ref).catch(() => undefined);
			if (!runtime) continue;
			const def = runtime.definition();
			for (const e of await runtime.core.safety.entries()) {
				const a = e.approval;
				items.push({
					id: e.id,
					agent: entry.ref,
					agentName: entry.title,
					...(entry.agent?.avatar ? { avatar: entry.agent.avatar } : {}),
					kind: e.kind,
					at: e.at,
					title: e.title,
					body: e.body,
					needsYou: e.needsYou && (a ? true : !e.read),
					read: e.read ?? false,
					...(e.conversation ? { conversationId: e.conversation } : {}),
					...(a
						? {
								approval: {
									kind: "approval" as const,
									id: `approval:${a.id}`,
									at: a.requestedAt,
									approvalId: a.id,
									tool: a.tool,
									title: a.title,
									args: a.args,
									status: a.status,
									...(a.editedArgs ? { editedArgs: a.editedArgs } : {}),
									...(a.reason ? { reason: a.reason } : {}),
									expiresAt: new Date(a.expiresAt).toISOString(),
									always: alwaysLabel(a.key, def),
								},
							}
						: {}),
				});
			}
		}
		// Agents in your cloud keep their own Inbox (docs/spec/30 K1); one that can't be reached right now shows none.
		for (const entry of [...this.host.all()].filter((e) => e.ref.kind === "agent" && e.cloud)) {
			const theirs = await this.host.cloud()?.call(entry.ref.id, "inbox.list", {}).catch(() => undefined);
			if (theirs) items.push(...theirs.items.map((i) => ({ ...i, agent: entry.ref, agentName: entry.title })));
		}
		items.sort((a, b) => b.at.localeCompare(a.at));
		return { count: this.inboxCount(), items };
	}

	async inboxRead(items: readonly { agentId: string; id: string }[]): Promise<void> {
		const byAgent = new Map<string, string[]>();
		for (const i of items) byAgent.set(i.agentId, [...(byAgent.get(i.agentId) ?? []), i.id]);
		for (const [agentId, ids] of byAgent) {
			if (this.isCloud(agentId)) {
				await this.cloudLink().call(agentId, "inbox.read", { items: ids.map((id) => ({ agentId, id })) });
				await this.refreshCloudAgent(agentId);
			} else await (await this.host.agent({ kind: "agent", id: agentId })).core.safety.markRead(ids);
		}
	}

	/** A webhook trigger (hooks.ts): the agent must exist and have it. */
	async fireTrigger(agentId: string, triggerId: string, body: string, deliveryId?: string): Promise<{ runId: string }> {
		if (this.host.get(agentId)?.ref.kind !== "agent") throw new EngineError("NOT_FOUND", "No such agent.");
		const run = await (await this.host.agent({ kind: "agent", id: agentId })).trigger(triggerId, body, deliveryId);
		return { runId: run.id };
	}

	agentMemory(ref: ContainerRef) {
		const def = this.agentDefinition(ref.id).definition;
		const partitions = [
			{ id: "owner", label: def.contacts.find((c) => c.role === "owner")?.name ?? "Owner", bank: `${def.id}/owner` },
			{ id: "shared", label: "Shared", bank: `${def.id}/shared` },
			...def.contacts.filter((c) => c.role === "contact").map((c) => ({ id: `contacts/${c.id}`, label: c.name, bank: `${def.id}/contacts/${c.id}` })),
		];
		return { provider: def.memory?.provider ?? "builtin", partitions };
	}

	/** Settings › Memory: the agents that use memory, their partitions' names, and whether they learn by themselves. */
	memoryOwners(): { agents: { id: string; name: string; avatar?: string; learns: boolean; provider: string; partitions: { bank: string; label: string }[] }[] } {
		const agents = [...this.host.all()]
			.filter((e) => e.ref.kind === "agent")
			.flatMap((e) => {
				const def = this.agentDefinition(e.ref.id).definition;
				if (!def.tools.builtin.includes("memory")) return [];
				const { provider, partitions } = this.agentMemory(e.ref);
				return [{ id: def.id, name: def.name, ...(def.avatar ? { avatar: def.avatar } : {}), learns: def.memory?.learn !== false, provider, partitions: partitions.map((p) => ({ bank: p.bank, label: p.label })) }];
			});
		return { agents };
	}

	/** Turns an agent's learned facts on or off (its definition's memory.learn), as a saved change in its history. */
	async setLearning(ref: ContainerRef, learn: boolean): Promise<void> {
		const { definition, instructions } = this.agentDefinition(ref.id);
		const next = { ...definition, memory: { provider: definition.memory?.provider ?? "builtin", ...definition.memory, learn } };
		const saved = await this.saveAgent(ref, next, instructions, learn ? "Learn facts from conversations" : "Stop learning facts from conversations");
		if (!saved.saved) throw new EngineError("INVALID", saved.errors[0]?.message ?? "Couldn't save the agent.");
	}

	private validateAgent(definition: unknown, id: string): DefinitionError[] {
		const knownAgents = [...this.host.all()].filter((e) => e.ref.kind === "agent" && e.ref.id !== id).map((e) => e.ref.id);
		return validate(definition, {
			unsupported: true,
			knownAgents,
			knownModels: (m) => {
				const { provider, modelId } = modelOf(m);
				return Boolean(this.host.getModel(provider, modelId));
			},
		});
	}

	/** The last valid definition: from memory, else from disk (falling back to nothing usable). */
	/** An agent's models, for work done in its name; a definition that doesn't read counts as utility off. */
	agentModels(id: string): { default: string; utility?: string } {
		try {
			return this.agentDefinition(id).definition.models;
		} catch {
			return { default: "", utility: "off" };
		}
	}

	agentDefinition(id: string): { definition: AgentDefinition; instructions: string } {
		let cached = this.definitions.get(id);
		if (!cached) {
			const entry = this.host.entry({ kind: "agent", id });
			const read = this.services.files.read(entry.agentFolder!);
			if (validate(read.definition).length) {
				entry.agent = entry.agent ? { ...entry.agent, invalid: true } : entry.agent;
				throw new EngineError("INVALID", `${entry.title}'s agent.json doesn't validate; fix it in the Definition tab.`);
			}
			cached = read;
			this.definitions.set(id, cached);
		}
		return cached;
	}

	private setAgentInfo(entry: CatalogEntry, def: AgentDefinition): void {
		const status = entry.agent?.status;
		entry.agent = {
			...(status ? { status } : {}),
			...(def.policies?.requireApproval?.length ? { asksFirst: true } : {}),
			...(def.interview ? { draft: true } : {}),
			slug: def.slug,
			...(def.avatar ? { avatar: def.avatar } : {}),
			...(def.description ? { description: def.description } : {}),
			folder: entry.agentFolder!,
			location: entry.cloud ? "cloud" : "local",
			model: def.models.default,
			contacts: def.contacts.map((c) => ({ id: c.id, name: c.name, role: c.role })),
		};
	}
}
