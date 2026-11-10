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

async function start(home = mkdtempSync(join(tmpdir(), "piopio-teams-"))) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, watchers: { settleMs: 200 }, log: () => {} });
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

/** A new conversation in the team's project: with its lead (docs/spec/20 PT4). */
async function conversation(client: TestClient, team: { id: string; cwd?: string; folder: string }) {
	const t = ((await client.call("teams.get", { id: team.id })) as { team: { cwd: string } }).team;
	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: t.cwd, team: team.id })) as { ref: { kind: string; id: string } };
	return ref;
}

/** A brief the scripted model acts on: the builder writes, the reviewer gives its verdict. */
const brief = (file: string, pass: boolean) => `write: ${file} | hello from ${file}\ncall: verdict | ${JSON.stringify({ pass, notes: pass ? "Looks right." : "The greeting is wrong." })}`;

test("a development team: the lead's tasks run in parallel on their own branches, QA approves, CI merges and runs the checks (docs/spec/19)", async () => {
	const { client } = await start();
	const dir = repo();
	const { team } = (await client.call("teams.create", { name: "Dev", template: "development", cwd: dir, testCommand: "test -f a.txt", maxParallel: 2 })) as { team: Team };
	expect(team.git).toMatchObject({ base: "main", branch: expect.stringMatching(/^team\/dev-/) });
	expect(existsSync(join(team.folder, "NOTES.md"))).toBe(true);
	// A conversation in the project with the team is a conversation with its lead (docs/spec/20 PT4); it may edit (PT5).
	const lead = await conversation(client, team);
	const sessions = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; team?: { kind: string }; approvalMode?: string }[];
	expect(sessions.find((s) => s.ref.id === lead.id)).toMatchObject({ team: { kind: "lead" }, approvalMode: expect.not.stringMatching(/read_only/) });

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
	const { team } = (await client.call("teams.create", { name: "Strict", template: "development", cwd: dir, goal: "Wait for tasks." })) as { team: Team };
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

test("a research team works in a project of its own, without git; you can move a card back to To do", async () => {
	const { client } = await start();
	const { team } = (await client.call("teams.create", { name: "Market", template: "research" })) as { team: Team & { cwd: string } };
	expect(team.git).toBeUndefined();
	// Every team works in a project (docs/spec/20 PT2): without a folder, it gets a new one named after it.
	const projects = ((await client.call("projects.list", {})) as { projects: { path: string; name: string }[] }).projects;
	expect(projects.find((p) => p.path === team.cwd)).toMatchObject({ name: "Market" });
	await client.call("teams.addTask", { id: team.id, title: "Competitors", brief: "write: notes/T1.md | - Acme sells X", role: "researcher" });
	const done = await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team, (t) => t.tasks[0]?.state === "done");
	expect(readFileSync(join(team.cwd, "notes", "T1.md"), "utf8")).toContain("Acme sells X");
	await expect(client.call("teams.addTask", { id: team.id, title: "Nope", brief: "x", role: "lead" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	await client.call("teams.updateTask", { id: team.id, taskId: "T1", state: "blocked" });
	expect(((await client.call("teams.get", { id: team.id })) as { team: Team }).team.tasks[0]).toMatchObject({ state: "blocked", blocked: "Stopped by you" });
}, 40_000);

test("a team for a new project: its folder becomes a git repo, and the team works on its own branch", async () => {
	const { client } = await start();
	const project = (await client.call("projects.create", { name: "Shop" })) as { project?: { path: string }; path?: string };
	const path = project.project?.path ?? project.path!;
	expect(existsSync(join(path, ".git"))).toBe(false);
	const { team } = (await client.call("teams.create", { name: "Shop team", template: "development", cwd: path, initGit: true })) as { team: Team };
	expect(existsSync(join(path, ".git"))).toBe(true);
	expect(team.git).toMatchObject({ base: "main", branch: expect.stringMatching(/^team\/shop-team-/) });
	// The project's own files are in the first commit (AGENTS.md, NOTES.md).
	expect(execFileSync("git", ["log", "--format=%s", "main"], { cwd: path }).toString().trim()).toBe("Start");
	expect(execFileSync("git", ["ls-files"], { cwd: path }).toString()).toContain("AGENTS.md");
}, 30_000);

type Landing = { base: string; branch: string; ahead: number; behind: number; files: { path: string }[]; tasks: { id: string }[]; open: number; checkedOut?: string; remote?: string; compareUrl?: string };
const git = (dir: string, ...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } }).toString();

async function finished(client: TestClient, dir: string, file: string) {
	const { team } = (await client.call("teams.create", { name: "Ship", template: "development", cwd: dir, goal: "Ship what's on the board." })) as { team: Team };
	await client.call("teams.addTask", { id: team.id, title: `Add ${file}`, brief: brief(file, true) });
	await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team, (t) => t.tasks[0]?.state === "done", 40_000);
	return team;
}

