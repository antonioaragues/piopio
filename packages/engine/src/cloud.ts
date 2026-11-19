/**
 * CloudLink (docs/spec/30 §8, K1): the Mac's engine talking to your cloud, so the app keeps one connection, to this
 * engine. Settings › This Mac & cloud connects a Worker already deployed (its address and owner token); the token
 * lives in the Keychain. A cloud agent's conversations open here as `CloudAgentView`s: each one a subscription on that
 * agent's socket (`/v1/ws?agent=<id>`), its timeline kept in step from the events, and its messages sent up.
 *
 * One socket per cloud agent, opened when something needs it and reopened after a drop (the views subscribe again
 * and send a fresh snapshot). The gateway with one socket for everything (30 §8) waits for the phone app (K3).
 */
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import type { CloudStatus, ContainerRef, MethodName, ModelRef, Params, Result, SessionEvent, Snapshot } from "@piopio/protocol";
import { EngineError } from "./models.js";
import type { Runtime, SubmitOptions } from "./runtimes/runtime.js";
import { Emitter } from "./runtimes/runtime.js";
import type { SecretBroker } from "./secrets.js";

/** The Keychain item for the Worker's owner token. */
export const SECRET_CLOUD = "CLOUD_OWNER_TOKEN";

export type CloudConfig = { url: string; connectedAt: string; version?: string };

type Fetch = typeof fetch;
type Socket = WebSocket;
type Notification = { subscriptionId: string; seq: number; events: SessionEvent[] };

const RECONNECT_MS = [1_000, 2_000, 5_000, 10_000, 30_000];

/** `https://piopio-cloud.x.workers.dev/` → `https://piopio-cloud.x.workers.dev`; refuses anything but http(s). */
export function cloudOrigin(raw: string): string {
	let url: URL;
	try {
		url = new URL(raw.trim().includes("://") ? raw.trim() : `https://${raw.trim()}`);
	} catch {
		throw new EngineError("INVALID", "That isn't an address. Paste the Worker's URL, like https://piopio-cloud.<you>.workers.dev.");
	}
	if (url.protocol !== "https:" && url.protocol !== "http:") throw new EngineError("INVALID", "The Worker's address starts with https://.");
	// Plain http only for a Worker on this Mac (wrangler dev).
	if (url.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) throw new EngineError("INVALID", "Use the Worker's https:// address.");
	return url.origin;
}

export class CloudLink {
	private readonly sockets = new Map<string, AgentSocket>();
	private readonly fetchImpl: Fetch;

	constructor(
		private readonly options: {
			/** Where the address is kept (the token isn't: it's in the Keychain). */
			file: string;
			secrets: SecretBroker;
			fetch?: Fetch;
			/** Tests: a WebSocket that takes `{ headers }` (Node's does). */
			webSocket?: (url: string, token: string) => Socket;
			log?: (line: string) => void;
		},
	) {
		this.fetchImpl = options.fetch ?? fetch;
	}

	config(): CloudConfig | undefined {
		if (!existsSync(this.options.file)) return undefined;
		try {
			return JSON.parse(readFileSync(this.options.file, "utf8")) as CloudConfig;
		} catch {
			return undefined;
		}
	}

	get connected(): boolean {
		return this.config() !== undefined;
	}

	private async token(): Promise<string> {
		const token = await this.options.secrets.get(SECRET_CLOUD, "Your cloud's owner token");
		if (!token) throw new EngineError("AUTH", "Piopio can't read your cloud's owner token from the Keychain. Connect again in Settings › This Mac & cloud.");
		return token;
	}

