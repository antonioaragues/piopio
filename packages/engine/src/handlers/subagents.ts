/**
 * The engine's `subagents.*` methods (roadmap PAR12, docs/spec/05-build §4 "Custom subagents"), one handler each.
 * server.ts checks the params against the protocol before calling them.
 */
import { join } from "node:path";
import { homedir } from "node:os";
import { readFileSync, unlinkSync } from "node:fs";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { type Params, type Result, type SubagentInfo } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { moveToTrash } from "../sessions.js";
import { editableSubagent, listSubagents, parseSubagent, subagentsRoot, writeSubagent, type Subagent } from "../custom-subagents.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function subagentsHandlers(engine: Engine): Handlers<"subagents"> {
	const agentDir = () => engine.options.piAgentDir ?? getAgentDir();
	const roots = (project?: string) => [subagentsRoot(agentDir()), ...(project ? [subagentsRoot(agentDir(), project)] : [])];
	return {
		"subagents.list": async (params, _call) => {
			const p = params as Params<"subagents.list">;
			return { subagents: listSubagents(agentDir(), p.project).map(info) } satisfies Result<"subagents.list">;
		},
		"subagents.get": async (params, _call) => {
			const p = params as Params<"subagents.get">;
			const found = listSubagents(agentDir(), engine.projectOf(p.path)).find((a) => a.path === p.path);
			if (!found) throw new EngineError("NOT_FOUND", "That subagent isn't there any more.");
			return { info: info(found), instructions: parseSubagent(readFileSync(p.path, "utf8"))?.instructions ?? "" } satisfies Result<"subagents.get">;
		},
		"subagents.save": async (params, _call) => {
			const p = params as Params<"subagents.save">;
			if (p.path && !editableSubagent(p.path, roots(p.project ?? engine.projectOf(p.path)))) throw new EngineError("INVALID", "Only subagents in your agents folder or a project's .pi/agents can be changed here.");
			const path = writeSubagent(subagentsRoot(agentDir(), p.project), { name: p.name, description: p.description, ...(p.tools ? { tools: p.tools } : {}), ...(p.model ? { model: p.model } : {}), instructions: p.instructions }, p.path);
			// Renamed: the old file goes, so the old name stops being offered.
			if (p.path && p.path !== path) unlinkSync(p.path);
			await engine.skillsChanged();
			return { path } satisfies Result<"subagents.save">;
		},
		"subagents.delete": async (params, _call) => {
			const p = params as Params<"subagents.delete">;
			if (!editableSubagent(p.path, roots(engine.projectOf(p.path)))) throw new EngineError("INVALID", "Only subagents in your agents folder or a project's .pi/agents can be deleted here.");
			moveToTrash(p.path, engine.options.trashDir ?? join(homedir(), ".Trash"));
			await engine.skillsChanged();
			return {} satisfies Result<"subagents.delete">;
		},
	};
}

function info(a: Subagent): SubagentInfo {
	return { name: a.name, description: a.description, ...(a.tools ? { tools: a.tools } : {}), ...(a.model ? { model: a.model } : {}), path: a.path, where: a.where };
}
