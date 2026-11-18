import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Teams become projects' ways of working (docs/spec/26 §8): once, with nothing lost and nothing deleted.

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function start(home: string) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return client;
}

async function stop() {
	const o = open.splice(0)[0]!;
	o.client.close();
	await o.engine.stop();
}

const role = (id: string, name: string, kind: string, responsibility: string, extra: object = {}) => ({ id, name, kind, responsibility, ...extra });

test("teams become ways of working: boards, branches, tasks and routines stay; notes and custom members are kept; lead conversations are Piopio's", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-migrate-"));
	const app = realpathSync(mkdtempSync(join(tmpdir(), "piopio-migrate-app-")));
	const blog = realpathSync(mkdtempSync(join(tmpdir(), "piopio-migrate-blog-")));
	const sh = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } }).toString();
	sh(app, "init", "-q", "-b", "main");
	writeFileSync(join(app, "README.md"), "# App\n");
	sh(app, "add", "-A");
	sh(app, "commit", "-qm", "init");
	writeFileSync(join(app, "NOTES.md"), "# Notes\n\nUse pnpm.\n");
	// The team's branch, in its worktree, as 19 T2 made them.
	const integration = join(home, "worktrees", "teams", "team_app", "_team");
	sh(app, "worktree", "add", "-q", "-b", "team/dev-1234", integration, "main");

	// Before 26: the engine knew both folders as projects, a lead conversation in each and a member's session.
	let client = await start(home);
	const appProject = (await client.call("projects.add", { path: app })).project.id as string;
	const blogProject = (await client.call("projects.add", { path: blog })).project.id as string;
	const lead = (await client.call("sessions.create", { kind: "build", cwd: app })).ref.id as string;
	const member = (await client.call("sessions.create", { kind: "build", cwd: app })).ref.id as string;
	const editorLead = (await client.call("sessions.create", { kind: "build", cwd: blog })).ref.id as string;
	await stop();

	const catalog = JSON.parse(readFileSync(join(home, "sessions.json"), "utf8")) as { ref: { id: string }; team?: object }[];
	for (const e of catalog) {
		if (e.ref.id === lead) e.team = { id: "team_app", role: "lead", kind: "lead" };
		if (e.ref.id === member) e.team = { id: "team_app", role: "builder", kind: "write", taskId: "T1" };
		if (e.ref.id === editorLead) e.team = { id: "team_blog", role: "lead", kind: "lead" };
	}
	writeFileSync(join(home, "sessions.json"), JSON.stringify(catalog));

	const dev = (await import("../src/work/playbooks.js")).BUILTIN_PLAYBOOKS.find((p) => p.id === "development")!;
	const teamsDir = join(home, "Teams");
	for (const [slug, brief, notes] of [["dev", "Always write British English.", "# Dev: notes\n\nThe CI is slow on Mondays."], ["blog", "", ""]] as const) {
		mkdirSync(join(teamsDir, slug), { recursive: true });
		writeFileSync(join(teamsDir, slug, "TEAM.md"), `# ${slug}\n\n${brief || "<!-- What every member of this team is told. -->"}\n`);
		writeFileSync(join(teamsDir, slug, "NOTES.md"), `${notes || "# notes\n\n<!-- nothing yet -->"}\n`);
	}
	const devRoles = [role("lead", "Tech lead", "lead", "You lead."), role("builder", "Builder", "write", dev.build.text, { done: dev.build.done }), role("qa", "QA", "review", dev.review!.text, { model: "faux:faux-1" }), role("ci", "CI", "integrate", "Merges.")];
	const blogRoles = [role("lead", "Editor in chief", "lead", "You lead."), role("writer", "Writer", "write", "You write posts for bakers.", { done: "A post with a recipe." }), role("photo", "Photographer", "write", "You describe the photos each post needs."), role("proof", "Proofreader", "review", "You check spelling.", { agent: "agt_rita" })];
	const at = "2026-11-10T10:00:00.000Z";
	writeFileSync(
		join(home, "teams.json"),
		JSON.stringify([
			{ id: "team_app", definitionId: "tdef_dev", name: "Dev", slug: "dev", template: "development", roles: devRoles, style: dev.plan, cwd: app, folder: join(teamsDir, "dev"), git: { base: "main", branch: "team/dev-1234", integration }, memberMode: "auto_edit", maxParallel: 2, testCommand: "true", reviewLimit: 2, budgetPerJob: 4, tasks: [{ id: "T1", title: "Login", brief: "Build it", role: "builder", state: "done", by: "lead", conversationId: lead, sessionId: member, attempts: 1, createdAt: at, updatedAt: at }], nextTask: 2, createdAt: at },
			{ id: "team_blog", definitionId: "tdef_blog", name: "Bakery blog", slug: "bakery-blog", template: "custom", roles: blogRoles, style: "One post per task.", cwd: blog, folder: join(teamsDir, "blog"), memberMode: "full_auto", maxParallel: 3, tasks: [], nextTask: 1, routines: [{ id: "r1", on: "time", prompt: "Plan next week's posts", cron: "0 9 * * 1", tz: "UTC", by: "lead", createdAt: at, runs: 0 }], createdAt: at },
		]),
	);
	writeFileSync(
		join(home, "team-definitions.json"),
		JSON.stringify([
			{ id: "tdef_dev", name: "Dev", template: "development", roles: devRoles, style: dev.plan, folder: join(teamsDir, "dev"), memberMode: "auto_edit", saved: false, createdAt: at },
			{ id: "tdef_blog", name: "Bakery blog", template: "custom", roles: blogRoles, style: "One post per task.", folder: join(teamsDir, "blog"), memberMode: "full_auto", saved: true, createdAt: at },
			{ id: "tdef_spare", name: "Podcast team", template: "custom", roles: [role("lead", "Producer", "lead", "You lead."), role("r", "Researcher", "write", "You research guests.")], style: "One guest per task.", folder: join(teamsDir, "podcast"), memberMode: "auto_edit", saved: true, createdAt: at },
		]),
	);
	mkdirSync(join(teamsDir, "Templates", "launch", "roles"), { recursive: true });
	writeFileSync(join(teamsDir, "Templates", "launch", "TEAM.md"), "---\nname: Launch team\nstyle: One channel per task.\n---\n\n# Launch team\n");
	writeFileSync(join(teamsDir, "Templates", "launch", "roles", "01-lead.md"), "---\nname: Lead\nkind: lead\n---\n\nYou lead.\n");
	writeFileSync(join(teamsDir, "Templates", "launch", "roles", "02-copy.md"), "---\nname: Copywriter\nkind: write\n---\n\nYou write the copy.\n");

	client = await start(home);
	type Work = { project: string; way: Record<string, unknown>; git?: { branch: string }; tasks: { id: string; helper: string; by: string; state: string; conversationId?: string }[] };
	const all = ((await client.call("work.list", {})) as { work: Work[] }).work;
	const appWork = all.find((w) => w.project === appProject)!;
	// The development team: the built-in playbook, its settings and board as they were.
	expect(appWork.way).toEqual({ parallel: true, review: true, reviewLimit: 2, testCommand: "true", maxParallel: 2, reviewModel: "faux:faux-1", helperMode: "auto_edit", budgetPerJob: 4, playbook: "development" });
	expect(appWork.git?.branch).toBe("team/dev-1234");
	expect(appWork.tasks).toEqual([expect.objectContaining({ id: "T1", helper: "Builder", by: "piopio", state: "done", conversationId: lead })]);
	// TEAM.md and the team's notes are in the project's NOTES.md.
	const notes = readFileSync(join(app, "NOTES.md"), "utf8");
	expect(notes).toContain("Use pnpm.");
	expect(notes).toContain("## From Dev");
	expect(notes).toContain("Always write British English.");
	expect(notes).toContain("The CI is slow on Mondays.");

	// The custom team: a playbook in the project with its members' text, and its routine on the project.
	const blogWork = all.find((w) => w.project === blogProject)!;
	expect(blogWork.way).toMatchObject({ parallel: true, review: true, helperMode: "full_auto", playbook: "how-bakery-blog-works" });
	const playbook = readFileSync(join(blog, ".pi", "skills", "how-bakery-blog-works", "SKILL.md"), "utf8");
	expect(playbook).toMatch(/^---\nname: how-bakery-blog-works\ndescription: /);
	expect(playbook).toContain("## Planning\n\nOne post per task.");
	expect(playbook).toContain("a helper called “Photographer”");
	expect(playbook).toContain("## Doing tasks: Writer\n\nYou write posts for bakers.\n\nDone means: A post with a recipe.");
	expect(playbook).toContain("## Reviewing: Proofreader\n\nYou check spelling.");
	expect(((await client.call("work.playbooks", { project: blogProject })) as { playbooks: { id: string; source: string }[] }).playbooks[0]).toEqual(expect.objectContaining({ id: "how-bakery-blog-works", source: "project" }));
	expect(((await client.call("automations.list", { project: blogProject })) as { automations: { id: string; by: string; runsAs: string }[] }).automations).toEqual([expect.objectContaining({ id: "r1", by: "piopio", runsAs: "piopio" })]);

	// Unused saved teams and your templates: playbooks in your skills library.
	expect(existsSync(join(home, "pi-agent", "skills", "how-podcast-works", "SKILL.md"))).toBe(true);
	expect(existsSync(join(home, "pi-agent", "skills", "how-launch-works", "SKILL.md"))).toBe(true);

	// Lead conversations are plain ones with Piopio; the member's session is a helper's.
	const sessions = (await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; helper?: object; team?: object }[];
	expect(sessions.find((s) => s.ref.id === lead)).not.toHaveProperty("team");
	expect(sessions.find((s) => s.ref.id === lead)).not.toHaveProperty("helper");
	expect(sessions.find((s) => s.ref.id === member)?.helper).toEqual({ project: appProject, kind: "build", taskId: "T1" });

	// The report, once; the old files are kept, renamed; the team folders are untouched.
	const { report } = (await client.call("work.migrationReport", {})) as { report?: string };
	expect(report).toContain("# What changed in your teams");
	expect(report).toContain("**Dev**");
	expect(report).toContain("Proofreader stays one of your agents");
	expect(existsSync(join(home, "teams.before-26.json"))).toBe(true);
	expect(existsSync(join(home, "team-definitions.before-26.json"))).toBe(true);
	expect(existsSync(join(home, "teams.json"))).toBe(false);
	expect(readFileSync(join(teamsDir, "dev", "TEAM.md"), "utf8")).toContain("British English");
	await client.call("work.dismissMigrationReport", {});
	expect(((await client.call("work.migrationReport", {})) as { report?: string }).report).toBeUndefined();

	// C1's "done when": the migrated project runs a three-task job from a plain conversation with Piopio, reviewed and
	// merged on the team's old branch, with the models it had.
	const brief = (file: string) => `write: ${file} | hello from ${file}\ncall: verdict | ${JSON.stringify({ pass: true, notes: "Fine." })}`;
	const piopio = (await client.call("sessions.create", { kind: "build", cwd: app })).ref as { kind: string; id: string };
	await client.call("sessions.submit", { ref: piopio, input: { text: ["a.txt", "b.txt", "c.txt"].map((f) => `call: create_task | ${JSON.stringify({ title: `Add ${f}`, brief: brief(f) })}`).join("\n") } });
	const until = async <T>(get: () => Promise<T>, ok: (v: T) => boolean) => {
		for (const end = Date.now() + 50_000; ; ) {
			const v = await get();
			if (ok(v)) return v;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 800)}`);
			await new Promise((r) => setTimeout(r, 100));
		}
	};
	const job = await until(async () => ((await client.call("work.get", { project: appProject })) as { work: Work & { tasks: { id: string; state: string; reviewSessionId?: string }[] } }).work.tasks.filter((t) => t.id !== "T1"), (ts) => ts.length === 3 && ts.every((t) => t.state === "done"));
	expect(job.map((t) => t.id)).toEqual(["T2", "T3", "T4"]);
	const merged = sh(app, "log", "--format=%s", "team/dev-1234");
	for (const id of ["T2", "T3", "T4"]) expect(merged).toContain(`Merge ${id}: Add`);
	const reviewers = ((await client.call("sessions.list", { kind: "build" })).sessions as { ref: { id: string }; model?: { provider: string; id: string } }[]).filter((s) => job.some((t) => t.reviewSessionId === s.ref.id));
	expect(reviewers.map((s) => s.model)).toEqual([{ provider: "faux", id: "faux-1" }, { provider: "faux", id: "faux-1" }, { provider: "faux", id: "faux-1" }]);

	// A second start changes nothing.
	await stop();
	client = await start(home);
	expect(((await client.call("work.list", {})) as { work: Work[] }).work).toHaveLength(2);
	expect(readFileSync(join(app, "NOTES.md"), "utf8").match(/## From Dev/g)).toHaveLength(1);
}, 60_000);
