/**
 * AgentDO: one per agent. pi-durable runs inside it through the Agents SDK `PiHarness`, on this
 * object's SQLite. Clients reach it over a hibernatable WebSocket speaking a subset of the
 * Engine Protocol (JSON-RPC 2.0, one message per text frame).
 *
 * Subscriptions live in each connection's attachment, so they survive hibernation. The pi watches
 * behind them are in memory only: after any wake (WebSocket message, alarm, request) the object
 * reopens them and sends each subscriber a `resnapshot`.
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createRegistry, Harness, type ConversationWatch } from "@earendil-works/pi-durable";
import { methods, PROTOCOL_VERSION, type JsonRpcId, type MethodName, type ModelRef, type Params, type Result, type SessionEvent, type TimelineItem } from "@piopio/protocol";
import { PiHarness, ROOT_SESSION, type PiSession } from "agents/harness/pi";
import { Lifecycle } from "agents/lifecycle";
import { WebSockets } from "agents/websockets";
import { DurableObject } from "cloudflare:workers";
import { Value } from "typebox/value";
import { alwaysLabel, modelOf, validate, type AgentDefinition, type MemoryRecord, type Reminder, DurableViewMapper, type DurableView, type Entry } from "@piopio/runtime";
import { AgentHost, defaultAgent, type StoredAgent } from "./agent.js";
import { sameSecret } from "./auth.js";
import { CloudTelegram } from "./telegram.js";
import type { Env } from "./env.js";
import { createCloudModels, defaultModel } from "./models.js";
import { REGISTRY_NAME } from "./registry-do.js";
import { TimelineBuilder } from "@piopio/runtime";
import { agentItem } from "./timeline/agent-items.js";

export const CLOUD_VERSION = "0.0.0";

/** `session`: pi's session id inside the object; `conversation`: what refs call it (`person:<id>`, `run:<id>`). */
type Subscription = { id: string; session: string; conversation?: string; seq: number };
/** Where a ref goes: pi's session, its public name, and the person who writes there (none for a run). */
type Target = { session: string; conversation: string; contactId?: string };
type ConnState = { authed?: boolean; subs?: Subscription[] };
type Connection = ReturnType<WebSockets["getConnections"]> extends IterableIterator<infer C> ? C : never;
type ErrorCode = "NOT_FOUND" | "BUSY" | "AUTH" | "INVALID" | "INTERNAL";

class RpcError extends Error {
	constructor(
		readonly code: ErrorCode,
		message: string,
	) {
		super(message);
	}
}

/** How much of a conversation a view loads: its newest entries (there is no loading earlier ones yet). */
const MAX_HISTORY = 5_000;

/** A session's history: pi-durable's raw entries, the newest `MAX_HISTORY`, oldest first. */
async function history(pi: Harness, session: string): Promise<Entry[] | undefined> {
	const conversation = await pi.conversation(Number(session) as never, BACKGROUND_CONTEXT);
	if (!conversation) return undefined;
	const newest: Entry[] = [];
	let cursor: unknown;
	do {
		const page = await conversation.entries({ order: "descending" }, 500, cursor as never, BACKGROUND_CONTEXT);
		newest.push(...(page.items as unknown as Entry[]));
		cursor = page.next;
	} while (cursor && newest.length < MAX_HISTORY);
	return newest.slice(0, MAX_HISTORY).reverse();
}

/** One pi session's state folded into a timeline, shared by its subscribers. */
class SessionView {
	readonly listeners = new Map<string, (events: SessionEvent[]) => void>();
	private constructor(
		readonly builder: TimelineBuilder,
		private readonly watch: ConversationWatch,
	) {}

	/**
	 * The history is read before the watch, so the watch's first value is as new or newer. It is the conversation's raw
	 * entries, which a compaction never changes: the session's `messages()` is the model's context, so a chat read from
	 * it lost everything a compaction had summarized (as the engine's did, packages/engine/src/runtimes/agent.ts).
	 */
	static async open(agentId: string, conversation: string, pi: PiSession, model: ModelRef, history: () => Promise<Entry[] | undefined>): Promise<SessionView> {
		const transcript = (await history().catch(() => undefined)) ?? ((await pi.messages()) as unknown as Entry[]);
		const watch = await pi.watch();
		const builder = new TimelineBuilder({ kind: "agent", id: agentId, conversationId: conversation });
		const mapper = new DurableViewMapper<TimelineItem>(builder, { ownItem: agentItem });
		mapper.load(transcript, watch.value as unknown as DurableView, false);
		builder.setState({ model });
		builder.flush();
		const view = new SessionView(builder, watch);
		watch.start(async (call) => {
			if (call.kind !== "value") return;
			mapper.apply(call.value as unknown as DurableView);
			const out = builder.flush();
			if (out.length === 0) return;
			for (const listener of view.listeners.values()) listener(out);
		});
		return view;
	}

