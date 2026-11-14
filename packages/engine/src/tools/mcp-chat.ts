/**
 * MCP servers in Threads and Spaces (pi-durable runtimes). pi-durable has no MCP client, so this connects the
 * global servers from pi's `mcp.json` (the ones Settings › MCP servers edits) and offers their tools as a
 * pi-durable extension, `mcp__<server>__<tool>`. A server with `"exposure": "direct"` declares its tools to the
 * model; others are deferred and found with `tool_search` (Build reaches them through codemode instead).
 * Only the servers the user turned on for chats in Settings › MCP servers: chat has no approvals, so it's opt-in per
 * server. Tools turned off for a server (pi's `toolExposure`: "hidden") stay out.
 */
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section, type Extension } from "@earendil-works/pi-durable";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { hiddenTools, type McpConfig, type RawServer } from "../mcp.js";

export const MCP_EXTENSION = "piopio-mcp";
const CONNECT_TIMEOUT_MS = 15_000;

type Connected = { name: string; client: Client; tools: { name: string; description?: string; inputSchema: unknown; direct: boolean }[]; description?: string };

/** Shared by every runtime: one connection per server, made when a conversation first needs the tools. */
export class ChatMcp {
	private connecting?: Promise<Connected[]>;
	private listeners = new Set<() => void>();
	readonly toolSearch = createToolSearchExtension() as unknown as Extension;
	errors: string[] = [];
	/** Retries after a server didn't connect (it may still be starting); reset once one connects. */
	private retries = 0;

	constructor(
		private readonly config: McpConfig,
		private readonly inChat: (name: string, server: RawServer) => boolean,
	) {}

	private servers() {
		return this.config.globalServers().filter(({ name, server }) => this.inChat(name, server));
	}

