/**
 * AgentDO: one per agent. pi-durable runs inside it through the Agents SDK `PiHarness`, on this
 * object's SQLite. Clients reach it over a hibernatable WebSocket speaking a subset of the
 * Engine Protocol (JSON-RPC 2.0, one message per text frame).
 *
 * Subscriptions live in each connection's attachment, so they survive hibernation. The pi event
 * streams behind them are in memory only: after any wake (WebSocket message, alarm, request) the
 * object reopens them and sends each subscriber a `resnapshot`, because pi's event streams cannot
 * resume from a cursor.
 */
import { createRegistry, Harness, type AgentEventStream } from "@earendil-works/pi-durable";
import { methods, PROTOCOL_VERSION, type JsonRpcId, type MethodName, type ModelRef, type Params, type Result, type SessionEvent } from "@piopio/protocol";
import { PiHarness, ROOT_SESSION } from "agents/harness/pi";
import { Lifecycle } from "agents/lifecycle";
import { WebSockets } from "agents/websockets";
import { DurableObject } from "cloudflare:workers";
import { Value } from "typebox/value";
import type { Env } from "./env.js";
import { createCloudModels, defaultModel } from "./models.js";
import { TimelineBuilder } from "./timeline/builder.js";
import { DurableEventMapper } from "./timeline/pi-durable.js";

export const CLOUD_VERSION = "0.0.0";

type Subscription = { id: string; session: string; seq: number };
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

/** One pi session's event stream folded into a timeline, shared by its subscribers. */
class SessionView {
	readonly listeners = new Map<string, (events: SessionEvent[]) => void>();
	private constructor(
		readonly builder: TimelineBuilder,
		private readonly stream: AgentEventStream,
	) {}

	static async open(agentId: string, session: string, stream: AgentEventStream, model: ModelRef): Promise<SessionView> {
		const builder = new TimelineBuilder({ kind: "agent", id: agentId, conversationId: session });
		const mapper = new DurableEventMapper(builder);
		mapper.applySnapshot(stream.snapshot as never, false);
		builder.setState({ model });
		builder.flush();
		const view = new SessionView(builder, stream);
		stream.start(async (events) => {
			for (const event of events) mapper.apply(event as never);
			const out = builder.flush();
			if (out.length === 0) return;
			for (const listener of view.listeners.values()) listener(out);
		});
		return view;
	}

	async close(): Promise<void> {
		await this.stream.stop();
	}
}

export class AgentDO extends DurableObject<Env> {
	/** Changes on every cold start or wake, so tests can tell a hibernation from a warm object. */
	readonly instanceId = crypto.randomUUID();
	private readonly startedAt = Date.now();
	private readonly views = new Map<string, Promise<SessionView>>();

	readonly harness = new PiHarness({
		harness: async ({ storage, context }) => Harness.open(storage, { models: await createCloudModels(this.env), registry: createRegistry() }, context),
		defaults: { model: defaultModel(this.env) },
	});

	readonly webSockets = new WebSockets({
		// Our own protocol on the socket: no Agents SDK identity/state frames.
		protocol: false,
		handlers: {
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
		await this.ctx.storage.put(LAST_ALARM_KEY, Date.now());
	}

	async onRequest(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (this.env.PIOPIO_TEST_HOOKS) {
			if (url.pathname === "/__test/status") {
				return Response.json({
					instanceId: this.instanceId,
					startedAt: this.startedAt,
					alarm: await this.ctx.storage.getAlarm(),
					lastAlarmAt: (await this.ctx.storage.get<number>(LAST_ALARM_KEY)) ?? null,
					busy: await this.harness.session().busy(),
				});
			}
		}
		return new Response("Not found", { status: 404 });
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
				return { uptimeMs: Date.now() - this.startedAt, openSessions: this.views.size, subscriptions } satisfies Result<"engine.status">;
			}
			case "sessions.subscribe": {
				const p = params as Params<"sessions.subscribe">;
				const session = this.sessionOf(p.ref);
				const sub: Subscription = { id: `sub_${crypto.randomUUID().slice(0, 8)}`, session, seq: 0 };
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
				const session = this.harness.session(this.sessionOf(p.ref));
				const busy = await session.busy();
				if (busy && p.whenBusy === "reject") throw new RpcError("BUSY", "The agent is busy.");
				const whenBusy = p.whenBusy === "steer" ? "steer" : "followUp";
				await session.submit(p.input.text, { whenBusy, ...(p.clientRequestId ? { operationId: p.clientRequestId } : {}) });
				return { accepted: true, disposition: busy ? "queued" : "started" } satisfies Result<"sessions.submit">;
			}
			case "sessions.abort": {
				const p = params as Params<"sessions.abort">;
				await this.harness.session(this.sessionOf(p.ref)).abort();
				return {};
			}
			default:
				throw new RpcError("NOT_FOUND", `Unknown method ${method}`);
		}
	}

	// ── Subscriptions ─────────────────────────────────────────────────────

	private sessionOf(ref: Params<"sessions.subscribe">["ref"]): string {
		if (ref.kind !== "agent" || ref.id !== this.agentId) throw new RpcError("NOT_FOUND", `This socket serves agent ${this.agentId}.`);
		return ref.conversationId ?? ROOT_SESSION;
	}

	/** Opens (or reuses) the session's view and routes its events to `sub` on `connection`. */
	private async attach(connection: Connection, sub: Subscription): Promise<SessionView> {
		let opening = this.views.get(sub.session);
		if (!opening) {
			opening = this.harness
				.session(sub.session)
				.events()
				.then((stream) => SessionView.open(this.agentId, sub.session, stream, defaultModel(this.env)));
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

const LAST_ALARM_KEY = "piopio:lastAlarmAt";

const SUPPORTED = new Set<string>(["engine.hello", "engine.status", "sessions.subscribe", "sessions.unsubscribe", "sessions.submit", "sessions.abort"]);

/** Constant-time comparison of two secrets (via their SHA-256 digests, so lengths may differ). */
async function sameSecret(a: string, b: string): Promise<boolean> {
	const enc = new TextEncoder();
	const [da, db] = await Promise.all([crypto.subtle.digest("SHA-256", enc.encode(a)), crypto.subtle.digest("SHA-256", enc.encode(b))]);
	return crypto.subtle.timingSafeEqual(da, db);
}
