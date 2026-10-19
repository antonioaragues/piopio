/** Minimal Engine Protocol client over WebSocket, for tests and scripts. */
import type { SessionEventsNotification } from "@piopio/protocol";

export class WsClient {
	private id = 1;
	private waiters = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
	readonly events: SessionEventsNotification[] = [];
	private eventListeners: ((n: SessionEventsNotification) => void)[] = [];
	readonly closed: Promise<{ code: number; reason: string }>;

	private constructor(private readonly ws: WebSocket) {
		ws.addEventListener("message", (e) => this.onMessage(JSON.parse(String(e.data))));
		this.closed = new Promise((resolve) =>
			ws.addEventListener("close", (e) => {
				for (const w of this.waiters.values()) w.reject(new Error(`socket closed (${e.code})`));
				this.waiters.clear();
				resolve({ code: e.code, reason: e.reason });
			}),
		);
	}

	static connect(url: string): Promise<WsClient> {
		return new Promise((resolve, reject) => {
			const ws = new WebSocket(url);
			ws.addEventListener("open", () => resolve(new WsClient(ws)), { once: true });
			ws.addEventListener("error", () => reject(new Error(`cannot connect to ${url}`)), { once: true });
		});
	}

	call<T = any>(method: string, params: unknown = {}): Promise<T> {
		const id = this.id++;
		this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
		return new Promise((resolve, reject) => this.waiters.set(id, { resolve, reject }));
	}

	/** Resolves with the first event batch (already received or future) that satisfies `predicate`. */
	waitFor(predicate: (n: SessionEventsNotification) => boolean, timeoutMs = 10_000): Promise<SessionEventsNotification> {
		const seen = this.events.find(predicate);
		if (seen) return Promise.resolve(seen);
		return new Promise((resolve, reject) => {
			const t = setTimeout(() => reject(new Error("timeout waiting for events")), timeoutMs);
			this.eventListeners.push((n) => {
				if (!predicate(n)) return;
				clearTimeout(t);
				resolve(n);
			});
		});
	}

	close() {
		this.ws.close();
	}

	private onMessage(m: any) {
		if (m.method === "session.events") {
			this.events.push(m.params);
			for (const l of this.eventListeners) l(m.params);
		} else if ("id" in m) {
			const w = this.waiters.get(m.id);
			this.waiters.delete(m.id);
			if (m.error) w?.reject(Object.assign(new Error(m.error.message), { data: m.error.data }));
			else w?.resolve(m.result);
		}
	}
}
