/**
 * The engine's `projects.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `projects.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { join } from "node:path";
import { type Params, type Result } from "@piopio/protocol";
import { listDir, readProjectFile, searchFiles, writeProjectFile } from "../files.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function projectsHandlers(engine: Engine): Handlers<"projects"> {
	return {
		"projects.list": async (_params, _call) => {
			return { projects: engine.projects.list() } satisfies Result<"projects.list">;
		},
		"projects.add": async (params, _call) => {
			const p = params as Params<"projects.add">;
			const project = engine.projects.add(p.path, p.lens);
			await engine.sessions.syncFolder(project.path);
			return { project } satisfies Result<"projects.add">;
		},
		"projects.configure": async (params, _call) => {
			const p = params as Params<"projects.configure">;
			const change = { ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.removeRule ? { removeRule: p.removeRule } : {}), ...(p.trust !== undefined ? { trust: p.trust } : {}), ...(p.linkFolder ? { linkFolder: p.linkFolder } : {}), ...(p.unlinkFolder ? { unlinkFolder: p.unlinkFolder } : {}), ...(p.prEvents ? { prEvents: p.prEvents } : {}), ...(p.check !== undefined ? { check: p.check } : {}), ...(p.network ? { network: p.network } : {}) };
			return { project: engine.projects.configure(p.id, change) } satisfies Result<"projects.configure">;
		},
		"projects.create": async (params, _call) => {
			const p = params as Params<"projects.create">;
			return { project: engine.projects.create(p.name, p.instructions) } satisfies Result<"projects.create">;
		},
		"projects.files": async (params, _call) => {
			const p = params as Params<"projects.files">;
			const limit = p.limit ?? 30;
			const own = await searchFiles(engine.folder(p), p.query, limit);
			// Linked folders (18 §18): their matches too, as absolute paths, once something is typed.
			const linked = p.query.trim() ? (await Promise.all(engine.projects.foldersFor(p.cwd).map(async (f) => (await searchFiles(f.path, p.query, 8)).map((m) => ({ ...m, path: join(f.path, m.path) }))))).flat() : [];
			const room = Math.max(limit - Math.min(linked.length, Math.ceil(limit / 2)), 0);
			return { files: [...own.slice(0, room), ...linked].slice(0, limit) } satisfies Result<"projects.files">;
		},
		"projects.listDir": async (params, _call) => {
			const p = params as Params<"projects.listDir">;
			return { entries: await listDir(engine.folder(p), p.dir) } satisfies Result<"projects.listDir">;
		},
		"projects.readFile": async (params, _call) => {
			const p = params as Params<"projects.readFile">;
			return (await readProjectFile(engine.folder(p), p.path)) satisfies Result<"projects.readFile">;
		},
		"projects.writeFile": async (params, _call) => {
			const p = params as Params<"projects.writeFile">;
			await writeProjectFile(engine.folder(p), p.path, p.content);
			return {};
		},
		"projects.remove": async (params, _call) => {
			const p = params as Params<"projects.remove">;
			const project = engine.projects.remove(p.id);
			await engine.sessions.forgetFolder(project.path);
			return {};
		},
	};
}