	/** `/v1/health` (open), then `/v1/agents` (needs the token): the Worker answers, and the token is right. */
	private async check(url: string, token: string): Promise<{ version?: string; agents: CloudStatus["agents"] }> {
		let health: Response;
		try {
			health = await this.fetchImpl(`${url}/v1/health`, { signal: AbortSignal.timeout(10_000) });
		} catch (error) {
			throw new EngineError("ENGINE_UNAVAILABLE", `${url} didn't answer (${(error as Error).message}).`);
		}
		if (!health.ok) throw new EngineError("ENGINE_UNAVAILABLE", `${url}/v1/health answered ${health.status}. Is this a Piopio Worker?`);
		const { version } = (await health.json().catch(() => ({}))) as { version?: string };
		const res = await this.fetchImpl(`${url}/v1/agents`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
		if (res.status === 401) throw new EngineError("AUTH", "The Worker refused that owner token.");
		if (res.status === 404) throw new EngineError("ENGINE_UNAVAILABLE", "This Worker is older than Piopio: it has no agent registry. Deploy it again (packages/cloud: node scripts/deploy.ts).");
		if (!res.ok) throw new EngineError("ENGINE_UNAVAILABLE", `${url}/v1/agents answered ${res.status}.`);
		const { agents } = (await res.json()) as { agents: CloudStatus["agents"] };
		return { ...(version ? { version } : {}), agents };
	}

	async connect(rawUrl: string, token: string): Promise<CloudStatus> {
		const url = cloudOrigin(rawUrl);
		if (!token.trim()) throw new EngineError("INVALID", "Paste the Worker's owner token (OWNER_TOKEN when it was deployed).");
		const { version, agents } = await this.check(url, token.trim());
		await this.options.secrets.set(SECRET_CLOUD, token.trim());
		const config: CloudConfig = { url, connectedAt: new Date().toISOString(), ...(version ? { version } : {}) };
		writeFileSync(this.options.file, JSON.stringify(config, null, "\t"));
		return { connected: true, url, reachable: true, ...(version ? { version } : {}), connectedAt: config.connectedAt, agents };
	}

	async status(): Promise<CloudStatus> {
		const config = this.config();
		if (!config) return { connected: false, agents: [] };
		const base = { connected: true, url: config.url, connectedAt: config.connectedAt };
		try {
			const { version, agents } = await this.check(config.url, await this.token());
			return { ...base, reachable: true, ...(version ? { version } : {}), agents };
		} catch (error) {
			return { ...base, reachable: false, error: (error as Error).message, agents: [] };
		}
	}

	async disconnect(): Promise<void> {
		this.close();
		rmSync(this.options.file, { force: true });
		await this.options.secrets.delete(SECRET_CLOUD);
	}

	/** The socket to one cloud agent's object, opened on first use. */
	agent(id: string): AgentSocket {
		const config = this.config();
		if (!config) throw new EngineError("ENGINE_UNAVAILABLE", "No cloud is connected. Connect one in Settings › This Mac & cloud.");
		let socket = this.sockets.get(id);
		if (!socket) {
			const url = `${config.url.replace(/^http/, "ws")}/v1/ws?agent=${encodeURIComponent(id)}`;
			socket = new AgentSocket(url, () => this.token(), this.options.webSocket ?? ((u, t) => new WebSocket(u, { headers: { Authorization: `Bearer ${t}` } } as unknown as string[])), this.options.log);
			this.sockets.set(id, socket);
		}
		return socket;
	}

	/** Calls a method on one cloud agent's object. */
	call<M extends MethodName>(agentId: string, method: M, params: Params<M>): Promise<Result<M>> {
		return this.agent(agentId).call(method, params);
	}

	/** Closes one agent's socket (it moved back to the Mac). */
	drop(id: string): void {
		this.sockets.get(id)?.close();
		this.sockets.delete(id);
	}

	close(): void {
		for (const socket of this.sockets.values()) socket.close();
		this.sockets.clear();
	}
}

/**
 * One agent's socket: JSON-RPC calls, `session.events` routed to their subscriptions, and after a drop a new socket
 * on the next call (or on its own while something is subscribed), followed by `onReconnect` for the views.
 */
export class AgentSocket {
	private socket?: Socket;
	private opening?: Promise<Socket>;
	private nextId = 1;
	private readonly waiters = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
	readonly subscriptions = new Map<string, (n: Notification) => void>();
	private readonly reconnectors = new Set<() => void>();
	private closed = false;
	private attempt = 0;
	private helloResult?: Result<"engine.hello">;
	private retry?: NodeJS.Timeout;

	constructor(
		private readonly url: string,
		private readonly token: () => Promise<string>,
		private readonly make: (url: string, token: string) => Socket,
		private readonly log?: (line: string) => void,
	) {}

	/** Runs after the socket came back from a drop (subscriptions on the old one are gone). */
	onReconnect(listener: () => void): () => void {
		this.reconnectors.add(listener);
		return () => this.reconnectors.delete(listener);
	}

