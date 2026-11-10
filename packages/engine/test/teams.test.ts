import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Task = { id: string; title: string; state: string; role: string; branch?: string; sessionId?: string; reviewSessionId?: string; attempts: number; blocked?: string; report?: string };
type Team = { id: string; name: string; git?: { base: string; branch: string; integration: string }; leadSessionId: string; tasks: Task[]; folder: string };

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 20_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1500)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

async function start() {
	const home = mkdtempSync(join(tmpdir(), "piopio-teams-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return { home, client };
}

function repo(): string {
	const dir = mkdtempSync(join(tmpdir(), "piopio-team-repo-"));
	const sh = (...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } });
	sh("init", "-q", "-b", "main");
	writeFileSync(join(dir, "README.md"), "# App\n");
	writeFileSync(join(dir, "package.json"), "{}");
	sh("add", "-A");
	sh("commit", "-qm", "init");
	return dir;
}

/** A brief the scripted model acts on: the builder writes, the reviewer gives its verdict. */
const brief = (file: string, pass: boolean) => `write: ${file} | hello from ${file}\ncall: verdict | ${JSON.stringify({ pass, notes: pass ? "Looks right." : "The greeting is wrong." })}`;

test("a development team: the lead's tasks run in parallel on their own branches, QA approves, CI merges and runs the checks (docs/spec/19)", async () => {
	const { client } = await start();
	const dir = repo();
	const { team } = (await client.call("teams.create", { name: "Dev", template: "development", cwd: dir, testCommand: "test -f a.txt", maxParallel: 2 })) as { team: Team };
	expect(team.git).toMatchObject({ base: "main", branch: expect.stringMatching(/^team\/dev-/) });
	expect(existsSync(join(team.folder, "NOTES.md"))).toBe(true);
	const lead = { kind: "build", id: team.leadSessionId };
	const sessions = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; team?: { kind: string }; approvalMode?: string }[];
	expect(sessions.find((s) => s.ref.id === team.leadSessionId)?.team).toMatchObject({ kind: "lead" });

	// The lead (Read only) puts two tasks on the board; both start at once, each in its own worktree.
	await client.call("sessions.submit", { ref: lead, input: { text: `call: create_task | ${JSON.stringify({ title: "Greeting A", brief: brief("a.txt", true), role: "builder" })}\ncall: create_task | ${JSON.stringify({ title: "Greeting B", brief: brief("b.txt", true) })}` } });
	const done = await until(
		async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team,
		(t) => t.tasks.length === 2 && t.tasks.every((x) => x.state === "done"),
		40_000,
	);
	expect(done.tasks.map((t) => [t.id, t.role, t.attempts])).toEqual([["T1", "builder", 0], ["T2", "builder", 0]]);
	expect(done.tasks.every((t) => t.reviewSessionId && t.report)).toBe(true);
	// Both merged into the team's branch, which the checks ran on; main is untouched.
	const log = execFileSync("git", ["log", "--format=%s", team.git!.branch], { cwd: dir }).toString();
	expect(log).toContain("Merge T1: Greeting A");
	expect(log).toContain("Merge T2: Greeting B");
	expect(readFileSync(join(team.git!.integration, "a.txt"), "utf8")).toContain("hello from a.txt");
	expect(existsSync(join(dir, "a.txt"))).toBe(false);
	// The lead heard about each one on the board.
	const leadItems = JSON.stringify((await client.call("sessions.open", { ref: lead })).items);
	expect(leadItems).toContain("[Board] T1 “Greeting A” is done. Merged into team/dev-");
	expect(leadItems).toContain("checks passed");
}, 60_000);

test("a failing review sends a task back; after three rounds it's blocked and the lead hears why", async () => {
	const { client } = await start();
	const dir = repo();
	const { team } = (await client.call("teams.create", { name: "Strict", template: "development", cwd: dir })) as { team: Team };
	await client.call("teams.addTask", { id: team.id, title: "Never right", brief: brief("c.txt", false) });
	const blocked = await until(
		async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team,
		(t) => t.tasks[0]?.state === "blocked",
		60_000,
	);
	expect(blocked.tasks[0]).toMatchObject({ attempts: 3, blocked: expect.stringContaining("Sent back 3 times by review") });
	const leadItems = JSON.stringify((await client.call("sessions.open", { ref: { kind: "build", id: team.leadSessionId } })).items);
	expect(leadItems).toContain("You were given a task on the board: T1");
	expect(leadItems).toContain("went back to its Builder (review, round 1)");
	expect(leadItems).toContain("is blocked: Sent back 3 times");
}, 90_000);

test("a research team works in its own folder, without git; you can move a card back to To do", async () => {
	const { client } = await start();
	const { team } = (await client.call("teams.create", { name: "Market", template: "research" })) as { team: Team };
	expect(team.git).toBeUndefined();
	await client.call("teams.addTask", { id: team.id, title: "Competitors", brief: "write: notes/T1.md | - Acme sells X", role: "researcher" });
	const done = await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team, (t) => t.tasks[0]?.state === "done");
	expect(readFileSync(join(done.folder, "notes", "T1.md"), "utf8")).toContain("Acme sells X");
	await expect(client.call("teams.addTask", { id: team.id, title: "Nope", brief: "x", role: "lead" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	await client.call("teams.updateTask", { id: team.id, taskId: "T1", state: "blocked" });
	expect(((await client.call("teams.get", { id: team.id })) as { team: Team }).team.tasks[0]).toMatchObject({ state: "blocked", blocked: "Stopped by you" });
}, 40_000);