	/**
	 * The extension with every connected server's tools, or undefined when off or without servers. `off`: servers the
	 * conversation turned off (docs/design/session-panel, step 3).
	 */
	async extension(off: (server: string) => boolean = () => false): Promise<Extension | undefined> {
		if (!this.servers().some(({ name }) => !off(name))) return undefined;
		this.connecting ??= this.connect();
		const servers = (await this.connecting).filter((s) => !off(s.name));
		if (!servers.length) return undefined;
		const tools = servers.flatMap((s) =>
			s.tools.map((t) =>
				defineTool({
					name: `mcp__${s.name}__${t.name}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 64),
					description: t.description ?? `${t.name} (MCP server ${s.name})`,
					parameters: Type.Unsafe<Record<string, unknown>>((t.inputSchema as object) ?? { type: "object", properties: {} }),
					...(t.direct ? {} : { deferred: true as const }),
					execute: async (args) => {
						const result = (await s.client.callTool({ name: t.name, arguments: args as Record<string, unknown> })) as { content?: { type: string; text?: string; data?: string; mimeType?: string }[]; isError?: boolean };
						type Block = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
						const output = (result.content ?? []).map((c): Block =>
							c.type === "text" ? { type: "text", text: c.text ?? "" } : c.type === "image" && c.data ? { type: "image", data: c.data, mimeType: c.mimeType ?? "image/png" } : { type: "text", text: JSON.stringify(c) },
						);
						return { output: output.length ? output : [{ type: "text" as const, text: "(no output)" }], ...(result.isError ? { isError: true } : {}) };
					},
				}),
			),
		);
		// tool_search doesn't say which servers are behind it, so the prompt names them (as pi's mcp_servers section does in Build).
		const deferred = servers.filter((s) => s.tools.some((t) => !t.direct));
		const sections = deferred.length ? [section("mcp_servers", () => serversSection(deferred))] : [];
		return defineExtension({ name: MCP_EXTENSION, tools, sections }) as unknown as Extension;
	}

	/** Servers or the setting changed: drop the connections; runtimes reinstall the extension. */
	async reset(): Promise<void> {
		const old = this.connecting;
		this.connecting = undefined;
		for (const s of (await old?.catch(() => [])) ?? []) await s.client.close().catch(() => undefined);
		for (const l of this.listeners) l();
	}

	/** A conversation's own list changed: runtimes reinstall the tools, keeping the connections. */
	refresh(): void {
		for (const l of this.listeners) l();
	}

	onChange(listener: () => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	async close(): Promise<void> {
		this.listeners.clear();
		await this.reset();
	}

	private async connect(): Promise<Connected[]> {
		this.errors = [];
		const results = await Promise.all(
			this.servers().map(async ({ name, server }) => {
				try {
					const client = new Client({ name: "piopio", version: "1.0.0" });
					await withTimeout(client.connect(transport(server)), CONNECT_TIMEOUT_MS);
					const { tools } = await withTimeout(client.listTools(), CONNECT_TIMEOUT_MS);
					const hidden = new Set(hiddenTools(server));
					// pi's exposure: the server's, unless `toolExposure` says otherwise for one tool ("direct", "deferred").
					const direct = (tool: string) => (server.toolExposure?.[tool] ?? server.exposure) === "direct";
					return {
						name,
						client,
						tools: tools.filter((t) => !hidden.has(t.name)).map((t) => ({ ...t, direct: direct(t.name) })),
						...(server.description ? { description: server.description } : {}),
					} as Connected;
				} catch (error) {
					this.errors.push(`${name}: ${(error as Error).message}`);
					return undefined;
				}
			}),
		);
		const connected = results.filter((r): r is Connected => Boolean(r));
		// A server that didn't answer is tried again a little later (it may have been starting, like Piopio's
		// browser), instead of staying out until the settings change: reset() reconnects and reinstalls the tools.
		if (this.errors.length && this.retries < 5) {
			const attempt = ++this.retries;
			setTimeout(() => void (this.retries === attempt && this.reset()), 2_000 * attempt).unref();
		} else if (!this.errors.length) {
			this.retries = 0;
		}
		return connected;
	}
}

/** The deferred servers, one line each, with how to reach their tools. */
export function serversSection(servers: readonly { name: string; description?: string }[]): string {
	const lines = servers.map((s) => `- ${s.name}${s.description ? `: ${s.description.replace(/\s+/g, " ").trim()}` : ""}`);
	return ["# MCP servers", "", "Some or all of these servers' tools aren't listed above; load them with `tool_search` (search for the server's name or what you need).", "", ...lines].join("\n");
}

export function transport(server: RawServer, stderr: "ignore" | "pipe" = "ignore") {
	const expand = (v: string) => v.replace(/\$\{(\w+)\}/g, (_, k: string) => process.env[k] ?? "");
	if (server.url) {
		const headers = Object.fromEntries(Object.entries((server.headers as Record<string, string> | undefined) ?? {}).map(([k, v]) => [k, expand(v)]));
		return new StreamableHTTPClientTransport(new URL(server.url), { requestInit: { headers } });
	}
	const env = Object.fromEntries(Object.entries({ ...process.env, ...server.env }).filter((e): e is [string, string] => typeof e[1] === "string").map(([k, v]) => [k, expand(v)]));
	return new StdioClientTransport({ command: server.command!, args: server.args ?? [], env, stderr });
}

export function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`no answer in ${ms / 1000}s`)), ms);
		promise.then(
			(v) => (clearTimeout(timer), resolve(v)),
			(e) => (clearTimeout(timer), reject(e)),
		);
	});
}

/** Installs the MCP tools (and `tool_search`) in a runtime's registry, and again whenever they change. */
export async function attachChatMcp(registry: { install(e: never): void; uninstall(e: never): void }, mcp: ChatMcp, off: (server: string) => boolean = () => false): Promise<() => void> {
	let current: Extension | undefined;
	const apply = async () => {
		const next = await mcp.extension(off).catch(() => undefined);
		if (current) {
			registry.uninstall(current as never);
			registry.uninstall(mcp.toolSearch as never);
		}
		current = next;
		if (next) {
			registry.install(next as never);
			registry.install(mcp.toolSearch as never);
		}
	};
	await apply();
	return mcp.onChange(() => void apply());
}
