/** Minimal Engine Protocol client for tests and scripts. */
import { createConnection, type Socket } from "node:net";
import type { SessionEventsNotification } from "@piopio/protocol";

export class TestClient {
	private buf = "";
	private id = 1;
	private waiters = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
	readonly events: SessionEventsNotification[] = [];
	readonly notifications: { method: string; params: any }[] = [];
	private eventListeners: ((n: SessionEventsNotification) => void)[] = [];
	secrets: Record<string, string> = {};
	/** Answers `app.tool` like the Mac app (when the client said it serves it in engine.hello). */
	appTool?: (params: any) => any;

	private constructor(private readonly socket: Socket) {
		socket.setEncoding("utf8");
		socket.on("data", (d: string) => {
			this.buf += d;
			let i: number;
			while ((i = this.buf.indexOf("\n")) !== -1) {
				const line = this.buf.slice(0, i);
				this.buf = this.buf.slice(i + 1);
				if (line) this.onMessage(JSON.parse(line));
			}
		});
	}

	static connect(path: string): Promise<TestClient> {
		return new Promise((resolve, reject) => {
			const s = createConnection(path, () => resolve(new TestClient(s)));
			s.once("error", reject);
		});
	}

	call<T = any>(method: string, params: unknown = {}): Promise<T> {
		const id = this.id++;
		this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
		return new Promise((resolve, reject) => this.waiters.set(id, { resolve, reject }));
	}

	onEvents(listener: (n: SessionEventsNotification) => void) {
		this.eventListeners.push(listener);
	}

	/** Resolves when an event batch satisfies `predicate`. */
	waitFor(predicate: (n: SessionEventsNotification) => boolean, timeoutMs = 10_000): Promise<void> {
		if (this.events.some(predicate)) return Promise.resolve();
		return new Promise((resolve, reject) => {
			const t = setTimeout(() => reject(new Error("timeout waiting for events")), timeoutMs);
			this.onEvents((n) => {
				if (predicate(n)) {
					clearTimeout(t);
					resolve();
				}
			});
		});
	}

	close() {
		this.socket.end();
	}

	private onMessage(m: any) {
		if (m.method && !("id" in m)) this.notifications.push({ method: m.method, params: m.params });
		if (m.method === "session.events") {
			this.events.push(m.params);
			for (const l of this.eventListeners) l(m.params);
		} else if (m.method === "secrets.get") {
			this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { value: this.secrets[m.params.name] ?? null } })}\n`);
		} else if (m.method === "app.tool") {
			try {
				const result = this.appTool ? this.appTool(m.params) : { ok: false, output: "no handler" };
				this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, result })}\n`);
			} catch (error) {
				this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32000, message: (error as Error).message } })}\n`);
			}
		} else if ("id" in m) {
			const w = this.waiters.get(m.id);
			this.waiters.delete(m.id);
			if (m.error) w?.reject(Object.assign(new Error(m.error.message), { data: m.error.data }));
			else w?.resolve(m.result);
		}
	}
}
