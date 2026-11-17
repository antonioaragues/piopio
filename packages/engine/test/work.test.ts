import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// A project's work (docs/spec/26): every conversation there is with Piopio; with parallel work on, it puts tasks on
// the board and helpers do them, reviewed and merged by the way of working.

type Task = { id: string; title: string; state: string; helper: string; by: string; branch?: string; sessionId?: string; reviewSessionId?: string; conversationId?: string; attempts: number; blocked?: string; report?: string; landed?: string };
type Work = { project: string; cwd: string; way: { parallel: boolean; review: boolean; reviewLimit: number; testCommand?: string; maxParallel: number; buildModel?: string; reviewModel?: string; playbook: string }; git?: { base: string; branch: string; integration: string }; tasks: Task[] };

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

async function start(home = mkdtempSync(join(tmpdir(), "piopio-work-"))) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, watchers: { settleMs: 200 }, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return { home, client };
}

const git = (dir: string, ...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } }).toString();

function repo(): string {
	const dir = mkdtempSync(join(tmpdir(), "piopio-work-repo-"));
	git(dir, "init", "-q", "-b", "main");
	writeFileSync(join(dir, "README.md"), "# App\n");
	writeFileSync(join(dir, "package.json"), "{}");
	git(dir, "add", "-A");
	git(dir, "commit", "-qm", "init");
	return dir;
}

/** A folder made a project, with parallel work on and these settings. */
async function parallel(client: TestClient, dir: string, settings: Record<string, unknown> = {}): Promise<Work> {
	const { project } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	return ((await client.call("work.configure", { project: project.id, parallel: true, ...settings })) as { work: Work }).work;
}

const workOf = async (client: TestClient, project: string) => ((await client.call("work.get", { project })) as { work: Work }).work;
const textOf = async (client: TestClient, id: string) => JSON.stringify((await client.call("sessions.open", { ref: { kind: "build", id } })).items);
const conversation = async (client: TestClient, cwd: string) => ((await client.call("sessions.create", { kind: "build", cwd })) as { ref: { kind: string; id: string } }).ref;
const createTask = (args: object) => `call: create_task | ${JSON.stringify(args)}`;

/** A brief the scripted model acts on: the builder writes, the reviewer gives its verdict. */
const brief = (file: string, pass: boolean) => `write: ${file} | hello from ${file}\ncall: verdict | ${JSON.stringify({ pass, notes: pass ? "Looks right." : "The greeting is wrong." })}`;

test("parallel work in a git project: Piopio's tasks run on their own branches, are reviewed, merged and checked, and it's told to look before saying done (docs/spec/26 CL3)", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir, { testCommand: "test -f a.txt", maxParallel: 2 });
	expect(work.way).toMatchObject({ parallel: true, review: true, reviewLimit: 3, playbook: "development" });
	expect(work.git).toMatchObject({ base: "main", branch: expect.stringMatching(/^work\//) });
	// Every conversation in the project is with Piopio; it has the board's tools now.
	const piopio = await conversation(client, work.cwd);
	await client.call("sessions.submit", { ref: piopio, input: { text: `${createTask({ title: "Greeting A", brief: brief("a.txt", true) })}\n${createTask({ title: "Greeting B", brief: brief("b.txt", true) })}` } });
	const done = await until(() => workOf(client, work.project), (w) => w.tasks.length === 2 && w.tasks.every((x) => x.state === "done"), 40_000);
	expect(done.tasks.map((t) => [t.id, t.helper, t.by, t.attempts, t.conversationId])).toEqual([["T1", "Builder", "piopio", 0, piopio.id], ["T2", "Builder", "piopio", 0, piopio.id]]);
	expect(done.tasks.every((t) => t.reviewSessionId && t.report)).toBe(true);
	// Both merged into the work branch, which the checks ran on; main is untouched.
	const log = git(dir, "log", "--format=%s", work.git!.branch);
	expect(log).toContain("Merge T1: Greeting A");
	expect(log).toContain("Merge T2: Greeting B");
	expect(readFileSync(join(work.git!.integration, "a.txt"), "utf8")).toContain("hello from a.txt");
	expect(existsSync(join(dir, "a.txt"))).toBe(false);
	// Piopio heard about each one, with the reviewer's word, and is told to check the diff (docs/spec/26 §7.2).
	const said = await until(() => textOf(client, piopio.id), (s) => s.includes("“Greeting B” is done"));
	expect(said).toContain("[Board] T1 “Greeting A” is done. Merged into work/");
	expect(said).toContain("checks passed");
	expect(said).toContain("QA approved it:");
	expect(said).toContain("Before you say it's done, look at what changed");
	// Helpers are marked as such, and aren't asked for your agents or offers.
	const sessions = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; helper?: { kind: string; taskId: string; project: string } }[];
	expect(sessions.find((s) => s.ref.id === done.tasks[0]!.sessionId)?.helper).toEqual({ project: work.project, kind: "build", taskId: "T1" });
	expect(sessions.find((s) => s.ref.id === done.tasks[0]!.reviewSessionId)?.helper).toEqual({ project: work.project, kind: "review", taskId: "T1" });
	expect(sessions.find((s) => s.ref.id === piopio.id)?.helper).toBeUndefined();
}, 60_000);

