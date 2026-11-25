import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { addWorktree, git, removeWorktree, status } from "../src/git.js";
import { WorkRunner, type WorkHost } from "../src/work/runner.js";

// Re-audit 2026-11-25 §5.2: a task cut off while it was being merged ("integrating") was never picked up again, and the
// board waited on it for good. Now resume merges it again, from wherever the crash left it.

const ID = ["-c", "user.name=Test", "-c", "user.email=test@example.com"];

async function setup() {
	const home = mkdtempSync(join(tmpdir(), "piopio-work-resume-"));
	const repo = join(home, "repo");
	await git(home, ["init", "-q", "-b", "main", repo]);
	writeFileSync(join(repo, "README.md"), "hi\n");
	await git(repo, ["add", "-A"]);
	await git(repo, [...ID, "commit", "-q", "-m", "Start"]);
	const said: string[] = [];
	let n = 0;
	const host: WorkHost = {
		createSession: async () => `ses_${++n}`,
		submit: async (id, text) => void said.push(`${id}: ${text}`),
		onSettled: async () => () => {},
		peek: async () => ({ idle: false, answer: "" }),
		git: (cwd, args) => git(cwd, args[0] === "-c" ? args : [...ID, ...args]),
		isRepo: async (cwd) => (await status(cwd)).repo,
		branchOf: async (cwd) => (await status(cwd)).branch,
		addWorktree,
		removeWorktree,
		run: async () => ({ ok: true, output: "" }),
		project: () => ({ id: "prj_x", path: repo }),
		worktreesDir: join(home, "worktrees"),
		stateFile: join(home, "work.json"),
		changed: () => {},
		log: () => {},
	};
	const runner = new WorkRunner(host);
	await runner.configure("prj_x", { parallel: true, review: false });
	const t = await runner.createTask("prj_x", { title: "Add a file", brief: "b" }, "piopio", "ses_piopio");
	writeFileSync(join(t.cwd!, "added.txt"), "new\n");
	await git(t.cwd!, ["add", "-A"]);
	await git(t.cwd!, [...ID, "commit", "-q", "-m", "T1: Add a file"]);
	const work = runner.get("prj_x");
	/** The engine stops with the task mid-merge, and starts again. */
	const crash = async (at: (integration: string) => Promise<void>) => {
		t.state = "integrating";
		(runner as unknown as { save(w: unknown): void }).save(work);
		await at(work.git!.integration);
		runner.stop();
		const again = new WorkRunner(host);
		await again.resume();
		for (let i = 0; i < 100 && again.get("prj_x").tasks[0]!.state === "integrating"; i++) await new Promise((r) => setTimeout(r, 50));
		const merges = (await git(work.git!.integration, ["log", "--format=%s", "--merges"])).trim().split("\n").filter(Boolean);
		return { task: again.get("prj_x").tasks[0]!, merges, integration: work.git!.integration, again };
	};
	return { t, crash, said, repo };
}

test("cut off after the merge commit, before the checks: merged once, checked, done", async () => {
	const { t, crash } = await setup();
	const r = await crash(async (integration) => {
		await git(integration, [...ID, "merge", "--no-ff", "-q", "-m", `Merge ${t.id}: ${t.title}`, t.branch!]);
	});
	expect(r.task.state).toBe("done");
	expect(r.merges).toEqual(["Merge T1: Add a file"]);
	expect(existsSync(join(r.integration, "added.txt"))).toBe(true);
	expect(existsSync(t.cwd!)).toBe(false);
	r.again.stop();
});

test("cut off after its worktree went: done, with no second merge", async () => {
	const { t, crash, repo } = await setup();
	const r = await crash(async (integration) => {
		await git(integration, [...ID, "merge", "--no-ff", "-q", "-m", `Merge ${t.id}: ${t.title}`, t.branch!]);
		await removeWorktree(repo, t.cwd!, t.branch!, true);
	});
	expect(r.task.state).toBe("done");
	expect(r.merges).toEqual(["Merge T1: Add a file"]);
	r.again.stop();
});

test("cut off before the merge: merged now", async () => {
	const { crash } = await setup();
	const r = await crash(async () => {});
	expect(r.task.state).toBe("done");
	expect(r.merges).toEqual(["Merge T1: Add a file"]);
	r.again.stop();
});
