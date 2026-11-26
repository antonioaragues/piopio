import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// The Watchdog (docs/spec/17 §4, DP1), with thresholds in seconds: a silent turn and one repeating itself become a
// note in Needs you (yours) or a report to the parent (a side conversation's); an approval left waiting, a reminder.

type Ref = { kind: string; id: string };
type Note = { id: string; ref: Ref; rule: string; text: string };

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 30_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1500)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

async function start(mode = "full_auto", git = false, seed?: (home: string) => void) {
	const home = mkdtempSync(join(tmpdir(), "piopio-wd-"));
	seed?.(home);
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, watchdog: { silentMs: 1500, waitingMs: 1500, tickMs: 200 }, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-wd-dir-")));
	if (git) {
		const sh = (...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } });
		sh("init", "-q", "-b", "main");
		writeFileSync(join(dir, "README.md"), "#\n");
		sh("add", "-A");
		sh("commit", "-qm", "init");
	}
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: added } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	await client.call("projects.configure", { id: added.id, trust: true });
	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: mode })) as { ref: Ref };
	return { client, ref };
}

const notes = async (client: TestClient) => ((await client.call("watchdog.list", {})) as { notes: Note[] }).notes;
const attention = (client: TestClient) => client.notifications.filter((n) => n.method === "session.attention").map((n) => n.params as { ref: Ref; kind: string; message: string });

test("W1: a turn with nothing new is a note in Needs you, with what's running; it goes when the turn moves on", async () => {
	const { client, ref } = await start();
	await client.call("sessions.submit", { ref, input: { text: "$ sleep 4" } });
	const [note] = await until(() => notes(client), (n) => n.length === 1);
	expect(note).toMatchObject({ ref: { id: ref.id }, rule: "silent", text: expect.stringMatching(/^It looks stuck: nothing new for \d+ seconds while running `sleep 4`\.$/) });
	expect(attention(client).some((a) => a.ref.id === ref.id && a.kind === "notify" && a.message.startsWith("It looks stuck"))).toBe(true);
	await until(() => notes(client), (n) => n.length === 0, 15_000);
}, 30_000);

test("W2: the same failing command three times is a note that stays after the turn, until you dismiss it", async () => {
	const { client, ref } = await start();
	await client.call("sessions.submit", { ref, input: { text: "$ ls /nope-not-here\n$ ls /nope-not-here\n$ ls /nope-not-here" } });
	const [note] = await until(() => notes(client), (n) => n.some((x) => x.rule === "looping"));
	expect(note!.text).toContain("It is repeating itself");
	await until(async () => ((await client.call("sessions.open", { ref })) as { state: { status: string } }).state.status, (s) => s === "idle");
	expect((await notes(client)).map((n) => n.rule)).toEqual(["looping"]);
	await client.call("watchdog.dismiss", { id: note!.id });
	expect(await notes(client)).toEqual([]);
}, 30_000);

test("deleting a conversation takes its notes with it", async () => {
	const { client, ref } = await start();
	await client.call("sessions.submit", { ref, input: { text: "$ ls /nope-not-here\n$ ls /nope-not-here\n$ ls /nope-not-here" } });
	await until(() => notes(client), (n) => n.some((x) => x.rule === "looping"));
	await until(async () => ((await client.call("sessions.open", { ref })) as { state: { status: string } }).state.status, (s) => s === "idle");
	await client.call("sessions.delete", { ref });
	expect(await notes(client)).toEqual([]);
}, 30_000);

test("on start, notes about conversations that no longer exist are dropped", async () => {
	const orphan = { id: "wd_old", ref: { kind: "thread", id: "thr_gone" }, title: "Gone", rule: "looping", text: "It is repeating itself.", at: "2026-11-17T23:11:54.132Z" };
	const { client } = await start("full_auto", false, (home) => writeFileSync(join(home, "watchdog.json"), JSON.stringify([orphan])));
	expect(await notes(client)).toEqual([]);
}, 30_000);

test("W3: an approval left waiting gets one reminder, and no note", async () => {
	const { client, ref } = await start("ask");
	await client.call("sessions.submit", { ref, input: { text: "$ printf hello" } });
	await until(() => attention(client), (a) => a.some((x) => x.message.startsWith("Still waiting for you after")));
	await new Promise((r) => setTimeout(r, 800));
	expect(attention(client).filter((x) => x.message.startsWith("Still waiting for you"))).toHaveLength(1);
	expect(await notes(client)).toEqual([]);
}, 30_000);

test("a side conversation that looks stuck is reported to its parent, not to you", async () => {
	const { client, ref } = await start("full_auto", true);
	await client.call("sessions.side.start", { ref, brief: "$ sleep 4", title: "Slow side" });
	const items = async () => (await client.call("sessions.open", { ref })).items as { kind: string; text?: string }[];
	await until(items, (x) => x.some((i) => i.kind === "user" && /^\[Side\] “Slow side” \(ses_\w+\) looks stuck: nothing new for/.test(i.text ?? "")));
	expect(await notes(client)).toEqual([]);
}, 30_000);
