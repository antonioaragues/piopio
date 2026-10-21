/**
 * Webhook triggers (docs/spec/06-agents §6 PR3): a local HTTP endpoint, `POST /hooks/<agentId>/<triggerId>/<token>`,
 * where the token is an HMAC of the agent and trigger under a key kept in the engine's home, so a URL can't be guessed
 * and stops working when the key is replaced. The body (up to 1 MB) goes into the trigger's prompt and runs as a run.
 * An `Idempotency-Key` or `X-Delivery-Id` header makes a retried delivery a no-op.
 */
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";

const MAX_BODY = 1_000_000;
export const DEFAULT_HOOKS_PORT = 47615;

export type Fire = (agentId: string, triggerId: string, body: string, deliveryId?: string) => Promise<{ runId: string }>;

export class Hooks {
	private server?: Server;
	private readonly key: Buffer;
	port = 0;

	constructor(
		keyFile: string,
		private readonly fire: Fire,
		private readonly log: (line: string) => void,
	) {
		if (!existsSync(keyFile)) {
			writeFileSync(keyFile, `${randomBytes(32).toString("hex")}\n`, { mode: 0o600 });
			chmodSync(keyFile, 0o600);
		}
		this.key = Buffer.from(readFileSync(keyFile, "utf8").trim(), "hex");
	}

	token(agentId: string, triggerId: string): string {
		return createHmac("sha256", this.key).update(`${agentId}/${triggerId}`).digest("base64url").slice(0, 32);
	}

	url(agentId: string, triggerId: string): string {
		return `http://127.0.0.1:${this.port}/hooks/${agentId}/${triggerId}/${this.token(agentId, triggerId)}`;
	}

	/** Listens on 127.0.0.1:`port`; when it's taken, on any free port (the URLs then change with each start). */
	async listen(port: number): Promise<void> {
		const server = createServer((req, res) => {
			void this.handle(req).then(
				({ status, body }) => {
					res.writeHead(status, { "content-type": "application/json" });
					res.end(JSON.stringify(body));
				},
				() => {
					res.writeHead(500, { "content-type": "application/json" });
					res.end(JSON.stringify({ error: "internal" }));
				},
			);
		});
		const bind = (p: number) =>
			new Promise<void>((resolve, reject) => {
				server.once("error", reject);
				server.listen(p, "127.0.0.1", () => {
					server.off("error", reject);
					resolve();
				});
			});
		try {
			await bind(port);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE" || port === 0) throw error;
			this.log(`Webhook triggers: port ${port} is taken; using another one.`);
			await bind(0);
		}
		this.server = server;
		this.port = (server.address() as AddressInfo).port;
	}

	private async handle(req: IncomingMessage): Promise<{ status: number; body: unknown }> {
		const m = /^\/hooks\/([A-Za-z0-9_-]+)\/([a-z0-9_-]+)\/([A-Za-z0-9_-]+)\/?$/.exec(new URL(req.url ?? "/", "http://x").pathname);
		if (!m) return { status: 404, body: { error: "not found" } };
		const [, agentId, triggerId, token] = m as unknown as [string, string, string, string];
		const want = Buffer.from(this.token(agentId, triggerId));
		const got = Buffer.from(token);
		if (got.length !== want.length || !timingSafeEqual(got, want)) return { status: 403, body: { error: "bad signature" } };
		if (req.method !== "POST") return { status: 405, body: { error: "POST only" } };
		const chunks: Buffer[] = [];
		let size = 0;
		for await (const chunk of req) {
			size += (chunk as Buffer).length;
			if (size > MAX_BODY) return { status: 413, body: { error: "body over 1 MB" } };
			chunks.push(chunk as Buffer);
		}
		const header = req.headers["idempotency-key"] ?? req.headers["x-delivery-id"];
		const deliveryId = Array.isArray(header) ? header[0] : header;
		try {
			const { runId } = await this.fire(agentId, triggerId, Buffer.concat(chunks).toString("utf8"), deliveryId);
			return { status: 202, body: { runId } };
		} catch (error) {
			const code = (error as { code?: string }).code;
			return { status: code === "NOT_FOUND" ? 404 : 500, body: { error: (error as Error).message } };
		}
	}

	async close(): Promise<void> {
		await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
		this.server = undefined;
	}
}