test("a failing review sends a task back; past the way of working's limit it's blocked and Piopio hears why", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir, { reviewLimit: 2 });
	const piopio = await conversation(client, work.cwd);
	await client.call("sessions.submit", { ref: piopio, input: { text: createTask({ title: "Never right", brief: brief("c.txt", false) }) } });
	const blocked = await until(() => workOf(client, work.project), (w) => w.tasks[0]?.state === "blocked", 60_000);
	expect(blocked.tasks[0]).toMatchObject({ attempts: 2, blocked: expect.stringContaining("Sent back 2 times by review") });
	const said = await until(() => textOf(client, piopio.id), (s) => s.includes("is blocked"));
	expect(said).toContain("went back to its Builder (review, round 1)");
	expect(said).toContain("is blocked: Sent back 2 times");
}, 90_000);

test("without git, helpers share the folder; with review off a task is done when its helper finishes; you add and move cards", async () => {
	const { client } = await start();
	const created = (await client.call("projects.create", { name: "Market" })) as { project: { id: string; path: string } };
	const dir = created.project.path;
	// No parallel work yet: the project has no board.
	expect(((await client.call("work.get", { project: created.project.id })) as { work?: Work }).work).toBeUndefined();
	const work = ((await client.call("work.configure", { project: created.project.id, parallel: true, review: false, playbook: "research" })) as { work: Work }).work;
	expect(work.git).toBeUndefined();
	await client.call("work.addTask", { project: work.project, title: "Competitors", brief: "write: notes/T1.md | - Acme sells X" });
	const done = await until(() => workOf(client, work.project), (w) => w.tasks[0]?.state === "done");
	expect(done.tasks[0]).toMatchObject({ helper: "Researcher", by: "you" });
	expect(done.tasks[0]!.reviewSessionId).toBeUndefined();
	expect(readFileSync(join(dir, "notes", "T1.md"), "utf8")).toContain("Acme sells X");
	await client.call("work.updateTask", { project: work.project, taskId: "T1", state: "blocked" });
	expect((await workOf(client, work.project)).tasks[0]).toMatchObject({ state: "blocked", blocked: "Stopped by you" });
	// The helper was told the playbook's part.
	expect(await textOf(client, done.tasks[0]!.sessionId!)).toContain("You're a Researcher: a helper Piopio made for one task in this project.");
	// A playbook that isn't there is refused.
	await expect(client.call("work.configure", { project: work.project, playbook: "nope" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	expect(((await client.call("work.playbooks", { project: work.project })) as { playbooks: { id: string }[] }).playbooks.map((p) => p.id)).toEqual(["development", "general", "research", "writing"]);
}, 40_000);

test("the helpers' models come from the way of working: a reviewer has its own, or the build model", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir, { buildModel: "faux:faux-1", reviewModel: "faux:qa-model" });
	await client.call("work.addTask", { project: work.project, title: "Sketch", brief: brief("sketch.txt", true) });
	const t = await until(() => workOf(client, work.project), (w) => !!w.tasks[0]?.reviewSessionId, 30_000).then((w) => w.tasks[0]!);
	const sessions = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; model?: { provider: string; id: string } }[];
	expect(sessions.find((s) => s.ref.id === t.sessionId)?.model).toEqual({ provider: "faux", id: "faux-1" });
	expect(sessions.find((s) => s.ref.id === t.reviewSessionId)?.model).toEqual({ provider: "faux", id: "qa-model" });
	// Clearing them, and changing the checks and pace.
	const updated = ((await client.call("work.configure", { project: work.project, buildModel: null, reviewModel: null, testCommand: "", maxParallel: 5 })) as { work: Work }).work;
	expect(updated.way).not.toHaveProperty("buildModel");
	expect(updated.way).not.toHaveProperty("testCommand");
	expect(updated.way.maxParallel).toBe(5);
}, 40_000);

