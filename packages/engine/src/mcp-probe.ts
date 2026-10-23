/**
 * Settings › MCP servers (design handoff p0–p2): starts a server to see that it works and what tools it offers,
 * remembers each configured server's last result (the list's status dots), and finds servers configured in other
 * apps (Claude Desktop, Cursor, VS Code, Windsurf) to offer importing them. Nothing is imported on its own.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { McpProbe } from "@piopio/protocol";
import type { RawServer } from "./mcp.js";
import { transport } from "./tools/mcp-chat.js";

const PROBE_TIMEOUT_MS = 45_000;
const LOG_LIMIT = 8_000;
const STATUS_TTL_MS = 10 * 60_000;

/** Starts the server, lists its tools and closes it: "Started · 1.2 s" and the tools, or what went wrong in plain words. */
export async function probe(server: RawServer, timeoutMs = PROBE_TIMEOUT_MS): Promise<McpProbe> {
	const started = Date.now();
	let log = "";
	const client = new Client({ name: "piopio", version: "1.0.0" });
	const t = transport(server, "pipe");
	if (t instanceof StdioClientTransport) {
		t.stderr?.on("data", (chunk: Buffer) => {
			log = (log + chunk.toString()).slice(-LOG_LIMIT);
		});
	}
	const exited = new Promise<never>((_, reject) => {
		t.onclose = () => reject(new Error(server.url ? "The server closed the connection." : "Exited right after starting"));
	});
	exited.catch(() => undefined);
	try {
		await race(client.connect(t), exited, timeoutMs);
		const { tools } = await race(client.listTools(), exited, timeoutMs);
		return { ok: true, ms: Date.now() - started, tools: tools.map((tool) => ({ name: tool.name, ...(tool.description ? { description: firstLine(tool.description) } : {}) })), ...(log ? { log } : {}) };
	} catch (error) {
		return { ok: false, tools: [], error: plain(error as Error, server, log), ...(log ? { log } : {}) };
	} finally {
		t.onclose = undefined;
		await client.close().catch(() => undefined);
	}
}

/** Each configured server's last probe, kept a while so the list doesn't restart every server on every visit. */
export class McpStatus {
	private readonly cache = new Map<string, { at: number; spec: string; result: Promise<McpProbe> }>();

	get(key: string, server: RawServer, refresh = false): Promise<McpProbe> {
		const spec = JSON.stringify(server);
		const hit = this.cache.get(key);
		if (hit && !refresh && hit.spec === spec && Date.now() - hit.at < STATUS_TTL_MS) return hit.result;
		const result = probe(server);
		this.cache.set(key, { at: Date.now(), spec, result });
		return result;
	}
}

export type FoundServer = { name: string; command?: string; args?: string[]; url?: string; env?: Record<string, string> };

/** Where other apps keep their MCP servers on a Mac, and the key that holds them. */
const OTHER_APPS = [
	{ app: "Claude Desktop", path: ["Library", "Application Support", "Claude", "claude_desktop_config.json"], key: "mcpServers" },
	{ app: "Cursor", path: [".cursor", "mcp.json"], key: "mcpServers" },
	{ app: "VS Code", path: ["Library", "Application Support", "Code", "User", "mcp.json"], key: "servers" },
	{ app: "Windsurf", path: [".codeium", "windsurf", "mcp_config.json"], key: "mcpServers" },
];

/** Servers configured in other apps that Piopio's (pi's) global file doesn't have yet. */
export function detectOtherApps(known: ReadonlySet<string>, home = homedir()): { app: string; path: string; servers: FoundServer[] }[] {
	const out: { app: string; path: string; servers: FoundServer[] }[] = [];
	for (const { app, path, key } of OTHER_APPS) {
		const file = join(home, ...path);
		if (!existsSync(file)) continue;
		let entries: Record<string, Record<string, unknown>>;
		try {
			entries = ((JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>)[key] ?? {}) as Record<string, Record<string, unknown>>;
		} catch {
			continue;
		}
		const servers: FoundServer[] = [];
		for (const [rawName, s] of Object.entries(entries)) {
			const name = rawName.replace(/[^A-Za-z0-9_-]/g, "-");
			const url = (s.url ?? s.serverUrl) as string | undefined;
			const command = s.command as string | undefined;
			if (known.has(name) || (!url && !command)) continue;
			servers.push({
				name,
				...(command ? { command, ...(Array.isArray(s.args) && s.args.length ? { args: s.args.map(String) } : {}) } : { url: url! }),
				...(s.env && typeof s.env === "object" ? { env: Object.fromEntries(Object.entries(s.env as Record<string, unknown>).map(([k, v]) => [k, String(v)])) } : {}),
			});
		}
		if (servers.length) out.push({ app, path: file, servers });
	}
	return out;
}

function race<T>(work: Promise<T>, exited: Promise<never>, ms: number): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`No answer in ${Math.round(ms / 1000)} s.`)), ms);
		Promise.race([work, exited]).then(
			(v) => (clearTimeout(timer), resolve(v)),
			(e) => (clearTimeout(timer), reject(e)),
		);
	});
}

function firstLine(text: string): string {
	return text.split("\n")[0]!.slice(0, 200);
}

/** The error as someone setting up a server needs it. */
function plain(error: Error, server: RawServer, log: string): string {
	const text = `${error.message} ${(error as { code?: string }).code ?? ""}`;
	if (/ENOENT|spawn .* ENOENT|not found/i.test(text) && server.command) return `Can't find “${server.command}” on this Mac. Is it installed?`;
	if (/401|unauthorized|invalid_token/i.test(text)) return "The server wants you to sign in. Sign in with “pi mcp” in a terminal, then try again.";
	if (/ECONNREFUSED|fetch failed/i.test(text) && server.url) return `Nothing is answering at ${safeHost(server.url)}.`;
	if (/Exited|closed/i.test(text)) {
		const last = log.trim().split("\n").filter(Boolean).pop();
		return last ? `${error.message}: ${last.slice(0, 160)}` : error.message;
	}
	return error.message;
}

function safeHost(url: string): string {
	try {
		return new URL(url).host;
	} catch {
		return url;
	}
}
