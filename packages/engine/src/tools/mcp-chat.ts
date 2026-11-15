/**
 * MCP helpers shared by the memory providers and Settings' probe: how to reach a server from pi's `mcp.json`, and a
 * timeout. Chats reach MCP servers through pi's own MCP extension (one engine for conversations, 2026-11-15); the ones
 * not turned on for chats in Settings › MCP servers are refused there (`notInChat`).
 */
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { McpConfig, RawServer } from "../mcp.js";

/** Global servers chats don't use (Settings › MCP servers): a chat's pi session refuses their tools. */
export function notInChat(config: McpConfig, inChat: (name: string, server: RawServer) => boolean): string[] {
	return config.globalServers().flatMap(({ name, server }) => (inChat(name, server) ? [] : [name]));
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