	private open(): Promise<Socket> {
		if (this.socket && this.socket.readyState === 1) return Promise.resolve(this.socket);
		this.opening ??= (async () => {
			const token = await this.token();
			const ws = await new Promise<Socket>((resolve, reject) => {
				const ws = this.make(this.url, token);
				const timer = setTimeout(() => (ws.close(), reject(new EngineError("ENGINE_UNAVAILABLE", "Your cloud didn't answer in time."))), 15_000);
				ws.addEventListener("open", () => (clearTimeout(timer), resolve(ws)), { once: true });
				ws.addEventListener("error", () => (clearTimeout(timer), reject(new EngineError("ENGINE_UNAVAILABLE", "Couldn't reach your cloud. Check the connection, or Settings › This Mac & cloud."))), { once: true });
			});
			ws.addEventListener("message", (e) => this.onMessage(String((e as MessageEvent).data)));
			ws.addEventListener("close", () => this.onClose(ws));
			this.socket = ws;
			this.helloResult = await this.send<Result<"engine.hello">>(ws, "engine.hello", { token, client: "piopio-engine", protocolVersion: "1.0" });
			this.attempt = 0;
			return ws;
		})().finally(() => (this.opening = undefined));
		return this.opening;
	}

	/** What the object said at `engine.hello` (its models, among others). */
	async hello(): Promise<Result<"engine.hello">> {
		await this.open();
		return this.helloResult!;
	}

	async call<T = unknown>(method: string, params: unknown): Promise<T> {
		if (this.closed) throw new EngineError("ENGINE_UNAVAILABLE", "This cloud connection was closed.");
		return this.send<T>(await this.open(), method, params);
	}

	private send<T>(ws: Socket, method: string, params: unknown): Promise<T> {
		const id = this.nextId++;
		return new Promise<T>((resolve, reject) => {
			this.waiters.set(id, { resolve: resolve as (v: unknown) => void, reject });
			ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
		});
	}

	private onMessage(raw: string): void {
		let message: { id?: number; method?: string; params?: Notification; result?: unknown; error?: { message: string; data?: { code?: string } } };
		try {
			message = JSON.parse(raw);
		} catch {
			return;
		}
		if (message.method === "session.events" && message.params) {
			this.subscriptions.get(message.params.subscriptionId)?.(message.params);
			return;
		}
		if (message.id === undefined) return;
		const waiter = this.waiters.get(message.id);
		this.waiters.delete(message.id);
		if (!waiter) return;
		if (message.error) {
			const code = message.error.data?.code;
			waiter.reject(new EngineError(code === "BUSY" || code === "AUTH" || code === "NOT_FOUND" || code === "INVALID" ? code : "INTERNAL", message.error.message));
		} else waiter.resolve(message.result);
	}

	private onClose(ws: Socket): void {
		if (this.socket !== ws) return;
		this.socket = undefined;
		for (const w of this.waiters.values()) w.reject(new EngineError("ENGINE_UNAVAILABLE", "The connection to your cloud dropped."));
		this.waiters.clear();
		this.subscriptions.clear();
		this.scheduleReconnect();
	}

	/** While someone is watching, the socket comes back by itself, and they subscribe again. */
	private scheduleReconnect(): void {
		if (this.closed || this.reconnectors.size === 0 || this.retry) return;
		const delay = RECONNECT_MS[Math.min(this.attempt++, RECONNECT_MS.length - 1)]!;
		this.retry = setTimeout(() => {
			this.retry = undefined;
			this.open()
				.then(() => {
					for (const listener of [...this.reconnectors]) listener();
				})
				.catch((error: Error) => {
					this.log?.(`Cloud: ${error.message}`);
					this.scheduleReconnect();
				});
		}, delay);
		this.retry.unref?.();
	}

