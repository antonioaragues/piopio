/**
 * The engine's `skills.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `skills.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { dirname, join, resolve } from "node:path";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { type Params, type Result } from "@piopio/protocol";
import { projectPath } from "@piopio/pi-extensions";
import { EngineError } from "../models.js";
import { loadSkills, type Skill } from "@earendil-works/pi-coding-agent";
import { moveToTrash } from "../sessions.js";
import { skillSource } from "../tools/chat-resources.js";
import { editable, parseSkill, skillsRoot, writeSkill } from "../skills.js";
import type { SkillInfo } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function skillsHandlers(engine: Engine): Handlers<"skills"> {
	return {
		"skills.list": async (params, _call) => {
			return { skills: await skillList(engine, (params as Params<"skills.list">).project) } satisfies Result<"skills.list">;
		},
		"skills.get": async (params, _call) => {
			const p = params as Params<"skills.get">;
			const info = (await skillList(engine, engine.projectOf(p.path))).find((s) => s.path === p.path);
			if (!info) throw new EngineError("NOT_FOUND", "That skill isn't loaded.");
			return { info, body: parseSkill(readFileSync(p.path, "utf8")).body } satisfies Result<"skills.get">;
		},
		"skills.save": async (params, _call) => {
			const p = params as Params<"skills.save">;
			const roots = skillRoots(engine, p.project);
			if (p.path && !editable(p.path, roots)) throw new EngineError("INVALID", "Only your own skills can be changed here; a package's change with the package.");
			const path = writeSkill(skillsRoot(engine.chatResources.agentDir, p.project), { name: p.name, description: p.description, body: p.body, ...(p.manual ? { manual: true } : {}) }, p.path);
			await engine.skillsChanged();
			return { path } satisfies Result<"skills.save">;
		},
		"skills.delete": async (params, _call) => {
			const p = params as Params<"skills.delete">;
			if (!editable(p.path, skillRoots(engine, engine.projectOf(p.path)))) throw new EngineError("INVALID", "Only your own skills can be deleted here.");
			moveToTrash(dirname(p.path), engine.options.trashDir ?? join(homedir(), ".Trash"));
			await engine.skillsChanged();
			return {} satisfies Result<"skills.delete">;
		},
	};
}

/** Yours, a project's (with `project`), and packages'; pi's own order, the first of a name wins. */
async function skillList(engine: Engine, project?: string): Promise<SkillInfo[]> {
	const all: Skill[] = [...(await engine.chatResources.allSkills())];
	if (project) for (const s of loadSkills({ cwd: project, agentDir: engine.chatResources.agentDir, skillPaths: [], includeDefaults: true }).skills) if (!all.some((a) => a.filePath === s.filePath)) all.push(s);
	const yours = skillRoots(engine).map((r) => `${resolve(r)}/`);
	const ofProject = project ? skillRoots(engine, project).slice(2).map((r) => `${resolve(r)}/`) : [];
	return all.flatMap((s): SkillInfo[] => {
		const path = resolve(s.filePath);
		const where = yours.some((r) => path.startsWith(r)) ? "yours" : ofProject.some((r) => path.startsWith(r)) ? "project" : project && path.startsWith(`${resolve(project)}/`) ? "project" : "package";
		if (where === "project" && !project) return [];
		return [{ name: s.name, description: s.description, path: s.filePath, where, manual: s.disableModelInvocation, editable: where !== "package" && path.endsWith("/SKILL.md"), ...(where === "package" ? { source: skillSource(s) } : {}) }];
	});
}

/** Where your skills may be written: every project's folders, and one project's when given (backlog D9). */
function skillRoots(engine: Engine, project?: string): string[] {
	const own = project ? [join(".pi", "skills"), join(".agents", "skills")].flatMap((rel) => projectPath(project, rel) ?? []) : [];
	return [skillsRoot(engine.chatResources.agentDir), join(homedir(), ".agents", "skills"), ...own];
}
