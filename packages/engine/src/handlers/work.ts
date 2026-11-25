/**
 * The engine's `work.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `work.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { join } from "node:path";
import { existsSync, readFileSync, renameSync } from "node:fs";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { fitCheck } from "../work/fit.js";
import { type ProjectWork } from "../work/runner.js";
import { REPORT_FILE } from "../work/migrate.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function workHandlers(engine: Engine): Handlers<"work"> {
	return {
		"work.list": async (_params, _call) => {
			return { work: engine.work.list().map((w) => workView(engine, w)) } satisfies Result<"work.list">;
		},
		"work.get": async (params, _call) => {
			const p = params as Params<"work.get">;
			const work = engine.work.find(engine.projects.get(p.project).id);
			return (work ? { work: workView(engine, work) } : {}) satisfies Result<"work.get">;
		},
		"work.configure": async (params, _call) => {
			const p = params as Params<"work.configure">;
			const { project, ...change } = p;
			return { work: workView(engine, await engine.work.configure(project, change)) } satisfies Result<"work.configure">;
		},
		"work.accept": async (params, _call) => {
			const p = params as Params<"work.accept">;
			engine.sessions.plannerIn({ kind: "build", id: p.sessionId }, engine.projects.get(p.project).path);
			const work = await engine.work.configure(p.project, { parallel: true });
			await engine.sessions.planInParallel({ kind: "build", id: p.sessionId });
			return { work: workView(engine, work) } satisfies Result<"work.accept">;
		},
		"work.playbooks": async (params, _call) => {
			const p = params as Params<"work.playbooks">;
			return { playbooks: engine.work.playbooks(engine.projects.get(p.project).path).map((x) => ({ id: x.id, name: x.name, description: x.description, source: x.source })) } satisfies Result<"work.playbooks">;
		},
		"work.fitCheck": async (params, _call) => {
			const p = params as Params<"work.fitCheck">;
			return fitCheck(p.cwd) satisfies Result<"work.fitCheck">;
		},
		"work.job": async (params, _call) => {
			const p = params as Params<"work.job">;
			return (await engine.work.jobCost(p.project, p.conversationId)) satisfies Result<"work.job">;
		},
		"work.addTask": async (params, _call) => {
			const p = params as Params<"work.addTask">;
			const task = await engine.work.createTask(p.project, { title: p.title, brief: p.brief, ...(p.done ? { done: p.done } : {}) }, "you");
			return { task } satisfies Result<"work.addTask">;
		},
		"work.updateTask": async (params, _call) => {
			const p = params as Params<"work.updateTask">;
			await engine.work.updateTask(p.project, p.taskId, { ...(p.state ? { state: p.state } : {}), ...(p.title ? { title: p.title } : {}), ...(p.brief ? { brief: p.brief } : {}) });
			return {} satisfies Result<"work.updateTask">;
		},
		"work.landing": async (params, _call) => {
			const p = params as Params<"work.landing">;
			return (await engine.work.landing(p.project)) satisfies Result<"work.landing">;
		},
		"work.land": async (params, _call) => {
			const p = params as Params<"work.land">;
			return (await engine.work.land(p.project, p.action)) satisfies Result<"work.land">;
		},
		"work.createPR": async (params, _call) => {
			const p = params as Params<"work.createPR">;
			const work = engine.work.get(engine.projects.get(p.project).id);
			if (!work.git) throw new EngineError("INVALID", "This project's work isn't on a branch.");
			const pr = await engine.github.createPullRequest(work.cwd, { head: work.git.branch, base: work.git.base, title: p.title, body: p.body, ...(p.draft ? { draft: true } : {}) });
			return { pr: await engine.github.pullRequest(pr.repo, pr.number) } satisfies Result<"work.createPR">;
		},
		"work.migrationReport": async (_params, _call) => {
			const file = join(engine.options.paths.home, REPORT_FILE);
			return (existsSync(file) ? { report: readFileSync(file, "utf8").trim() } : {}) satisfies Result<"work.migrationReport">;
		},
		"work.dismissMigrationReport": async (_params, _call) => {
			const file = join(engine.options.paths.home, REPORT_FILE);
			if (existsSync(file)) renameSync(file, join(engine.options.paths.home, `${REPORT_FILE.replace(/\.md$/, "")}.seen.md`));
			return {} satisfies Result<"work.dismissMigrationReport">;
		},
	};
}

/** A project's work as the app sees it. */
function workView(engine: Engine, work: ProjectWork) {
	return { project: work.project, cwd: work.cwd, way: work.way, ...(work.git ? { git: work.git } : {}), tasks: work.tasks, createdAt: work.createdAt };
}
