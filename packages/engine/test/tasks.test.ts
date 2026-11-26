import { mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Non-blocking subagents (docs/spec/17 §3, 26 §7.1): `task` returns at once, the result comes back as a [Task]
// message on the side conversations' bridge; task_wait collects results here instead; task_stop stops one.

type Ref = { kind: string; id: string };
type Item = { kind: string; text?: string; tool?: string; status?: string; output?: string; details?: { sessionId?: string; status?: string } };

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

async function start() {
	const home = mkdtempSync(join(tmpdir(), "piopio-tasks-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-tasks-dir-")));
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	await client.call("projects.configure", { id: project.id, trust: true });
	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: "full_auto" })) as { ref: Ref };
	return { client, ref, dir };
}

const items = async (client: TestClient, ref: Ref) => (await client.call("sessions.open", { ref })).items as Item[];
const idle = (client: TestClient, ref: Ref) => until(async () => ((await client.call("sessions.open", { ref })) as { state: { status: string } }).state.status, (s) => s === "idle");
const task = (description: string, prompt: string) => `call: task | ${JSON.stringify({ description, prompt })}`;
type Child = { ref: Ref; title: string; parent?: { id: string; state?: string } };
const children = async (client: TestClient, parent: Ref) => ((await client.call("sessions.list", { kind: "build" })).sessions as Child[]).filter((s) => s.parent?.id === parent.id);

test("task returns at once; the parent's turn ends; the result comes back as a [Task] message that wakes it", async () => {
	const { client, ref, dir } = await start();
	await client.call("sessions.submit", { ref, input: { text: task("Write a", "write: a.txt | from the child") } });
	const first = await until(() => items(client, ref), (x) => x.some((i) => i.tool === "task" && i.status === "done"));
	const started = first.find((i) => i.tool === "task")!;
	expect(started.output).toMatch(/^Started ses_\w+\. Its result comes back as a \[Task\] message/);
	expect(started.details).toMatchObject({ status: "started" });
	const [child] = await until(() => children(client, ref), (c) => c[0]?.parent?.state === "done");
	expect(child).toMatchObject({ title: "Write a", parent: { id: ref.id, state: "done" } });
	expect(readFileSync(join(dir, "a.txt"), "utf8")).toBe("from the child");
	const after = await until(() => items(client, ref), (x) => x.some((i) => i.kind === "user" && i.text?.startsWith("[Task] “Write a”")) && x.at(-1)?.kind === "assistant");
	expect(after.find((i) => i.kind === "user" && i.text?.startsWith("[Task]"))!.text).toContain(`(${child!.ref.id}) finished.`);
}, 60_000);

test("task_wait collects a result here, and then no [Task] message comes; task_stop stops one", async () => {
	const { client, ref } = await start();
	await client.call("sessions.submit", { ref, input: { text: task("Slow one", "$ sleep 3\nwrite: slow.txt | done") } });
	await idle(client, ref);
	const id = (await items(client, ref)).find((i) => i.tool === "task")!.details!.sessionId!;
	await client.call("sessions.submit", { ref, input: { text: `call: task_wait | ${JSON.stringify({ ids: [id] })}` } });
	const waited = await until(() => items(client, ref), (x) => x.some((i) => i.tool === "task_wait" && i.status === "done") && x.at(-1)?.kind === "assistant");
	expect(waited.find((i) => i.tool === "task_wait")!.output).toContain(`${id}: Echo:`);
	await idle(client, ref);
	await new Promise((r) => setTimeout(r, 500));
	expect((await items(client, ref)).some((i) => i.kind === "user" && i.text?.startsWith("[Task]"))).toBe(false);

	// Stop: its turn ends, and its note says so.
	await client.call("sessions.submit", { ref, input: { text: task("Long one", "$ sleep 20") } });
	await idle(client, ref);
	const long = (await items(client, ref)).filter((i) => i.tool === "task").at(-1)!.details!.sessionId!;
	await until(() => children(client, ref), (c) => c.find((x) => x.ref.id === long)?.parent?.state === "working");
	await client.call("sessions.submit", { ref, input: { text: `call: task_stop | ${JSON.stringify({ id: long })}` } });
	await until(() => children(client, ref), (c) => c.find((x) => x.ref.id === long)?.parent?.state === "stopped");
	await until(() => items(client, ref), (x) => x.some((i) => i.kind === "user" && i.text?.includes(`(${long}) was stopped.`)));
	// Another conversation's subagent isn't this one's to wait for.
	await idle(client, ref);
	await client.call("sessions.submit", { ref, input: { text: `call: task_wait | ${JSON.stringify({ ids: ["ses_nope"] })}` } });
	await until(() => items(client, ref), (x) => x.some((i) => i.tool === "task_wait" && i.status === "error" && i.output?.includes("isn't one of this conversation's subagents")));
}, 90_000);

test("a result that finished mid-turn and that task_wait then collects doesn't also wake the parent as a [Task] message", async () => {
	const { client, ref } = await start();
	// The subagent answers at once while the parent's turn is still busy, so its note waits in the parent's queue.
	await client.call("sessions.submit", { ref, input: { text: `call: task | ${JSON.stringify({ description: "Quick one", prompt: "hello" })}\n$ sleep 4` } });
	const id = (await until(() => items(client, ref), (x) => x.some((i) => i.tool === "task" && i.status === "done"))).find((i) => i.tool === "task")!.details!.sessionId!;
	await until(() => children(client, ref), (c) => c.find((x) => x.ref.id === id)?.parent?.state === "done");
	// Still in the same turn, the model collects it with task_wait.
	await client.call("sessions.submit", { ref, input: { text: `call: task_wait | ${JSON.stringify({ ids: [id] })}` }, whenBusy: "steer" });
	const waited = await until(() => items(client, ref), (x) => x.some((i) => i.tool === "task_wait" && i.status === "done"));
	expect(waited.find((i) => i.tool === "task_wait")!.output).toContain(`${id}: Echo: hello`);
	await idle(client, ref);
	await new Promise((r) => setTimeout(r, 800));
	await idle(client, ref);
	expect((await items(client, ref)).some((i) => i.kind === "user" && i.text?.startsWith("[Task]"))).toBe(false);
}, 60_000);