test("switching parallel work off takes the board's tools from Piopio; it offers parallel work again instead", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir);
	const piopio = await conversation(client, work.cwd);
	await client.call("sessions.submit", { ref: piopio, input: { text: "call: list_tasks | {}" } });
	await until(() => textOf(client, piopio.id), (s) => s.includes("The board is empty."));
	await until(async () => ((await client.call("sessions.open", { ref: piopio })) as { state: { status: string } }).state.status, (st) => st === "idle");
	// The idle conversation opens again without the board's tools.
	await client.call("work.configure", { project: work.project, parallel: false });
	await client.call("sessions.submit", { ref: piopio, input: { text: createTask({ title: "Nope", brief: "x" }) } });
	const said = await until(() => textOf(client, piopio.id), (s) => /"tool":"create_task"[^]*"status":"error"/.test(s));
	expect(said).not.toContain("Parallel work is off");
	expect((await workOf(client, work.project)).tasks).toEqual([]);
	// The board stays; you can still add a card yourself.
	await client.call("work.addTask", { project: work.project, title: "By hand", brief: brief("h.txt", true) });
	expect((await workOf(client, work.project)).tasks[0]).toMatchObject({ by: "you" });
}, 40_000);

type Landing = { base: string; branch: string; ahead: number; behind: number; files: { path: string }[]; tasks: { id: string }[]; open: number; checkedOut?: string; remote?: string; compareUrl?: string };

/** A project with one finished task, made by a conversation with Piopio. */
async function finished(client: TestClient, dir: string, file: string) {
	const work = await parallel(client, dir);
	const piopio = await conversation(client, work.cwd);
	await client.call("sessions.submit", { ref: piopio, input: { text: createTask({ title: `Add ${file}`, brief: brief(file, true) }) } });
	await until(() => workOf(client, work.project), (w) => w.tasks[0]?.state === "done", 40_000);
	return { work, piopio };
}

