/**
 * MCP servers as pi configures them (pi-coding-agent docs/mcp.md): `~/.pi/agent/mcp.json` (global) and
 * `<project>/.pi/mcp.json` (project, read by pi only when the project is trusted). Settings › MCP servers
 * lists and edits these files; Build sessions connect to the servers through pi's own MCP extension.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { McpServerInfo } from "@piopio/protocol";
import { EngineError } from "./models.js";

type Scope = "global" | "project";
export type RawServer = {
	command?: string;
	args?: string[];
	url?: string;
	type?: string;
	env?: Record<string, string>;
	enabled?: boolean;
	description?: string;
	/** pi's per-tool exposure: "hidden" turns a tool off (Settings › MCP servers, a server's tools). */
	toolExposure?: Record<string, string>;
	[key: string]: unknown;
};
type RawFile = { mcpServers?: Record<string, RawServer>; [key: string]: unknown };

export class McpConfig {
	constructor(private readonly agentDir: string) {}

	list(cwd?: string): { servers: McpServerInfo[]; errors: string[] } {
		const errors: string[] = [];
		const servers: McpServerInfo[] = [];
		for (const scope of ["global", "project"] as const) {
			if (scope === "project" && !cwd) continue;
			const path = this.path(scope, cwd);
			let file: RawFile;
			try {
				file = read(path);
			} catch (error) {
				errors.push(`${path}: ${(error as Error).message}`);
				continue;
			}
			for (const [name, s] of Object.entries(file.mcpServers ?? {})) {
				const override = scope === "project" && !s.command && !s.url && !s.type;
				servers.push({
					name,
					scope,
					transport: s.url || s.type === "http" || s.type === "streamable-http" ? "http" : "stdio",
					...(s.command ? { command: s.command } : {}),
					...(s.args?.length ? { args: s.args } : {}),
					...(s.url ? { url: s.url } : {}),
					enabled: s.enabled !== false,
					...(s.description ? { description: s.description } : {}),
					...(override ? { override: true } : {}),
					...(s.env && Object.keys(s.env).length ? { env: Object.keys(s.env) } : {}),
					...(hiddenTools(s).length ? { hiddenTools: hiddenTools(s) } : {}),
				});
			}
		}
		return { servers, errors };
	}

	/** The global servers that are on, as written (Chat connects to these; projects are Build's). */
	enabledGlobal(): { name: string; server: RawServer }[] {
		let file: RawFile;
		try {
			file = read(this.path("global"));
		} catch {
			return [];
		}
		return Object.entries(file.mcpServers ?? {})
			.filter(([, s]) => s.enabled !== false && (s.command || s.url))
			.map(([name, server]) => ({ name, server }));
	}

	/** Every global server, on or off (Chat picks its own). */
	globalServers(): { name: string; server: RawServer }[] {
		let file: RawFile;
		try {
			file = read(this.path("global"));
		} catch {
			return [];
		}
		return Object.entries(file.mcpServers ?? {})
			.filter(([, s]) => s.command || s.url)
			.map(([name, server]) => ({ name, server }));
	}

	/** A server as it runs: a project entry that only overrides takes the rest from the global one. */
	resolve(scope: Scope, cwd: string | undefined, name: string): RawServer {
		const own = read(this.path(scope, cwd)).mcpServers?.[name];
		if (!own) throw new EngineError("NOT_FOUND", `No MCP server “${name}”.`);
		if (scope === "project" && !own.command && !own.url && !own.type) return { ...read(this.path("global")).mcpServers?.[name], ...own };
		return own;
	}

	/** One tool on or off (pi's `toolExposure`: "hidden"), shared with the pi CLI. */
	setTool(scope: Scope, cwd: string | undefined, name: string, tool: string, enabled: boolean): void {
		this.edit(scope, cwd, (file) => {
			const server = file.mcpServers?.[name];
			if (!server) throw new EngineError("NOT_FOUND", `No MCP server “${name}”.`);
			const exposure = { ...server.toolExposure };
			if (enabled) delete exposure[tool];
			else exposure[tool] = "hidden";
			if (Object.keys(exposure).length) server.toolExposure = exposure;
			else delete server.toolExposure;
		});
	}

	add(scope: Scope, cwd: string | undefined, name: string, server: { command?: string; args?: string[]; url?: string; env?: Record<string, string>; description?: string; enabled?: boolean }): void {
		if (!/^[A-Za-z0-9_-]+$/.test(name)) throw new EngineError("INVALID", "Server names may use only letters, digits, - and _.");
		if (!server.command === !server.url) throw new EngineError("INVALID", "Give either a command (stdio) or a URL (HTTP).");
		if (server.url && !/^https?:\/\//.test(server.url)) throw new EngineError("INVALID", "The URL must start with http:// or https://.");
		this.edit(scope, cwd, (file) => {
			file.mcpServers ??= {};
			file.mcpServers[name] = {
				...(server.command ? { command: server.command, ...(server.args?.length ? { args: server.args } : {}) } : { url: server.url! }),
				...(server.env && Object.keys(server.env).length ? { env: server.env } : {}),
				...(server.description ? { description: server.description } : {}),
				...(server.enabled === false ? { enabled: false } : {}),
			};
		});
	}

	remove(scope: Scope, cwd: string | undefined, name: string): void {
		this.edit(scope, cwd, (file) => {
			if (!file.mcpServers?.[name]) throw new EngineError("NOT_FOUND", `No MCP server “${name}”.`);
			delete file.mcpServers[name];
		});
	}

	setEnabled(scope: Scope, cwd: string | undefined, name: string, enabled: boolean): void {
		this.edit(scope, cwd, (file) => {
			const server = file.mcpServers?.[name];
			if (!server) throw new EngineError("NOT_FOUND", `No MCP server “${name}”.`);
			if (enabled) delete server.enabled; // true is the default (as pi writes it)
			else server.enabled = false;
		});
	}

	private path(scope: Scope, cwd?: string): string {
		if (scope === "global") return join(this.agentDir, "mcp.json");
		if (!cwd) throw new EngineError("INVALID", "Project servers need the project folder.");
		return join(cwd, ".pi", "mcp.json");
	}

	/** Reads, changes and writes back the file, keeping everything else in it. */
	private edit(scope: Scope, cwd: string | undefined, change: (file: RawFile) => void): void {
		const path = this.path(scope, cwd);
		const file = read(path);
		change(file);
		mkdirSync(dirname(path), { recursive: true });
		const tmp = `${path}.tmp`;
		writeFileSync(tmp, `${JSON.stringify(file, null, 2)}\n`);
		renameSync(tmp, path);
	}
}

function read(path: string): RawFile {
	if (!existsSync(path)) return {};
	const text = readFileSync(path, "utf8").trim();
	if (!text) return {};
	const parsed = JSON.parse(text) as unknown;
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not a JSON object");
	return parsed as RawFile;
}

export const hiddenTools = (s: RawServer) => Object.entries(s.toolExposure ?? {}).filter(([, v]) => v === "hidden").map(([k]) => k);