	close(): void {
		this.closed = true;
		clearTimeout(this.retry);
		this.socket?.close();
		this.socket = undefined;
	}
}

/** Applies a batch of events to a snapshot, as the app does. */
export function applyEvents(snapshot: Snapshot, events: readonly SessionEvent[]): Snapshot {
	let s = snapshot;
	for (const e of events) {
		switch (e.type) {
			case "resnapshot":
				s = structuredClone(e.snapshot);
				break;
			case "state":
				s.state = e.state;
				break;
			case "item.added": {
				const at = e.before ? s.items.findIndex((i) => i.id === e.before) : -1;
				if (at >= 0) s.items.splice(at, 0, e.item);
				else s.items.push(e.item);
				break;
			}
			case "item.updated": {
				const at = s.items.findIndex((i) => i.id === e.item.id);
				if (at >= 0) s.items[at] = e.item;
				break;
			}
			case "item.replaced": {
				const at = s.items.findIndex((i) => i.id === e.oldId);
				if (at >= 0) s.items[at] = e.item;
				else s.items.push(e.item);
				break;
			}
			case "item.removed":
				s.items = s.items.filter((i) => i.id !== e.itemId);
				break;
			case "item.delta": {
				const item = s.items.find((i) => i.id === e.itemId) as { parts?: { type: string; text: string }[] } | undefined;
				if (!item?.parts) break;
				const part = item.parts[e.partIndex];
				if (part) part.text += e.textDelta;
				else item.parts[e.partIndex] = { type: e.partType, text: e.textDelta };
				break;
			}
		}
	}
	return s;
}

/**
 * One conversation of a cloud agent (a person's, or a run's), as a Runtime: what the app subscribes to through this
 * engine. The snapshot is the cloud's, kept in step here; sending goes to the cloud.
 */
export class CloudAgentView implements Runtime {
	private readonly emitter = new Emitter();
	private subscriptionId?: string;
	private readonly stopReconnect: () => void;

	private constructor(
		readonly ref: ContainerRef,
		private readonly socket: AgentSocket,
		private current: Snapshot,
	) {
		this.stopReconnect = socket.onReconnect(() => void this.resubscribe().catch(() => undefined));
	}

	static async open(socket: AgentSocket, ref: ContainerRef): Promise<CloudAgentView> {
		const placeholder: Snapshot = { ref, items: [], state: { status: "idle", queue: [], usage: { inputTokens: 0, outputTokens: 0, costUsd: 0 } } as unknown as Snapshot["state"] };
		const view = new CloudAgentView(ref, socket, placeholder);
		try {
			await view.resubscribe(false);
		} catch (error) {
			view.stopReconnect();
			throw error;
		}
		return view;
	}

	/** Subscribes (again) on the agent's socket; after a drop, the app gets the fresh snapshot as a `resnapshot`. */
	private async resubscribe(emit = true): Promise<void> {
		const { subscriptionId, snapshot } = await this.socket.call<Result<"sessions.subscribe">>("sessions.subscribe", { ref: this.ref });
		this.subscriptionId = subscriptionId;
		this.current = { ...snapshot, ref: this.ref };
		this.socket.subscriptions.set(subscriptionId, (n) => {
			const events = n.events.map((e) => (e.type === "resnapshot" ? { ...e, snapshot: { ...e.snapshot, ref: this.ref } } : e));
			this.current = applyEvents(this.current, events);
			this.emitter.emit(events);
		});
		if (emit) this.emitter.emit([{ type: "resnapshot", snapshot: structuredClone(this.current) }]);
	}

	snapshot(): Snapshot {
		return structuredClone(this.current);
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: SubmitOptions): Promise<{ disposition: "started" | "queued" }> {
		if (options.attachments?.length) throw new EngineError("INVALID", "Attachments don't reach cloud agents yet; send the text alone.");
		const result = await this.socket.call<Result<"sessions.submit">>("sessions.submit", { ref: this.ref, input: { text }, whenBusy: options.whenBusy, ...(options.requestId ? { clientRequestId: options.requestId } : {}) });
		return { disposition: result.disposition === "queued" ? "queued" : "started" };
	}

	async abort(): Promise<void> {
		await this.socket.call("sessions.abort", { ref: this.ref });
	}

	async configure(_change: { model?: ModelRef; thinking?: string; web?: boolean }): Promise<void> {
		throw new EngineError("INVALID", "A cloud agent's model is in its definition: change it there.");
	}

	async close(): Promise<void> {
		this.stopReconnect();
		if (!this.subscriptionId) return;
		this.socket.subscriptions.delete(this.subscriptionId);
		await this.socket.call("sessions.unsubscribe", { subscriptionId: this.subscriptionId }).catch(() => undefined);
	}
}
