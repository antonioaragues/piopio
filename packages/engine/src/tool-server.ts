/**
 * Piopio's tools for coding agents that take MCP servers by address (docs/spec/31 CA8): Antigravity CLI and Codex. A
 * loopback-only HTTP server (127.0.0.1, a port of its own, started when first needed) serves each open conversation's
 * tools at `/mcp/<secret>`, as MCP's Streamable HTTP without sessions (a fresh server per request, plain JSON answers).
 * An agent that can't reach HTTP gets the stdio bridge (`mcp-bridge.ts`) pointed at the same address.
 */
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { piopioServer, type CapturedTool } from "./runtimes/claude-code-tools.js";

/** What a conversation serves: its tools, how a call finds the agent's tool call, and the turn's stop signal. */
export type ToolRoute = { tools: () => readonly CapturedTool[]; callIdFor: (name: string, args: Record<string, unknown>) => string; signal: () => AbortSignal | undefined };

export class ToolServer {
	private server?: Server;
	private starting?: Promise<number>;
	private readonly routes = new Map<string, ToolRoute>();

	/** Serves a conversation's tools; the address works until `close`. */
	async register(route: ToolRoute): Promise<{ url: string; close: () => void }> {
		const port = await this.start();
		const secret = randomBytes(18).toString("base64url");
		this.routes.set(secret, route);
		return { url: `http://127.0.0.1:${port}/mcp/${secret}`, close: () => this.routes.delete(secret) };
	}

	private start(): Promise<number> {
		this.starting ??= new Promise((resolve, reject) => {
			const server = createServer((req, res) => void this.handle(req, res));
			server.once("error", reject);
			server.listen(0, "127.0.0.1", () => resolve((server.address() as { port: number }).port));
			this.server = server;
		});
		return this.starting;
	}

	private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
		const secret = /^\/mcp\/([A-Za-z0-9_-]+)$/.exec(req.url ?? "")?.[1];
		const route = secret ? this.routes.get(secret) : undefined;
		if (!route) {
			res.writeHead(404).end();
			return;
		}
		if (req.method !== "POST") {
			res.writeHead(405, { allow: "POST" }).end();
			return;
		}
		let body = "";
		for await (const chunk of req) body += chunk;
		let parsed: unknown;
		try {
			parsed = JSON.parse(body);
		} catch {
			res.writeHead(400).end();
			return;
		}
		const { instance } = piopioServer(route.tools(), route.callIdFor, route.signal);
		const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
		res.on("close", () => {
			void transport.close();
			void instance.close();
		});
		await instance.connect(transport);
		await transport.handleRequest(req, res, parsed);
	}

	async close(): Promise<void> {
		this.routes.clear();
		const server = this.server;
		this.server = undefined;
		this.starting = undefined;
		if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
	}
}

/** The stdio bridge's script, next to this one (dist, the app's bundle) or as source (tests). */
export function bridgeScript(): string {
	const here = dirname(fileURLToPath(import.meta.url));
	return [join(here, "mcp-bridge.js"), join(here, "mcp-bridge.ts")].find(existsSync) ?? join(here, "mcp-bridge.js");
}