	async close(): Promise<void> {
		await this.watch.stop();
	}
}

export class AgentDO extends DurableObject<Env> {
	/** Changes on every cold start or wake, so tests can tell a hibernation from a warm object. */
	readonly instanceId = crypto.randomUUID();
	private readonly startedAt = Date.now();
	private readonly views = new Map<string, Promise<SessionView>>();

	/** The agent (spike S7): its definition, and AgentCore on the harness pi opens with. */
	private agentDef?: StoredAgent;
	private host?: AgentHost;
	private hostReady?: Promise<AgentHost>;

	readonly harness = new PiHarness({
		// onWake hands pi's sleeping timers to the object's alarm, so a sleeping task doesn't pin it in memory.
		harness: async ({ storage, context, onWake }) => {
			const registry = createRegistry();
			const pi = await Harness.open(storage, { models: await createCloudModels(this.env), registry, onWake }, context);
			const model = defaultModel(this.env);
			this.agentDef = (await this.ctx.storage.get<StoredAgent>(AGENT_KEY)) ?? defaultAgent(this.agentId, `${model.provider}:${model.id}`);
			const host = new AgentHost(pi, () => this.agentDef!, this.ctx.storage, context, (to, text) => this.telegram.outbound(to, text));
			registry.install(host.core.extension);
			await host.core.configureAll();
			this.host = host;
			return pi;
		},
		defaults: { model: defaultModel(this.env) },
	});

	/** The agent's Telegram bot, read by webhook (docs/spec/13 §5.3). */
	readonly telegram: CloudTelegram = (() => {
		const self = this;
		return new CloudTelegram({
			get agentId() {
				return self.agentId;
			},
			storage: this.ctx.storage,
			definition: () => self.agentDef!.definition,
			save: async (change) => {
				const next = structuredClone(self.agentDef!);
				change(next.definition);
				await self.ctx.storage.put(AGENT_KEY, next);
				self.agentDef = next;
				await self.host?.core.configureAll();
			},
			origin: () => self.ctx.storage.get<string>(ORIGIN_KEY),
			say: (contactId, text) => self.target({ kind: "agent", id: self.agentId, conversationId: `person:${contactId}` }).then((t) => self.say(t, text, { whenBusy: "followUp" })),
			answer: async (owed) => (await self.harness.wait(owed.operationId, { session: owed.session })).text,
			notice: async (text) => (await self.agent()).core.proactive.notice(text),
			waitUntil: (work) => self.ctx.waitUntil(work),
			webhook: (secret) => self.env.REGISTRY.getByName(REGISTRY_NAME).setWebhook(self.agentId, secret),
			...(this.env.PIOPIO_TEST_TELEGRAM_API ? { api: this.env.PIOPIO_TEST_TELEGRAM_API } : {}),
		});
	})();

	/** Whether pi is answering anyone: a person's conversation, or the root session. */
	private async working(): Promise<boolean> {
		const people = Object.values(await this.host!.core.people());
		for (const id of [ROOT_SESSION, ...people]) if (await this.harness.session(id).busy()) return true;
		return false;
	}

	/** The agent, once pi is open and its tasks have started (after any wake). */
	async agent(): Promise<AgentHost> {
		this.hostReady ??= (async () => {
			if (await this.ctx.storage.get(RETIRED_KEY)) throw new RpcError("NOT_FOUND", "This agent moved back to the Mac.");
			await this.harness.session().busy(); // opens pi (and the agent, in the factory above)
			await this.host!.core.start();
			return this.host!;
		})();
		this.hostReady.catch(() => (this.hostReady = undefined));
		return this.hostReady;
	}

