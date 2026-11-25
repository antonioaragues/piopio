/**
 * The engine's `git.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `git.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import * as gitOps from "../git.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function gitHandlers(engine: Engine): Handlers<"git"> {
	return {
		"git.status": async (params, _call) => {
			return (await gitOps.status(engine.folder(params))) satisfies Result<"git.status">;
		},
		"git.branches": async (params, _call) => {
			return { branches: await gitOps.branches(engine.folder(params)) } satisfies Result<"git.branches">;
		},
		"git.log": async (params, _call) => {
			const p = params as Params<"git.log">;
			return { commits: await gitOps.log(engine.folder(p), p.since, p.limit ?? 20) } satisfies Result<"git.log">;
		},
		"git.checkout": async (params, _call) => {
			const p = params as Params<"git.checkout">;
			await gitOps.checkout(engine.folder(p), p.branch, p.create ?? false, p.base);
			engine.projects.touch();
			return {};
		},
		"git.commit": async (params, _call) => {
			const p = params as Params<"git.commit">;
			return { commit: await gitOps.commit(engine.folder(p), p.message, { ...(p.paths ? { paths: p.paths } : {}), ...(p.amend ? { amend: true } : {}) }) } satisfies Result<"git.commit">;
		},
		"git.message": async (params, _call) => {
			const p = params as Params<"git.message">;
			return { message: await gitOps.commitMessage(engine.folder(p), p.paths, (system, prompt) => engine.hub.utility(system, prompt)) } satisfies Result<"git.message">;
		},
		"git.sync": async (params, _call) => {
			const p = params as Params<"git.sync">;
			const cwd = engine.folder(p);
			const output = p.action === "push" ? await gitOps.push(cwd) : p.action === "pull" ? await gitOps.pull(cwd) : await gitOps.fetchAll(cwd);
			engine.projects.touch();
			return { output } satisfies Result<"git.sync">;
		},
		"git.suggestBranch": async (params, _call) => {
			const p = params as Params<"git.suggestBranch">;
			return { branch: gitOps.branchName(p.prompt) } satisfies Result<"git.suggestBranch">;
		},
	};
}
