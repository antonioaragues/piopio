import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { TeamRunner, type TeamHost } from "../src/teams/runner.js";

/** A job that reached its budget starts nothing new (docs/spec/21 D1): a stand-in host where every session costs $1. */
test("a job stops at its budget: tasks wait, the lead is told why", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-budget-"));
	const said: string[] = [];
	let n = 0;
	const host: TeamHost = {
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
		project: (x) => ({ id: "prj_x", path: x }),
		worktreesDir: join(home, "worktrees"),
		stateFile: join(home, "teams.json"),
		changed: () => {},
		log: () => {},
	};
	const runner = new TeamRunner(host);
	const team = await runner.create({ name: "Thrifty", template: "research", folder: join(home, "Teams", "thrifty"), cwd: home, maxParallel: 1 });
	runner.updateDefinition(team.definitionId!, { budgetPerJob: 1.5 });
	// The first task runs (the job has cost nothing yet); its session now costs $1, under $1.50.
	const a = await runner.createTask(team.id, { title: "A", brief: "a" }, "lead", "ses_lead");
	expect(a.state).toBe("doing");
	// Two more wait for a slot; once A's slot frees, the job has cost $1 + its reviewer's $1: over budget.
	const b = await runner.createTask(team.id, { title: "B", brief: "b" }, "lead", "ses_lead");
	expect(b.state).toBe("todo");
	a.reviewSessionId = "ses_review";
	a.state = "done";
	await runner.updateTask(team.id, "T2", { title: "B" });
	expect(runner.get(team.id).tasks.find((t) => t.id === "T2")).toMatchObject({ state: "blocked", blocked: expect.stringContaining("This job reached its budget ($2.00 of $1.50)") });
	expect(said.some((s) => s.startsWith("ses_lead: [Board] T2 “B” is blocked: This job reached its budget"))).toBe(true);
	expect(await runner.jobCost(team.id, "ses_lead")).toMatchObject({ cost: 2, tasks: 2, budget: 1.5 });
	runner.stop();
});
