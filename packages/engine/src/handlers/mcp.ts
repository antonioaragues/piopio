/**
 * The engine's `mcp.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `mcp.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { detectOtherApps, probe } from "../mcp-probe.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function mcpHandlers(engine: Engine): Handlers<"mcp"> {
	return {
		"mcp.list": async (params, _call) => {
			const p = params as Params<"mcp.list">;
			const list = engine.mcp.list(p.cwd ? engine.folder(p) : undefined);
			const global = new Map(engine.mcp.globalServers().map((g) => [g.name, g.server]));
			return { ...list, servers: list.servers.map((s) => (s.scope === "global" && global.has(s.name) ? { ...s, chat: engine.inChat(s.name, global.get(s.name)!) } : s)) } satisfies Result<"mcp.list">;
		},
		"mcp.add": async (params, _call) => {
			const p = params as Params<"mcp.add">;
			const { scope, cwd, name, chat, ...server } = p;
			engine.mcp.add(scope, cwd ? engine.folder({ cwd }) : undefined, name, server);
			if (scope === "global") {
				if (chat !== undefined) engine.setChat(name, chat);
			}
			return {};
		},
		"mcp.probe": async (params, _call) => {
			const p = params as Params<"mcp.probe">;
			if (!p.command === !p.url) throw new EngineError("INVALID", "Give either a command or a URL.");
			return (await probe(p)) satisfies Result<"mcp.probe">;
		},
		"mcp.status": async (params, _call) => {
			const p = params as Params<"mcp.status">;
			const cwd = p.cwd ? engine.folder(p) : undefined;
			return (await engine.mcpStatus.get(`${p.scope}:${cwd ?? ""}:${p.name}`, engine.mcp.resolve(p.scope, cwd, p.name), p.refresh)) satisfies Result<"mcp.status">;
		},
		"mcp.setChat": async (params, _call) => {
			const p = params as Params<"mcp.setChat">;
			engine.setChat(p.name, p.chat);
			return {};
		},
		"mcp.setTool": async (params, _call) => {
			const p = params as Params<"mcp.setTool">;
			engine.mcp.setTool(p.scope, p.cwd ? engine.folder(p) : undefined, p.name, p.tool, p.enabled);
			return {};
		},
		"mcp.detect": async (_params, _call) => {
			return { found: detectOtherApps(new Set(engine.mcp.list().servers.map((s) => s.name))) } satisfies Result<"mcp.detect">;
		},
		"mcp.remove": async (params, _call) => {
			const p = params as Params<"mcp.remove">;
			engine.mcp.remove(p.scope, p.cwd ? engine.folder(p) : undefined, p.name);
			return {};
		},
		"mcp.setEnabled": async (params, _call) => {
			const p = params as Params<"mcp.setEnabled">;
			engine.mcp.setEnabled(p.scope, p.cwd ? engine.folder(p) : undefined, p.name, p.enabled);
			return {};
		},
	};
}
