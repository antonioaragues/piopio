/** What Piopio keeps on disk stays bounded, and goes when what it was for goes (the operational review, logs and disk). */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, expect, test } from "vitest";
import { CheckpointStore } from "../src/checkpoints.js";
import { ExtraCosts } from "../src/costs.js";
import { logLine, rotateLog } from "../src/logs.js";
import { enginePaths } from "../src/paths.js";
import { InputReceipts } from "../src/requests.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

const open: { client: TestClient; engine: Engine }[] = [];
afterEach(async () => {
	for (const a of open.splice(0)) {
		a.client.close();
		await a.engine.stop();
	}
});

async function start() {
	const home = mkdtempSync(join(tmpdir(), "piopio-disk-"));
	const paths = enginePaths(home);
	const trash = join(home, "trash");
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: trash, agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	open.push({ client, engine });
	return { home, trash, client, engine };
}

const sh = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8" });
function repo(): string {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-disk-git-")));
	sh(dir, "init", "-q", "-b", "main");
	sh(dir, "config", "user.email", "t@example.com");
	sh(dir, "config", "user.name", "Test");
	writeFileSync(join(dir, "a.txt"), "one\n");
	sh(dir, "add", ".");
	sh(dir, "commit", "-qm", "Initial commit");
	return dir;
}

test("engine.log: each line has its time; past the limit it moves to engine.log.1 and starts again", () => {
	expect(logLine("listening", new Date("2026-11-23T09:00:00Z"))).toBe("2026-11-23T09:00:00.000Z listening\n");
	const file = join(mkdtempSync(join(tmpdir(), "piopio-log-")), "engine.log");
	writeFileSync(file, "x".repeat(50));
	expect(rotateLog(file, 100)).toBe(false);
	writeFileSync(file, "y".repeat(150));
	expect(rotateLog(file, 100)).toBe(true);
	expect(statSync(file).size).toBe(0);
	expect(readFileSync(`${file}.1`, "utf8")).toBe("y".repeat(150));
	expect(rotateLog(join(tmpdir(), "no-such-log"))).toBe(false);
});

test("request receipts go after a week; those from before the change are dated when it runs", () => {
	const file = join(mkdtempSync(join(tmpdir(), "piopio-receipts-")), "requests.db");
	const old = new DatabaseSync(file);
	old.exec("CREATE TABLE receipts (id TEXT PRIMARY KEY, hash TEXT NOT NULL, result TEXT NOT NULL)");
	old.prepare("INSERT INTO receipts VALUES ('r1', 'h', '{}')").run();
	old.close();
	const receipts = new InputReceipts(file);
	expect(receipts.prune(Date.now() + 6 * 24 * 3600_000)).toBe(0);
	expect(receipts.prune(Date.now() + 8 * 24 * 3600_000)).toBe(1);
	receipts.close();
	expect(new DatabaseSync(file).prepare("PRAGMA journal_mode").get()).toEqual({ journal_mode: "wal" });
});

test("a month's costs are read by range: the month's own, not the next one's", () => {
	const costs = new ExtraCosts(join(mkdtempSync(join(tmpdir(), "piopio-costs-")), "extra-costs.db"));
	const db = (costs as unknown as { db: DatabaseSync }).db;
	for (const [at, usd] of [["2026-11-30T23:59:59.000Z", 1], ["2026-12-01T00:00:00.000Z", 2], ["2026-12-31T10:00:00.000Z", 3], ["2027-01-01T00:00:00.000Z", 4]] as const) db.prepare("INSERT INTO extra_costs VALUES (?, 'app', 'utility', 'm', ?)").run(at, usd);
	expect(costs.monthUsd("app", "2026-11")).toBe(1);
	expect(costs.monthUsd("app", "2026-12")).toBe(5);
	expect(costs.monthUsd("app", "2027-01")).toBe(4);
	expect((db.prepare("EXPLAIN QUERY PLAN SELECT SUM(usd) FROM extra_costs WHERE scope = 'app' AND at >= '2026-12' AND at < '2027-01'").all() as { detail: string }[]).map((r) => r.detail).join(" ")).toContain("extra_costs_scope_at");
	costs.close();
});

test("deleting a conversation with a worktree: a clean one is removed, one with work goes to the Trash; the branch stays", async () => {
	const a = await start();
	const dir = repo();
	await a.client.call("projects.add", { path: dir });
	const make = async (branch: string) => {
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: dir, workOn: { kind: "worktree", branch } });
		const summary = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id);
		return { ref, cwd: summary.cwd as string };
	};
	const clean = await make("piopio/clean");
	const dirty = await make("piopio/dirty");
	writeFileSync(join(dirty.cwd, "work.txt"), "not committed\n");
	await a.client.call("sessions.delete", { ref: clean.ref });
	await a.client.call("sessions.delete", { ref: dirty.ref });
	expect(existsSync(clean.cwd)).toBe(false);
	expect(existsSync(dirty.cwd)).toBe(false);
	const trashed = readdirSync(a.trash).find((n) => existsSync(join(a.trash, n, "work.txt")));
	expect(trashed).toBeDefined();
	expect(sh(dir, "worktree", "list")).not.toContain(a.home);
	expect(sh(dir, "branch", "--list", "piopio/*")).toContain("piopio/clean");
	expect(sh(dir, "branch", "--list", "piopio/*")).toContain("piopio/dirty");
});

test("removing a project takes its checkpoints and its worktree conversations with it", async () => {
	const a = await start();
	const dir = repo();
	const { project } = await a.client.call("projects.add", { path: dir });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: dir, workOn: { kind: "worktree", branch: "piopio/side" } });
	await new CheckpointStore(join(a.home, "checkpoints")).snapshot(dir, "Before a turn");
	expect(readdirSync(join(a.home, "checkpoints")).filter((n) => n.endsWith(".git")).length).toBe(1);
	await a.client.call("projects.remove", { id: project.id });
	expect(readdirSync(join(a.home, "checkpoints")).filter((n) => n.endsWith(".git"))).toEqual([]);
	expect((await a.client.call("sessions.list", { kind: "build" })).sessions.some((s: { ref: { id: string } }) => s.ref.id === ref.id)).toBe(false);
	expect(existsSync(join(a.home, "worktrees")) ? readdirSync(join(a.home, "worktrees")).flatMap((p) => readdirSync(join(a.home, "worktrees", p))) : []).toEqual([]);
});

test("deleting an agent removes its automations and its Telegram state", async () => {
	const a = await start();
	const { ref } = await a.client.call("agents.create", { name: "Pinpin", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	await a.client.call("automations.add", { runsAs: ref.id, when: "0 9 * * 1", prompt: "Weekly note" });
	const telegram = join(a.home, "channels", "telegram");
	mkdirSync(telegram, { recursive: true });
	writeFileSync(join(telegram, `${ref.id}.json`), JSON.stringify({ offset: 7 }));
	const mine = async () => ((await a.client.call("automations.list", {})) as { automations: { runsAs: string }[] }).automations.filter((x) => x.runsAs === ref.id);
	expect((await mine()).length).toBe(1);
	await a.client.call("sessions.delete", { ref });
	expect(await mine()).toEqual([]);
	for (let i = 0; i < 50 && existsSync(join(telegram, `${ref.id}.json`)); i++) await new Promise((r) => setTimeout(r, 20));
	expect(existsSync(join(telegram, `${ref.id}.json`))).toBe(false);
});