test("when the board is clear the lead hears it's ready; you merge the team's branch into the project's from the app", async () => {
	const { client } = await start();
	const dir = repo();
	const team = await finished(client, dir, "a.txt");
	const lead = { kind: "build", id: team.leadSessionId };
	await until(async () => JSON.stringify((await client.call("sessions.open", { ref: lead })).items), (s) => s.includes("The board is clear"));

	const landing = (await client.call("teams.landing", { id: team.id })) as Landing;
	expect(landing).toMatchObject({ base: "main", branch: team.git!.branch, behind: 0, open: 0, checkedOut: "main", tasks: [{ id: "T1" }], files: [{ path: "a.txt" }] });
	expect(landing.ahead).toBeGreaterThan(0);
	expect(landing.remote).toBeUndefined();

	const { commit } = (await client.call("teams.land", { id: team.id, action: "merge" })) as { commit: string };
	expect(commit).toMatch(/^[0-9a-f]+$/);
	expect(readFileSync(join(dir, "a.txt"), "utf8")).toContain("hello from a.txt");
	expect(git(dir, "log", "-1", "--format=%s", "main")).toContain("Merge Ship: T1 Add a.txt");
	// The task's branch is gone; the team's branch moved up to the merge.
	expect(git(dir, "branch", "--list", `${team.git!.branch}-t1`).trim()).toBe("");
	expect(((await client.call("teams.landing", { id: team.id })) as Landing)).toMatchObject({ ahead: 0, behind: 0, tasks: [] });
	expect(((await client.call("teams.get", { id: team.id })) as { team: Team & { tasks: (Task & { landed?: string })[] } }).team.tasks[0]!.landed).toBeTruthy();
	await expect(client.call("teams.land", { id: team.id, action: "merge" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	await until(async () => JSON.stringify((await client.call("sessions.open", { ref: lead })).items), (s) => s.includes("The user merged"));
}, 60_000);

test("a merge that conflicts changes nothing; with the project on another branch it merges aside; push sends the team's branch", async () => {
	const { client } = await start();
	const dir = repo();
	const team = await finished(client, dir, "a.txt");
	// Someone changed a.txt on main meanwhile, and the project's folder is now on another branch.
	writeFileSync(join(dir, "a.txt"), "mine\n");
	git(dir, "add", "-A");
	git(dir, "commit", "-qm", "mine");
	git(dir, "checkout", "-q", "-b", "other");
	const before = git(dir, "rev-parse", "main");
	const landing = (await client.call("teams.landing", { id: team.id })) as Landing;
	expect(landing).toMatchObject({ behind: 1, checkedOut: "other" });
	await expect(client.call("teams.land", { id: team.id, action: "merge" })).rejects.toMatchObject({ data: { code: "CONFLICT" } });
	expect(git(dir, "rev-parse", "main")).toBe(before);
	expect(git(dir, "worktree", "list")).not.toContain("_land");

	// Without the conflict it merges aside, leaving the folder on its branch.
	git(dir, "checkout", "-q", "main");
	git(dir, "reset", "-q", "--hard", "HEAD~1");
	git(dir, "checkout", "-q", "other");
	await client.call("teams.land", { id: team.id, action: "merge" });
	expect(git(dir, "show", "main:a.txt")).toContain("hello from a.txt");
	expect(git(dir, "branch", "--show-current").trim()).toBe("other");

	// Push: a second task, then the team's branch goes to the remote; a GitHub remote gives the PR page.
	const remote = mkdtempSync(join(tmpdir(), "piopio-team-remote-"));
	git(remote, "init", "-q", "--bare");
	git(dir, "remote", "add", "origin", remote);
	await client.call("teams.addTask", { id: team.id, title: "Add b", brief: brief("b.txt", true) });
	await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: Team }).team, (t) => t.tasks[1]?.state === "done", 40_000);
	await client.call("teams.land", { id: team.id, action: "push" });
	expect(git(remote, "branch", "--list", team.git!.branch)).toContain(team.git!.branch);
	git(dir, "remote", "set-url", "origin", "git@github.com:acme/shop.git");
	expect(((await client.call("teams.landing", { id: team.id })) as Landing).compareUrl).toBe(`https://github.com/acme/shop/compare/main...${team.git!.branch}?expand=1`);
}, 90_000);

