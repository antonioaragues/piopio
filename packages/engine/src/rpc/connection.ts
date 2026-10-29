/**
 * One JSON-RPC 2.0 peer over a byte stream, framed as LF-delimited JSON.
 * Splits on LF bytes only (not readline), so U+2028/U+2029 inside strings are safe.
 */
import type { Duplex } from "node:stream";
import type { ErrorCode, JsonRpcId, JsonRpcMessage, JsonRpcRequest, JsonRpcResponse } from "@piopio/protocol";

export type RpcError = { code: number; message: string; data?: { code: ErrorCode } };
export type RequestHandler = (method: string, params: unknown) => Promise<unknown>;

const PARSE_ERROR = -32700;
const METHOD_NOT_FOUND = -32601;

export class RpcConnection {
	private buffer = Buffer.alloc(0);
	private nextId = 1;
	private pending = new Map<JsonRpcId, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
	private closedListeners: (() => void)[] = [];
	private closed = false;

	constructor(
		private readonly stream: Duplex,
		private readonly onRequest: RequestHandler,
	) {
		stream.on("data", (chunk: Buffer) => this.onData(chunk));
		stream.on("close", () => this.handleClose());
		stream.on("error", () => this.handleClose());
	}

	onClose(listener: () => void): void {
		if (this.closed) listener();
		else this.closedListeners.push(listener);
	}

	notify(method: string, params: unknown): void {
		this.write({ jsonrpc: "2.0", method, params });
	}

	/** Sends a request to the peer (engine → client calls such as secrets.get). */
	request(method: string, params: unknown, timeoutMs = 120_000): Promise<unknown> {
		if (this.closed) return Promise.reject(new Error("connection closed"));
		const id = `e${this.nextId++}`;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`${method} timed out`));
			}, timeoutMs);
			this.pending.set(id, {
				resolve: (v) => (clearTimeout(timer), resolve(v)),
				reject: (e) => (clearTimeout(timer), reject(e)),
			});
			this.write({ jsonrpc: "2.0", id, method, params });
		});
	}

	close(): void {
		this.stream.destroy();
	}

	private write(message: JsonRpcMessage): void {
		if (this.closed) return;
		this.stream.write(`${JSON.stringify(message)}\n`);
	}

	private onData(chunk: Buffer): void {
		this.buffer = Buffer.concat([this.buffer, chunk]);
		let newline: number;
		while ((newline = this.buffer.indexOf(0x0a)) !== -1) {
			let line = this.buffer.subarray(0, newline);
			this.buffer = this.buffer.subarray(newline + 1);
			if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
			if (line.length === 0) continue;
			let message: JsonRpcMessage;
			try {
				message = JSON.parse(line.toString("utf8")) as JsonRpcMessage;
			} catch {
				this.write({ jsonrpc: "2.0", id: 0, error: { code: PARSE_ERROR, message: "Parse error" } });
				continue;
			}
			void this.dispatch(message);
		}
	}

	private async dispatch(message: JsonRpcMessage): Promise<void> {
		if ("method" in message) {
			if (!("id" in message)) return; // client notifications are not used yet
			const req = message as JsonRpcRequest;
			try {
				const result = await this.onRequest(req.method, req.params ?? {});
				this.write({ jsonrpc: "2.0", id: req.id, result: result ?? {} });
			} catch (error) {
				this.write({ jsonrpc: "2.0", id: req.id, error: toRpcError(error) });
			}
			return;
		}
		const res = message as JsonRpcResponse;
		const waiter = this.pending.get(res.id);
		if (!waiter) return;
		this.pending.delete(res.id);
		if ("error" in res) waiter.reject(new Error(res.error.message));
		else waiter.resolve(res.result);
	}

	private handleClose(): void {
		if (this.closed) return;
		this.closed = true;
		for (const w of this.pending.values()) w.reject(new Error("connection closed"));
		this.pending.clear();
		for (const l of this.closedListeners) l();
	}
}

export class MethodNotFound extends Error {}

function toRpcError(error: unknown): RpcError {
	if (error instanceof MethodNotFound) return { code: METHOD_NOT_FOUND, message: error.message };
	const e = error as { code?: string; message?: string };
	if (typeof e?.code === "string") return { code: -32000, message: e.message ?? "Error", data: { code: e.code as ErrorCode } };
	return { code: -32603, message: e?.message ?? String(error), data: { code: "INTERNAL" } };
}
