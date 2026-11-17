import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { WorkRunner, type WorkHost } from "../src/work/runner.js";

/** A job that reached its budget starts nothing new (docs/spec/21 D1): a stand-in host where every session costs $1. */
test("a job stops at its budget: tasks wait, Piopio is told why", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-budget-"));
	const said: string[] = [];
	let n = 0;
	const host: WorkHost = {
		createSession: async () => `ses_${++n}`,
		submit: async (id, text) => void said.push(`${id}: ${text}`),
		onSettled: async () => () => {},
		peek: async () => ({ idle: false, answer: "" }),
		git: async () => "",
		isRepo: async () => false,
		branchOf: async () => undefined,
		addWorktree: async () => {},
		removeWorktree: async () => {},
		run: async () => ({ ok: true, output: "" }),
		cost: async () => 1,
		project: () => ({ id: "prj_x", path: home }),
		worktreesDir: join(home, "worktrees"),
		stateFile: join(home, "work.json"),
		routinesFile: join(home, "project-routines.json"),
		changed: () => {},
		log: () => {},
	};
	const runner = new WorkRunner(host);
	await runner.configure("prj_x", { parallel: true, maxParallel: 1, budgetPerJob: 1.5 });
	// The first task runs (the job has cost nothing yet); its session now costs $1, under $1.50.
	const a = await runner.createTask("prj_x", { title: "A", brief: "a" }, "piopio", "ses_piopio");
	expect(a.state).toBe("doing");
	// Another waits for a slot; once A's slot frees, the job has cost $1 + its reviewer's $1: over budget.
	const b = await runner.createTask("prj_x", { title: "B", brief: "b" }, "piopio", "ses_piopio");
	expect(b.state).toBe("todo");
	a.reviewSessionId = "ses_review";
	a.state = "done";
	await runner.updateTask("prj_x", "T2", { title: "B" });
	expect(runner.get("prj_x").tasks.find((t) => t.id === "T2")).toMatchObject({ state: "blocked", blocked: expect.stringContaining("This job reached its budget ($2.00 of $1.50)") });
	expect(said.some((s) => s.startsWith("ses_piopio: [Board] T2 “B” is blocked: This job reached its budget"))).toBe(true);
	expect(await runner.jobCost("prj_x", "ses_piopio")).toMatchObject({ cost: 2, tasks: 2, budget: 1.5 });
	// Piopio can't put work on the board once parallel work is off.
	await runner.configure("prj_x", { parallel: false });
	await expect(runner.createTask("prj_x", { title: "C", brief: "c" }, "piopio", "ses_piopio")).rejects.toThrow(/Parallel work is off/);
	runner.stop();
});
