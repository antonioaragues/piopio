/**
 * The engine's `github.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `github.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { join } from "node:path";
import { existsSync, mkdirSync } from "node:fs";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function githubHandlers(engine: Engine): Handlers<"github"> {
	return {
		"github.status": async (_params, _call) => {
			return (await engine.github.status()) satisfies Result<"github.status">;
		},
		"github.setToken": async (params, _call) => {
			const p = params as Params<"github.setToken">;
			return { login: await engine.github.setToken(p.token) } satisfies Result<"github.setToken">;
		},
		"github.signOut": async (_params, _call) => {
			await engine.github.signOut();
			return {} satisfies Result<"github.signOut">;
		},
		"github.repos": async (_params, _call) => {
			return { repos: await engine.github.repos() } satisfies Result<"github.repos">;
		},
		"github.clone": async (params, _call) => {
			const p = params as Params<"github.clone">;
			const name = p.repo.replace(/\.git$/, "").split("/").pop() || "repo";
			let dest = p.path?.trim() || join(engine.options.paths.projectsRoot, name);
			if (!p.path) for (let n = 2; existsSync(dest); n++) dest = join(engine.options.paths.projectsRoot, `${name}-${n}`);
			else if (existsSync(dest)) throw new EngineError("INVALID", `${dest} already exists.`);
			mkdirSync(engine.options.paths.projectsRoot, { recursive: true });
			await engine.github.clone(p.repo, dest);
			const project = engine.projects.add(dest);
			await engine.sessions.syncFolder(project.path);
			return { project } satisfies Result<"github.clone">;
		},
	};
}