	readonly webSockets = new WebSockets({
		// Our own protocol on the socket: no Agents SDK identity/state frames.
		protocol: false,
		handlers: {
			// The Worker's public address, for the webhooks it sets (Telegram's).
			onConnect: (_connection, ctx) => this.ctx.storage.put(ORIGIN_KEY, new URL(ctx.request.url).origin),
			onMessage: (connection, message) => this.onMessage(connection as Connection, message),
			onClose: (connection) => this.dropSubscriptions(connection as Connection),
		},
	});

	readonly lifecycle = Lifecycle.install(this).use(this.harness).use(this.webSockets);

	private get agentId(): string {
		return this.lifecycle.name;
	}

	/** Runs on every cold start and every wake from hibernation, after pi has opened. */
	async onStart(): Promise<void> {
		// Moved back to the Mac: nothing runs here until it's deployed again.
		if (await this.ctx.storage.get(RETIRED_KEY)) return;
		await this.agent();
		this.telegram.resume();
		for (const connection of this.webSockets.getConnections<ConnState>()) {
			const subs = connection.state?.subs ?? [];
			const live: Subscription[] = [];
			for (const sub of subs) {
				try {
					await this.attach(connection, sub);
					live.push(sub);
				} catch {
					// The session is gone; drop the subscription.
				}
			}
			if (live.length !== subs.length) connection.setState({ ...connection.state, subs: live } satisfies ConnState);
			for (const sub of live) {
				const view = await this.views.get(sub.session)!;
				this.send(connection, sub, [{ type: "resnapshot", snapshot: view.builder.snapshot() }]);
			}
		}
	}

	/** Runs once per alarm invocation, after Lifecycle drove the due jobs (PiHarness wakes). */
	async onAlarm(): Promise<void> {
		// The last few alarm times (tests read them: an alarm between an eviction and a reconnect resumed the work).
		await this.ctx.storage.put(ALARMS_KEY, [...((await this.ctx.storage.get<number[]>(ALARMS_KEY)) ?? []), Date.now()].slice(-20));
	}