type Routine = { id: string; on: string; by: string; label: string; url?: string; next?: number; runs: number; lastRun?: string };
const leadText = async (client: TestClient, id: string) => JSON.stringify((await client.call("sessions.open", { ref: { kind: "build", id } })).items);
/** Every lead conversation of a team, as one text. */
async function teamText(client: TestClient, teamId: string): Promise<string> {
	const sessions = ((await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; team?: { id: string; kind: string } }[]).filter((s) => s.team?.id === teamId && s.team.kind === "lead");
	return (await Promise.all(sessions.map((s) => leadText(client, s.ref.id)))).join("\n");
}

test("routines start a team's work on their own: the lead sets them, a file or a webhook wakes it, you run or remove them (docs/spec/19 T1)", async () => {
	const { client } = await start();
	const inbox = mkdtempSync(join(tmpdir(), "piopio-team-inbox-"));
	// The lead sets two routines when asked.
	const { team } = (await client.call("teams.create", { name: "Market", template: "research", goal: `call: schedule | ${JSON.stringify({ when: "0 9 * * 1", prompt: "Write this week's brief" })}\ncall: watch | ${JSON.stringify({ on: "folder", folder: inbox, prompt: "Summarize the new report" })}` })) as { team: Team };
	const set = await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: { routines?: Routine[] } }).team.routines ?? [], (r) => r.length === 2);
	expect(set.map((r) => [r.on, r.by, r.label])).toEqual([["time", "lead", "Every Monday at 09:00"], ["folder", "lead", `When a file appears or changes in ${inbox}`]]);
	expect(set[0]!.next).toBeGreaterThan(Date.now());

	// A file appears: the lead hears it, with the path.
	await new Promise((r) => setTimeout(r, 300));
	writeFileSync(join(inbox, "q3.pdf"), "report");
	// It starts a new conversation with the lead in the project (docs/spec/20 §4).
	await until(() => teamText(client, team.id), (s) => s.includes("[Routine] When a file appears or changes in") && s.includes("q3.pdf"));

	// You add a webhook routine; its URL wakes the lead once per delivery.
	const { routine } = (await client.call("teams.addRoutine", { id: team.id, on: "webhook", prompt: "Look into the new lead" })) as { routine: Routine };
	expect(routine.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/hooks\/team_/);
	for (let i = 0; i < 2; i++) expect((await fetch(routine.url!, { method: "POST", headers: { "Idempotency-Key": "d1" }, body: '{"name":"Acme"}' })).status).toBe(202);
	await until(() => teamText(client, team.id), (s) => s.includes("[Routine] When its URL is called") && s.includes("Acme"));
	// The same delivery twice ran once.
	expect((((await client.call("teams.get", { id: team.id })) as { team: { routines: Routine[] } }).team.routines).find((r) => r.id === routine.id)).toMatchObject({ runs: 1 });

	// Run now, then remove; a bad time is refused.
	const { runId } = (await client.call("teams.runRoutine", { id: team.id, routineId: set[0]!.id })) as { runId: string };
	expect(runId).toMatch(/^ses/);
	await until(() => leadText(client, runId), (s) => s.includes("[Routine] Every Monday at 09:00: Write this week's brief"));
	await client.call("teams.removeRoutine", { id: team.id, routineId: set[1]!.id });
	expect((((await client.call("teams.get", { id: team.id })) as { team: { routines: Routine[] } }).team.routines).map((r) => r.on)).toEqual(["time", "webhook"]);
	await expect(client.call("teams.addRoutine", { id: team.id, on: "time", when: "2020-01-01T09:00", prompt: "x" })).rejects.toMatchObject({ data: { code: "INVALID" } });
}, 60_000);

