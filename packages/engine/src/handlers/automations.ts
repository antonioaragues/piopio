/**
 * The engine's `automations.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `automations.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { join } from "node:path";
import { existsSync, readFileSync, renameSync } from "node:fs";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { type Automation } from "../automations/model.js";
import { REPORT_FILE as AUTOMATIONS_REPORT } from "../automations/migrate.js";
import type { Automation as AutomationView } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function automationsHandlers(engine: Engine): Handlers<"automations"> {
	return {
		"automations.list": async (params, _call) => {
			const p = params as Params<"automations.list">;
			// Runs still going are read again first, so "Running now" doesn't outlast them.
			await engine.automations.runsOf(undefined, 200);
			const list = engine.automations.list().filter((a) => (!p.runsAs || a.runsAs === p.runsAs) && (!p.project || a.project === p.project));
			return { automations: list.map((a) => automationView(engine, a)) } satisfies Result<"automations.list">;
		},
		"automations.get": async (params, _call) => {
			const p = params as Params<"automations.get">;
			const a = engine.automations.get(p.id);
			engine.automations.opened(a.id);
			return { automation: automationView(engine, a), runs: await engine.automations.runsOf(a.id, 20), summary: engine.automations.summary(a) } satisfies Result<"automations.get">;
		},
		"automations.add": async (params, _call) => {
			const { id: _ignored, ...p } = params as Params<"automations.add"> & { id?: string };
			const a = engine.automations.add(p, "you");
			engine.automations.opened(a.id);
			return { automation: automationView(engine, a) } satisfies Result<"automations.add">;
		},
		"automations.update": async (params, _call) => {
			const { id, ...change } = params as Params<"automations.update">;
			return { automation: automationView(engine, engine.automations.update(id, change)) } satisfies Result<"automations.update">;
		},
		"automations.remove": async (params, _call) => {
			const p = params as Params<"automations.remove">;
			engine.automations.remove(p.id);
			return {} satisfies Result<"automations.remove">;
		},
		"automations.restore": async (params, _call) => {
			const p = params as Params<"automations.restore">;
			return { automation: automationView(engine, engine.automations.restoreRemoved(p.id)) } satisfies Result<"automations.restore">;
		},
		"automations.run": async (params, _call) => {
			const p = params as Params<"automations.run">;
			const run = await engine.automations.fire(p.id, "now", "Run now, by the user.");
			if (!run) throw new EngineError("INVALID", "It didn't run.");
			return { run } satisfies Result<"automations.run">;
		},
		"automations.runs": async (params, _call) => {
			const p = params as Params<"automations.runs">;
			return { runs: await engine.automations.runsOf(p.id, p.limit ?? 50) } satisfies Result<"automations.runs">;
		},
		"automations.migrationReport": async (_params, _call) => {
			const file = join(engine.options.paths.home, AUTOMATIONS_REPORT);
			return (existsSync(file) ? { report: readFileSync(file, "utf8").trim() } : {}) satisfies Result<"automations.migrationReport">;
		},
		"automations.dismissMigrationReport": async (_params, _call) => {
			const file = join(engine.options.paths.home, AUTOMATIONS_REPORT);
			if (existsSync(file)) renameSync(file, join(engine.options.paths.home, `${AUTOMATIONS_REPORT.replace(/\.md$/, "")}.seen.md`));
			return {} satisfies Result<"automations.dismissMigrationReport">;
		},
	};
}

function automationView(engine: Engine, a: Automation): AutomationView {
	const s = engine.automations.summary(a);
	const last = engine.automations.lastRun(a.id);
	return {
		...a,
		label: s.when,
		runnerName: s.runsAs,
		resultLabel: s.tellsYou,
		...(s.url ? { url: s.url } : {}),
		...(last ? { lastStatus: last.status, ...(last.summary ? { lastSummary: last.summary } : {}) } : {}),
	};
}