test("past three running, a task waits as queued and starts when one ends; their results come back in one turn", async () => {
	const { client, ref } = await start();
	const four = [1, 2, 3, 4].map((n) => task(`Task ${n}`, `$ sleep 1\nwrite: t${n}.txt | ${n}`)).join("\n");
	await client.call("sessions.submit", { ref, input: { text: four } });
	const outputs = await until(() => items(client, ref), (x) => x.filter((i) => i.tool === "task" && i.status === "done").length === 4).then((x) => x.filter((i) => i.tool === "task").map((i) => i.output!));
	expect(outputs.filter((o) => o.includes("(queued: 3 are running)"))).toHaveLength(1);
	await until(() => children(client, ref), (c) => c.length === 4 && c.every((x) => x.parent?.state === "done"), 60_000);
	const woke = await until(() => items(client, ref), (x) => x.some((i) => i.kind === "user" && i.text?.startsWith("[Task]")) && x.at(-1)?.kind === "assistant").then((x) => x.filter((i) => i.kind === "user" && i.text?.startsWith("[Task]")));
	// The first three report together once the last of them ends; the queued one reports on its own after.
	await until(() => items(client, ref), (x) => x.filter((i) => i.kind === "user" && i.text?.startsWith("[Task]")).flatMap((i) => i.text!.match(/\[Task\] “Task \d”/g) ?? []).length === 4);
	expect(woke.length).toBeLessThanOrEqual(2);
}, 90_000);

/** A follow-up to a subagent that finished (docs/spec/37 SB6): its row works again and its new answer reaches Piopio. */
test("a follow-up to a finished subagent is a new turn: working again, then a second [Task] result", async () => {
	const { client, ref } = await start();
	await client.call("sessions.submit", { ref, input: { text: task("Look around", "read: nothing.txt") } });
	type Timed = Child & { parent?: { id: string; state?: string; startedAt?: string; endedAt?: string } };
	const timed = async () => (await children(client, ref)) as Timed[];
	const [first] = await until(timed, (c) => c[0]?.parent?.state === "done");
	expect(first!.parent!.startedAt).toBeTruthy();
	expect(first!.parent!.endedAt).toBeTruthy();
	await until(() => items(client, ref), (x) => x.filter((i) => i.kind === "user" && i.text?.startsWith("[Task] “Look around”")).length === 1 && x.at(-1)?.kind === "assistant");
	await idle(client, ref);

	// You write to it from the column.
	await client.call("sessions.submit", { ref: first!.ref, input: { text: "And the README?" } });
	const [again] = await until(timed, (c) => c[0]?.parent?.state === "done" && c[0]!.parent!.startedAt !== first!.parent!.startedAt);
	expect(Date.parse(again!.parent!.endedAt!)).toBeGreaterThanOrEqual(Date.parse(again!.parent!.startedAt!));
	const notes = await until(() => items(client, ref), (x) => x.filter((i) => i.kind === "user" && i.text?.startsWith("[Task] “Look around”")).length === 2);
	expect(notes.filter((i) => i.kind === "user" && i.text?.startsWith("[Task]")).at(-1)!.text).toContain("Echo: And the README?");
}, 60_000);

/** A message to a queued subagent joins its brief; it still starts in its turn, told both (docs/spec/37). */
test("writing to a queued subagent adds to its brief and doesn't start it out of turn", async () => {
	const { client, ref } = await start();
	// Started in one message, as a model does: the limit holds for parallel calls too.
	const four = [1, 2, 3].map((n) => task(`Busy ${n}`, "$ sleep 3")).concat(task("Waiting", "read: README.md")).map((t, i) => (i ? `& ${t}` : t)).join("\n");
	await client.call("sessions.submit", { ref, input: { text: four } });
	type Queued = Child & { parent?: { id: string; state?: string; brief?: string } };
	const kids = async () => (await children(client, ref)) as Queued[];
	const waiting = (await until(kids, (c) => c.some((x) => x.title === "Waiting" && x.parent?.state === "queued"))).find((x) => x.title === "Waiting")!;
	expect(waiting.parent!.brief).toBe("read: README.md");

	const answer = (await client.call("sessions.submit", { ref: waiting.ref, input: { text: "Also the LICENSE." } })) as { disposition: string };
	expect(answer.disposition).toBe("queued");
	const still = (await kids()).find((x) => x.title === "Waiting")!;
	expect(still.parent).toMatchObject({ state: "queued", brief: "read: README.md\n\nAlso the LICENSE." });

	// It starts when a slot frees, with the brief and what you added, as its first message.
	await until(kids, (c) => c.find((x) => x.title === "Waiting")?.parent?.state === "done", 60_000);
	const first = (await items(client, waiting.ref)).find((i) => i.kind === "user")!;
	expect(first.text).toBe("read: README.md\n\nAlso the LICENSE.");
}, 90_000);