test("a time routine missed while the engine was off runs once when it's back", async () => {
	const first = await start();
	const { team } = (await first.client.call("teams.create", { name: "Weekly", template: "research" })) as { team: Team };
	await first.client.call("teams.addRoutine", { id: team.id, on: "time", when: "0 9 * * 1", prompt: "Write the weekly brief" });
	const o = open.splice(0)[0]!;
	o.client.close();
	await o.engine.stop();
	// The Mac slept through Monday 9:00.
	const file = join(first.home, "teams.json");
	const teams = JSON.parse(readFileSync(file, "utf8")) as { routines: { next: number }[] }[];
	teams[0]!.routines[0]!.next = Date.now() - 60_000;
	writeFileSync(file, JSON.stringify(teams));
	const { client } = await start(first.home);
	await until(() => teamText(client, team.id), (s) => s.includes("[Routine] Every Monday at 09:00: Write the weekly brief"));
	const after = ((await client.call("teams.get", { id: team.id })) as { team: { routines: Routine[] } }).team.routines[0]!;
	expect(after).toMatchObject({ runs: 1 });
	expect(after.next).toBeGreaterThan(Date.now());
}, 40_000);

test("a lead per conversation: two conversations plan their own tasks on one board, and each hears only its own (docs/spec/20 P1)", async () => {
	const { client } = await start();
	const dir = repo();
	const { team } = (await client.call("teams.create", { name: "Pair", template: "development", cwd: dir })) as { team: Team };
	expect(team.leadSessionId).toBeUndefined();
	// One team per project (PT3).
	await expect(client.call("teams.create", { name: "Other", template: "development", cwd: dir })).rejects.toMatchObject({ data: { code: "INVALID" } });
	const a = await conversation(client, team);
	const b = await conversation(client, team);
	await client.call("sessions.submit", { ref: a, input: { text: `call: create_task | ${JSON.stringify({ title: "From A", brief: brief("a.txt", true) })}` } });
	await client.call("sessions.submit", { ref: b, input: { text: `call: create_task | ${JSON.stringify({ title: "From B", brief: brief("b.txt", true) })}` } });
	const tasks = await until(async () => ((await client.call("teams.get", { id: team.id })) as { team: Team & { tasks: (Task & { conversationId?: string })[] } }).team.tasks, (t) => t.length === 2 && t.every((x) => x.state === "done"), 60_000);
	expect(Object.fromEntries(tasks.map((t) => [t.title, t.conversationId]))).toEqual({ "From A": a.id, "From B": b.id });
	const textA = await until(() => leadText(client, a.id), (s) => s.includes("“From A” is done"));
	const textB = await until(() => leadText(client, b.id), (s) => s.includes("“From B” is done"));
	expect(textA).not.toContain("“From B” is done");
	expect(textB).not.toContain("“From A” is done");
	// The lead's board shows every task, and which are this conversation's.
	await client.call("sessions.submit", { ref: a, input: { text: "call: list_tasks | {}" } });
	await until(() => leadText(client, a.id), (s) => /T\d \[done\] From A \(builder, yours\)/.test(s) && /T\d \[done\] From B \(builder\)/.test(s));
}, 90_000);

test("the project's Settings change the team's checks and pace, and remove it: its lead conversations stay, as plain ones (docs/spec/20 P2)", async () => {
	const { client } = await start();
	const dir = repo();
	const { team } = (await client.call("teams.create", { name: "Solo", template: "development", cwd: dir, testCommand: "npm test" })) as { team: Team & { testCommand?: string; maxParallel: number } };
	const lead = await conversation(client, team);
	const updated = ((await client.call("teams.update", { id: team.id, testCommand: "", maxParallel: 5 })) as { team: { testCommand?: string; maxParallel: number } }).team;
	expect(updated.testCommand).toBeUndefined();
	expect(updated.maxParallel).toBe(5);
	await client.call("teams.remove", { id: team.id });
	expect(((await client.call("teams.list", {})) as { teams: unknown[] }).teams).toEqual([]);
	const s = ((await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; team?: unknown }[]).find((x) => x.ref.id === lead.id);
	expect(s).toBeDefined();
	expect(s!.team).toBeUndefined();
	// The branch stays; its worktree goes. The project can get a team again.
	expect(execFileSync("git", ["branch", "--list", team.git!.branch], { cwd: dir }).toString()).toContain(team.git!.branch);
	expect(existsSync(team.git!.integration)).toBe(false);
	await client.call("teams.create", { name: "Again", template: "development", cwd: dir });
}, 30_000);