	async onRequest(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "POST" && url.pathname.startsWith("/v1/channels/telegram/")) {
			await this.agent();
			return this.telegram.webhook(request);
		}
		if (this.env.PIOPIO_TEST_HOOKS) {
			if (url.pathname.startsWith("/__test/agent")) return this.agentTestRoute(url, request);
			if (url.pathname === "/__test/status") {
				return Response.json({
					instanceId: this.instanceId,
					startedAt: this.startedAt,
					alarm: await this.ctx.storage.getAlarm(),
					alarms: (await this.ctx.storage.get<number[]>(ALARMS_KEY)) ?? [],
					busy: await (async () => (await this.agent(), this.working()))(),
				});
			}
		}
		return new Response("Not found", { status: 404 });
	}

	/**
	 * Test routes for the agent (spike S7): `say` runs a person's turn the way the engine does (memory recalled
	 * before, retained after); `remind` adds a reminder; `overview` shows runs, upcoming fires and the wake alarm;
	 * `recall` searches memory.
	 */
	private async agentTestRoute(url: URL, request: Request): Promise<Response> {
		const host = await this.agent();
		const core = host.core;
		const body = request.method === "POST" ? ((await request.json()) as Record<string, unknown>) : {};
		switch (url.pathname) {
			case "/__test/agent/say": {
				const contact = String(body.contact ?? "owner");
				const text = String(body.text ?? "");
				const conversation = await core.conversation(contact);
				await core.beforeTurn(contact, conversation.id, text);
				const session = String(conversation.id);
				const receipt = await this.harness.submit(text, { session });
				if (body.wait === false) return Response.json({ session, operationId: receipt.operationId });
				const result = await this.harness.wait(receipt.operationId, { session });
				await core.afterTurn(contact, text, result.text ?? "", { ref: `agent:${this.agentId}` });
				return Response.json({ ...result, session });
			}
			case "/__test/agent/wait": {
				const result = await this.harness.wait(String(body.operationId), { session: String(body.session) });
				return Response.json(result);
			}
			case "/__test/agent/remind": {
				const at = Date.now() + Number(body.inMs ?? 2000);
				await core.proactive.restoreReminder({ id: `r${at.toString(36)}`, prompt: String(body.prompt ?? "Remind me"), at, createdAt: new Date().toISOString(), by: "owner" });
				return Response.json({ at });
			}
			case "/__test/agent/overview":
				return Response.json({ ...(await core.proactive.overview()), alarm: await this.ctx.storage.getAlarm(), instanceId: this.instanceId });
			case "/__test/agent/list": {
				const bank = `${this.agentId}/${url.searchParams.get("partition") ?? "owner"}`;
				const fts = this.ctx.storage.sql.exec("SELECT count(*) AS n FROM memory_fts").toArray()[0];
				const triggers = this.ctx.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'trigger'").toArray();
				return Response.json({ records: (await host.memory.list(bank, { limit: 50 })).records, fts, triggers });
			}
			case "/__test/agent/recall": {
				const hits = await host.memory.recall([`${this.agentId}/owner`], url.searchParams.get("q") ?? "", { budgetTokens: 400 });
				return Response.json({ hits });
			}
			default:
				return new Response("Not found", { status: 404 });
		}
	}

	// ── Engine Protocol over the socket ───────────────────────────────────

	private async onMessage(connection: Connection, message: unknown): Promise<void> {
		let id: JsonRpcId | undefined;
		try {
			if (typeof message !== "string") throw new RpcError("INVALID", "Binary frames are not supported.");
			const request = JSON.parse(message) as { jsonrpc?: string; id?: JsonRpcId; method?: string; params?: unknown };
			id = request.id;
			const result = await this.dispatch(connection, String(request.method), request.params ?? {});
			if (id !== undefined) connection.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
		} catch (error) {
			if (id === undefined) return;
			const code: ErrorCode = error instanceof RpcError ? error.code : "INTERNAL";
			const rpcCode = code === "INVALID" ? -32602 : code === "NOT_FOUND" && error instanceof RpcError && error.message.startsWith("Unknown method") ? -32601 : -32000;
			connection.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code: rpcCode, message: error instanceof Error ? error.message : String(error), data: { code } } }));
		}
	}

	private async dispatch(connection: Connection, method: string, params: unknown): Promise<unknown> {
		if (!SUPPORTED.has(method)) throw new RpcError("NOT_FOUND", `Unknown method ${method}`);
		const schema = methods[method as MethodName].params;
		if (!Value.Check(schema, params)) {
			const first = [...Value.Errors(schema, params)][0];
			throw new RpcError("INVALID", `Invalid params for ${method}${first ? `: ${first.instancePath || "/"} ${first.message}` : ""}`);
		}
		const state = (connection.state ?? {}) as ConnState;
		if (method === "engine.hello") {
			const p = params as Params<"engine.hello">;
			if (!this.env.OWNER_TOKEN || !(await sameSecret(p.token, this.env.OWNER_TOKEN))) throw new RpcError("AUTH", "Bad owner token.");
			connection.setState({ ...state, authed: true } satisfies ConnState);
			const model = defaultModel(this.env);
			return {
				engineId: `cloud:${this.agentId}`,
				kind: "cloud",
				version: CLOUD_VERSION,
				protocolVersion: PROTOCOL_VERSION,
				capabilities: { runtimes: ["agent"], models: [`${model.provider}/${model.id}`] },
			} satisfies Result<"engine.hello">;
		}
		if (!state.authed) throw new RpcError("AUTH", "Call engine.hello first.");

		switch (method as MethodName) {
			case "engine.status": {
				let subscriptions = 0;
				for (const c of this.webSockets.getConnections<ConnState>()) subscriptions += c.state?.subs?.length ?? 0;
				return {
					uptimeMs: Date.now() - this.startedAt,
					openSessions: this.views.size,
					subscriptions,
					runtime: "Cloudflare Workers (workerd)",
					memoryMB: 0, // not observable from inside a Worker
					dataPath: `Durable Object ${this.ctx.id.toString().slice(0, 12)}…`,
				} satisfies Result<"engine.status">;
			}
			case "sessions.subscribe": {
				const p = params as Params<"sessions.subscribe">;
				const { session, conversation } = await this.target(p.ref);
				const sub: Subscription = { id: `sub_${crypto.randomUUID().slice(0, 8)}`, session, conversation, seq: 0 };
				const view = await this.attach(connection, sub);
				connection.setState({ ...state, subs: [...(state.subs ?? []), sub] } satisfies ConnState);
				return { subscriptionId: sub.id, snapshot: view.builder.snapshot() } satisfies Result<"sessions.subscribe">;
			}
			case "sessions.unsubscribe": {
				const p = params as Params<"sessions.unsubscribe">;
				const sub = state.subs?.find((s) => s.id === p.subscriptionId);
				if (sub) {
					(await this.views.get(sub.session))?.listeners.delete(sub.id);
					connection.setState({ ...state, subs: state.subs!.filter((s) => s.id !== sub.id) } satisfies ConnState);
				}
				return {};
			}
			case "sessions.submit": {
				const p = params as Params<"sessions.submit">;
				const target = await this.target(p.ref);
				if (!target.contactId) throw new RpcError("INVALID", "A run's conversation is read-only.");
				const busy = await this.harness.session(target.session).busy();
				if (busy && p.whenBusy === "reject") throw new RpcError("BUSY", "The agent is busy.");
				const whenBusy = p.whenBusy === "steer" ? "steer" : "followUp";
				const started = await this.say(target, p.input.text, { whenBusy, ...(p.clientRequestId ? { operationId: p.clientRequestId } : {}) });
				return { accepted: true, disposition: busy && started !== undefined ? "queued" : "started" } satisfies Result<"sessions.submit">;
			}
			case "agents.runs": {
				// The agent's runs, held messages and what's next (06 PR1), as the Mac's Runs tab reads them.
				const p = params as Params<"agents.runs">;
				this.ownAgent(p.ref);
				const o = await (await this.agent()).core.proactive.overview();
				const iso = (t: number | undefined) => (t === undefined ? undefined : new Date(t).toISOString());
				return {
					runs: o.runs.map((r) => ({ id: r.id, kind: r.kind, source: r.source, prompt: r.prompt, firedAt: r.firedAt, status: r.status, sent: r.sent, ...(r.summary ? { summary: r.summary } : {}), ...(r.costUsd !== undefined ? { costUsd: r.costUsd } : {}) })),
					outbox: o.outbox.map((m) => ({ id: m.id, to: m.to, text: m.text, notBefore: iso(m.notBefore)!, reason: m.reason })),
					upcoming: o.upcoming.map((u) => ({ id: u.id, kind: u.kind, label: u.label, ...(u.next !== undefined ? { next: iso(u.next)! } : {}), ...(u.cron ? { cron: u.cron } : {}) })),
				} satisfies Result<"agents.runs">;
			}
			case "agents.runNow": {
				// Run now (06 §6): a schedule of its definition, or any prompt.
				const p = params as Params<"agents.runNow">;
				this.ownAgent(p.ref);
				const core = (await this.agent()).core;
				let run;
				if (p.scheduleId) {
					const s = (this.agentDef!.definition.schedules ?? []).find((x) => x.id === p.scheduleId);
					if (!s) throw new RpcError("NOT_FOUND", `No schedule “${p.scheduleId}”.`);
					run = await core.proactive.startRun("manual", p.trial ? "trial" : s.id, s.prompt, s.deliverTo);
				} else {
					if (!p.prompt?.trim()) throw new RpcError("INVALID", "Give a schedule or a prompt.");
					run = await core.proactive.startRun("manual", p.trial ? "trial" : "manual", p.prompt.trim());
				}
				return { runId: run.id } satisfies Result<"agents.runNow">;
			}
			case "agents.pause": {
				const p = params as Params<"agents.pause">;
				this.ownAgent(p.ref);
				await (await this.agent()).core.safety.setPaused(p.paused);
				return {} satisfies Result<"agents.pause">;
			}
			case "agents.decide": {
				const p = params as Params<"agents.decide">;
				this.ownAgent(p.ref);
				try {
					const a = await (await this.agent()).core.safety.decide(p.approvalId, { approve: p.approve, ...(p.args && typeof p.args === "object" ? { args: p.args as never } : {}), ...(p.always ? { always: true } : {}), ...(p.reason ? { reason: p.reason } : {}) });
					return { status: a.status } satisfies Result<"agents.decide">;
				} catch (error) {
					throw new RpcError("INVALID", (error as Error).message);
				}
			}
			case "agents.undo": {
				const p = params as Params<"agents.undo">;
				this.ownAgent(p.ref);
				try {
					await (await this.agent()).core.safety.undo(p.undoId);
				} catch (error) {
					throw new RpcError("INVALID", (error as Error).message);
				}
				return {} satisfies Result<"agents.undo">;
			}
			case "agents.status": {
				const p = params as Params<"agents.status">;
				this.ownAgent(p.ref);
				const host = await this.agent();
				const safety = await host.core.safety.status();
				const next = (await host.core.proactive.overview()).upcoming.map((u) => u.next).filter((n): n is number => typeof n === "number").sort((a, b) => a - b)[0];
				return { ...safety, ...(next && !safety.paused ? { nextRun: new Date(next).toISOString() } : {}) } satisfies Result<"agents.status">;
			}
			case "inbox.list":
				return this.inbox();
			case "inbox.read": {
				const p = params as Params<"inbox.read">;
				const mine = p.items.filter((i) => i.agentId === this.agentId).map((i) => i.id);
				if (mine.length) await (await this.agent()).core.safety.markRead(mine);
				return {} satisfies Result<"inbox.read">;
			}
			case "agents.deploy":
				return this.deploy(params as Params<"agents.deploy">);
			case "agents.export":
				return this.exportAgent(params as Params<"agents.export">);
			case "agents.retire":
				return this.retire(params as Params<"agents.retire">);
			case "agents.conversations": {
				const p = params as Params<"agents.conversations">;
				this.ownAgent(p.ref);
				const people = await (await this.agent()).core.people();
				return {
					people: this.agentDef!.definition.contacts.map((c) => ({ contactId: c.id, name: c.name, role: c.role, conversationId: `person:${c.id}`, started: people[c.id] !== undefined })),
				} satisfies Result<"agents.conversations">;
			}
			case "sessions.abort": {
				const p = params as Params<"sessions.abort">;
				await this.harness.session((await this.target(p.ref)).session).abort();
				return {};
			}
			default:
				throw new RpcError("NOT_FOUND", `Unknown method ${method}`);
		}
	}

	/** This agent's Inbox (06 §12), shaped as the Mac's `inbox.list` so the Mac's engine merges it with its own. */
	private async inbox(): Promise<Result<"inbox.list">> {
		const core = (await this.agent()).core;
		const def = this.agentDef!.definition;
		const ref = { kind: "agent" as const, id: this.agentId };
		const items: Result<"inbox.list">["items"] = [];
		for (const e of await core.safety.entries()) {
			const a = e.approval;
			items.push({
				id: e.id,
				agent: ref,
				agentName: def.name,
				...(def.avatar ? { avatar: def.avatar } : {}),
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
		items.sort((x, y) => y.at.localeCompare(x.at));
		return { count: (await core.safety.status()).inbox, items };
	}

	// ── Moving between the Mac and the cloud (docs/spec/30 §3.2, K1) ───────

	/**
	 * The Mac sends the agent up as data: its definition and instructions, and on a move its memory, reminders and
	 * Telegram bot. The definition is checked first; nothing is stored when it doesn't validate.
	 */
	private async deploy(p: Params<"agents.deploy">): Promise<Result<"agents.deploy">> {
		this.ownAgent(p.ref);
		const definition = p.definition as AgentDefinition;
		const errors = validate(definition);
		if (errors.length) throw new RpcError("INVALID", `The definition doesn't validate: ${errors.map((e) => `${e.path} ${e.message}`).join("; ")}`);
		if (definition.id !== this.agentId) throw new RpcError("INVALID", `This object is agent ${this.agentId}, not ${definition.id}.`);
		await this.ctx.storage.delete(RETIRED_KEY);
		const stored: StoredAgent = { definition, instructions: p.instructions };
		await this.ctx.storage.put(AGENT_KEY, stored);
		this.agentDef = stored;
		const host = await this.agent();
		await host.core.configureAll();
		const lines: string[] = [];
		if (p.memory?.length) {
			for (const r of p.memory) await host.memory.retain(`${this.agentId}/${r.partition}`, { content: r.text, kind: r.kind as MemoryRecord["kind"], createdBy: r.createdBy, at: r.at, ...(r.tags ? { tags: r.tags } : {}), ...(r.pinned ? { pinned: true } : {}) });
			lines.push(`Memory: ${p.memory.length} ${p.memory.length === 1 ? "record" : "records"}.`);
		}
		let reminders = 0;
		for (const r of (p.reminders ?? []) as Reminder[]) {
			try {
				await host.core.proactive.restoreReminder(r);
				reminders++;
			} catch {
				// its moment passed on the way
			}
		}
		if (reminders) lines.push(`Reminders: ${reminders}.`);
		if (p.telegram) lines.push(await this.telegram.connect(p.telegram.token));
		const deployedAt = new Date().toISOString();
		await this.env.REGISTRY.getByName(REGISTRY_NAME).put({ id: this.agentId, name: definition.name, ...(definition.avatar ? { avatar: definition.avatar } : {}), deployedAt });
		return { deployedAt, lines };
	}

	/** Everything the Mac needs to run the agent again: read only, so a failed save on the Mac loses nothing here. */
	private async exportAgent(p: Params<"agents.export">): Promise<Result<"agents.export">> {
		this.ownAgent(p.ref);
		const host = await this.agent();
		const memory: Result<"agents.export">["memory"] = [];
		const prefix = `${this.agentId}/`;
		for (const { bank } of host.memory.banks().filter((b) => b.bank.startsWith(prefix))) {
			let cursor: string | undefined;
			do {
				const page = await host.memory.list(bank, { limit: 200, ...(cursor ? { cursor } : {}) });
				for (const r of page.records) {
					if (r.endedAt) continue;
					memory.push({ partition: bank.slice(prefix.length), text: r.text, kind: r.kind, createdBy: r.createdBy, at: r.at, ...(r.tags?.length ? { tags: r.tags } : {}), ...(r.pinned ? { pinned: true } : {}) });
				}
				cursor = page.cursor;
			} while (cursor);
		}
		const token = await this.telegram.token();
		return { definition: this.agentDef!.definition, instructions: this.agentDef!.instructions, memory, reminders: await host.core.proactive.reminders(), ...(token ? { telegram: { token } } : {}) };
	}

	/** The agent moved to the Mac: its bot's webhook stops, it leaves the registry, and its data here is deleted. */
	private async retire(p: Params<"agents.retire">): Promise<Result<"agents.retire">> {
		this.ownAgent(p.ref);
		if (!(await this.ctx.storage.get(RETIRED_KEY))) await this.agent();
		await this.telegram.disconnect();
		await this.env.REGISTRY.getByName(REGISTRY_NAME).remove(this.agentId);
		this.hostReady = undefined;
		this.host = undefined;
		for (const view of this.views.values()) await (await view.catch(() => undefined))?.close();
		this.views.clear();
		await this.harness.dispose();
		for (const connection of this.webSockets.getConnections<ConnState>()) connection.setState({ authed: connection.state?.authed ?? false } satisfies ConnState);
		await this.ctx.storage.deleteAlarm();
		await this.ctx.storage.deleteAll();
		await this.ctx.storage.put(RETIRED_KEY, new Date().toISOString());
		this.agentDef = undefined;
		// deleteAll also dropped the tables the Agents SDK made when this instance started (cf_agents_jobs, …), and
		// it remembers having made them: a deploy into this same instance would fail on the first message. So the
		// object restarts once the answer is out, and the next request starts a fresh instance that makes them again.
		setTimeout(() => this.ctx.abort("Retired: restarting with empty storage"), 50);
		return {};
	}

	// ── Subscriptions ─────────────────────────────────────────────────────

	/**
	 * The agent's own model, read as the runtime runs it ("provider:id", or a bare OpenRouter id as the Mac saves them),
	 * else the Worker's default. A bare id once read as no model, so the composer named the default (Haiku) while the
	 * agent answered with its own.
	 */
	private modelRef(): ModelRef {
		const id = this.agentDef?.definition.models.default;
		if (!id) return defaultModel(this.env);
		const { provider, modelId } = modelOf(id);
		return { provider, id: modelId };
	}

	private ownAgent(ref: Params<"sessions.subscribe">["ref"]): void {
		if (ref.kind !== "agent" || ref.id !== this.agentId) throw new RpcError("NOT_FOUND", `This socket serves agent ${this.agentId}.`);
	}

	/**
	 * Where a ref goes, as on the Mac: `person:<id>` is that person's conversation with the agent (the owner's when the
	 * ref names none), the one its runs write to and its memory follows; `run:<id>` is an automatic run's, read-only.
	 */
	private async target(ref: Params<"sessions.subscribe">["ref"]): Promise<Target> {
		this.ownAgent(ref);
		const core = (await this.agent()).core;
		const def = this.agentDef!.definition;
		const owner = def.contacts.find((c) => c.role === "owner")?.id ?? "owner";
		const conversation = ref.conversationId ?? `person:${owner}`;
		if (conversation.startsWith("person:")) {
			const contactId = conversation.slice("person:".length);
			if (!core.contact(contactId)) throw new RpcError("NOT_FOUND", `${def.name} has no contact ${contactId}.`);
			return { session: String((await core.conversation(contactId)).id), conversation, contactId };
		}
		if (conversation.startsWith("run:")) {
			const run = (await core.proactive.overview()).runs.find((r) => r.id === conversation.slice("run:".length));
			if (!run?.conversationId) throw new RpcError("NOT_FOUND", `No run ${conversation.slice("run:".length)}.`);
			return { session: String(run.conversationId), conversation };
		}
		throw new RpcError("NOT_FOUND", "A conversation is person:<contact id> or run:<run id>.");
	}

	/**
	 * A person's message, as the Mac's agent runtime takes it: /pause, /resume and messages while paused or out of
	 * budget answer without a turn; otherwise memory is recalled before, and what was said is kept once it's answered.
	 * False when no turn started.
	 */
	private async say(target: Target, text: string, options: { whenBusy: "followUp" | "steer"; operationId?: string }): Promise<{ operationId: string; session: string } | undefined> {
		const core = (await this.agent()).core;
		const contactId = target.contactId!;
		// The owner pasting a bot token connects Telegram; the token never reaches the model or the transcript.
		const connected = await this.telegram.intercept(contactId, text);
		if (connected) {
			await core.proactive.notice(connected);
			return undefined;
		}
		if (await core.intercept(contactId, text)) return undefined;
		await core.beforeTurn(contactId, Number(target.session) as never, text).catch(() => undefined);
		const receipt = await this.harness.submit(text, { session: target.session, ...options });
		// What follows the answer (its memory, the budget) is the agent's own durable task (@piopio/runtime, `turnEnded`):
		// it runs after the reply and an eviction doesn't lose it.
		return { operationId: receipt.operationId, session: target.session };
	}

	/** Opens (or reuses) the session's view and routes its events to `sub` on `connection`. */
	private async attach(connection: Connection, sub: Subscription): Promise<SessionView> {
		let opening = this.views.get(sub.session);
		if (!opening) {
			opening = SessionView.open(this.agentId, sub.conversation ?? sub.session, this.harness.session(sub.session), this.modelRef(), async () => history((await this.agent()).pi, sub.session));
			opening.catch(() => this.views.delete(sub.session));
			this.views.set(sub.session, opening);
		}
		let view: SessionView;
		try {
			view = await opening;
		} catch (error) {
			throw new RpcError("NOT_FOUND", `No session ${sub.session}: ${error instanceof Error ? error.message : String(error)}`);
		}
		view.listeners.set(sub.id, (events) => this.send(connection, sub, events));
		return view;
	}

	private send(connection: Connection, sub: Subscription, events: SessionEvent[]): void {
		sub.seq += 1;
		connection.send(JSON.stringify({ jsonrpc: "2.0", method: "session.events", params: { subscriptionId: sub.id, seq: sub.seq, events } }));
		// Persist the sequence number so it continues after hibernation.
		const state = (connection.state ?? {}) as ConnState;
		connection.setState({ ...state, subs: (state.subs ?? []).map((s) => (s.id === sub.id ? { ...s, seq: sub.seq } : s)) } satisfies ConnState);
	}

	private async dropSubscriptions(connection: Connection): Promise<void> {
		const subs = ((connection.state ?? {}) as ConnState).subs ?? [];
		for (const sub of subs) {
			const opening = this.views.get(sub.session);
			const view = await opening?.catch(() => undefined);
			if (!view) continue;
			view.listeners.delete(sub.id);
			if (view.listeners.size === 0 && this.views.get(sub.session) === opening) {
				this.views.delete(sub.session);
				await view.close();
			}
		}
	}
}

const ALARMS_KEY = "piopio:alarms";
const ORIGIN_KEY = "piopio:origin";
const AGENT_KEY = "piopio:agent";
/** Set when the agent moved back to the Mac (everything else was deleted). */
const RETIRED_KEY = "piopio:retired";

const SUPPORTED = new Set<string>(["engine.hello", "engine.status", "sessions.subscribe", "sessions.unsubscribe", "sessions.submit", "sessions.abort", "agents.runs", "agents.conversations", "agents.deploy", "agents.export", "agents.retire", "agents.runNow", "agents.pause", "agents.decide", "agents.undo", "agents.status", "inbox.list", "inbox.read"]);