test("when the board is clear Piopio hears it's ready; you merge the work branch into the project's from the app", async () => {
	const { client } = await start();
	const dir = repo();
	const { work, piopio } = await finished(client, dir, "a.txt");
	await until(() => textOf(client, piopio.id), (s) => s.includes("The board is clear"));

	const landing = (await client.call("work.landing", { project: work.project })) as Landing;
	expect(landing).toMatchObject({ base: "main", branch: work.git!.branch, behind: 0, open: 0, checkedOut: "main", tasks: [{ id: "T1" }], files: [{ path: "a.txt" }] });
	expect(landing.ahead).toBeGreaterThan(0);

	const { commit } = (await client.call("work.land", { project: work.project, action: "merge" })) as { commit: string };
	expect(commit).toMatch(/^[0-9a-f]+$/);
	expect(readFileSync(join(dir, "a.txt"), "utf8")).toContain("hello from a.txt");
	expect(git(dir, "log", "-1", "--format=%s", "main")).toContain("Merge T1 Add a.txt");
	expect(git(dir, "branch", "--list", `${work.git!.branch}-t1`).trim()).toBe("");
	expect((await client.call("work.landing", { project: work.project })) as Landing).toMatchObject({ ahead: 0, behind: 0, tasks: [] });
	expect((await workOf(client, work.project)).tasks[0]!.landed).toBeTruthy();
	await expect(client.call("work.land", { project: work.project, action: "merge" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	await until(() => textOf(client, piopio.id), (s) => s.includes("The user merged"));
}, 60_000);

test("a merge that conflicts changes nothing; with the project on another branch it merges aside; push sends the work branch", async () => {
	const { client } = await start();
	const dir = repo();
	const { work } = await finished(client, dir, "a.txt");
	writeFileSync(join(dir, "a.txt"), "mine\n");
	git(dir, "add", "-A");
	git(dir, "commit", "-qm", "mine");
	git(dir, "checkout", "-q", "-b", "other");
	const before = git(dir, "rev-parse", "main");
	expect((await client.call("work.landing", { project: work.project })) as Landing).toMatchObject({ behind: 1, checkedOut: "other" });
	await expect(client.call("work.land", { project: work.project, action: "merge" })).rejects.toMatchObject({ data: { code: "CONFLICT" } });
	expect(git(dir, "rev-parse", "main")).toBe(before);
	expect(git(dir, "worktree", "list")).not.toContain("_land");

	git(dir, "checkout", "-q", "main");
	git(dir, "reset", "-q", "--hard", "HEAD~1");
	git(dir, "checkout", "-q", "other");
	await client.call("work.land", { project: work.project, action: "merge" });
	expect(git(dir, "show", "main:a.txt")).toContain("hello from a.txt");
	expect(git(dir, "branch", "--show-current").trim()).toBe("other");

	const remote = mkdtempSync(join(tmpdir(), "piopio-work-remote-"));
	git(remote, "init", "-q", "--bare");
	git(dir, "remote", "add", "origin", remote);
	await client.call("work.addTask", { project: work.project, title: "Add b", brief: brief("b.txt", true) });
	await until(() => workOf(client, work.project), (w) => w.tasks[1]?.state === "done", 40_000);
	await client.call("work.land", { project: work.project, action: "push" });
	expect(git(remote, "branch", "--list", work.git!.branch)).toContain(work.git!.branch);
	git(dir, "remote", "set-url", "origin", "git@github.com:acme/shop.git");
	expect(((await client.call("work.landing", { project: work.project })) as Landing).compareUrl).toBe(`https://github.com/acme/shop/compare/main...${work.git!.branch}?expand=1`);
}, 90_000);

test("two conversations plan their own tasks on one board, and each hears only its own (docs/spec/20 PT6)", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir);
	const a = await conversation(client, work.cwd);
	const b = await conversation(client, work.cwd);
	await client.call("sessions.submit", { ref: a, input: { text: createTask({ title: "From A", brief: brief("a.txt", true) }) } });
	await client.call("sessions.submit", { ref: b, input: { text: createTask({ title: "From B", brief: brief("b.txt", true) }) } });
	const tasks = await until(() => workOf(client, work.project).then((w) => w.tasks), (t) => t.length === 2 && t.every((x) => x.state === "done"), 60_000);
	expect(Object.fromEntries(tasks.map((t) => [t.title, t.conversationId]))).toEqual({ "From A": a.id, "From B": b.id });
	const textA = await until(() => textOf(client, a.id), (s) => s.includes("“From A” is done"));
	const textB = await until(() => textOf(client, b.id), (s) => s.includes("“From B” is done"));
	expect(textA).not.toContain("“From B” is done");
	expect(textB).not.toContain("“From A” is done");
	await client.call("sessions.submit", { ref: a, input: { text: "call: list_tasks | {}" } });
	await until(() => textOf(client, a.id), (s) => /T\d \[done\] From A \(Builder, yours\)/.test(s) && /T\d \[done\] From B \(Builder\)/.test(s));
}, 90_000);

test("a task starts from the project as it is: the work branch catches up with commits on the base", async () => {
	const { client } = await start();
	const dir = repo();
	const work = await parallel(client, dir);
	writeFileSync(join(dir, "about.html"), "<p>About</p>\n");
	git(dir, "add", "-A");
	git(dir, "commit", "-qm", "About page");
	await client.call("work.addTask", { project: work.project, title: "Contact", brief: brief("contact.html", true) });
	await until(() => workOf(client, work.project), (w) => w.tasks[0]?.state === "done", 40_000);
	expect(existsSync(join(work.git!.integration, "about.html"))).toBe(true);
	expect(existsSync(join(work.git!.integration, "contact.html"))).toBe(true);
}, 60_000);

type Routine = { id: string; on: string; by: string; label: string; url?: string; next?: number; runs: number };

test("routines start a project's work on their own: Piopio sets them, a file or a webhook opens a conversation with it, you run or remove them", async () => {
	const { client } = await start();
	const inbox = mkdtempSync(join(tmpdir(), "piopio-work-inbox-"));
	const created = (await client.call("projects.create", { name: "Market" })) as { project: { id: string; path: string } };
	const project = created.project.id;
	await client.call("work.configure", { project, parallel: true });
	const piopio = await conversation(client, created.project.path);
	await client.call("sessions.submit", { ref: piopio, input: { text: `call: schedule | ${JSON.stringify({ when: "0 9 * * 1", prompt: "Write this week's brief" })}\ncall: watch | ${JSON.stringify({ on: "folder", folder: inbox, prompt: "Summarize the new report" })}` } });
	const list = async () => ((await client.call("routines.list", { project })) as { routines: Routine[] }).routines;
	const set = await until(list, (r) => r.length === 2);
	expect(set.map((r) => [r.on, r.by, r.label])).toEqual([["time", "piopio", "Every Monday at 09:00"], ["folder", "piopio", `When a file appears or changes in ${inbox}`]]);

	// A file appears: a new conversation with Piopio in the project gets it, with the path.
	const runs = async () => {
		const all = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; cwd?: string }[];
		return (await Promise.all(all.filter((s) => s.cwd === created.project.path && s.ref.id !== piopio.id).map((s) => textOf(client, s.ref.id)))).join("\n");
	};
	await new Promise((r) => setTimeout(r, 300));
	writeFileSync(join(inbox, "q3.pdf"), "report");
	await until(runs, (s) => s.includes("[Routine] When a file appears or changes in") && s.includes("q3.pdf"));

	const { routine } = (await client.call("routines.add", { project, on: "webhook", prompt: "Look into the new lead" })) as { routine: Routine };
	expect(routine).toMatchObject({ by: "you", url: expect.stringMatching(/^http:\/\/127\.0\.0\.1:\d+\/hooks\/prj_/) });
	for (let i = 0; i < 2; i++) expect((await fetch(routine.url!, { method: "POST", headers: { "Idempotency-Key": "d1" }, body: '{"name":"Acme"}' })).status).toBe(202);
	await until(runs, (s) => s.includes("[Routine] When its URL is called") && s.includes("Acme"));
	expect((await list()).find((r) => r.id === routine.id)).toMatchObject({ runs: 1 });

	const { runId } = (await client.call("routines.run", { project, routineId: set[0]!.id })) as { runId: string };
	await until(() => textOf(client, runId), (s) => s.includes("[Routine] Every Monday at 09:00: Write this week's brief"));
	await client.call("routines.remove", { project, routineId: set[1]!.id });
	expect((await list()).map((r) => r.on)).toEqual(["time", "webhook"]);
}, 60_000);

test("a time routine missed while the engine was off runs once when it's back", async () => {
	const first = await start();
	const created = (await first.client.call("projects.create", { name: "Weekly" })) as { project: { id: string; path: string } };
	const project = created.project.id;
	await first.client.call("routines.add", { project, on: "time", when: "0 9 * * 1", prompt: "Write the weekly brief" });
	const o = open.splice(0)[0]!;
	o.client.close();
	await o.engine.stop();
	const file = join(first.home, "project-routines.json");
	const places = JSON.parse(readFileSync(file, "utf8")) as { routines: { next: number }[] }[];
	places[0]!.routines[0]!.next = Date.now() - 60_000;
	writeFileSync(file, JSON.stringify(places));
	const { client } = await start(first.home);
	const ran = await until(async () => ((await client.call("routines.list", { project })) as { routines: (Routine & { lastConversation?: string })[] }).routines[0]!, (r) => r.runs === 1);
	expect(ran.next).toBeGreaterThan(Date.now());
	await until(() => textOf(client, ran.lastConversation!), (s) => s.includes("[Routine] Every Monday at 09:00: Write the weekly brief"));
}, 40_000);
