import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Piopio offers (docs/spec/26 CL9): parallel work in a project that doesn't have it yet; "Work in
// parallel" switches it on, and the same conversation plans the work with the board.

type Ctx = { engine: Engine; client: TestClient };
const open: Ctx[] = [];
async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-offers-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} } as ConstructorParameters<typeof Engine>[0]);
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	const ctx = { engine, client };
	open.push(ctx);
	return ctx;
}
afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 20_000): Promise<T> {
	const end = Date.now() + timeout;
	for (;;) {
		const value = await read();
		if (ready(value)) return value;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
		await new Promise((r) => setTimeout(r, 150));
	}
}

function project(): string {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-offers-p-")));
	writeFileSync(join(folder, "package.json"), JSON.stringify({ name: "app", scripts: { test: "node --test" }, devDependencies: { typescript: "5" } }));
	execFileSync("git", ["init", "-q", "-b", "main"], { cwd: folder });
	execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], { cwd: folder });
	return folder;
}

const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;

test("Piopio offers parallel work in a project and makes automations when asked; Work in parallel switches it on and the conversation plans with the board", async () => {
	const a = await start();
	const folder = project();
	const { project: added } = await a.client.call("projects.add", { path: folder });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: "full_auto" });
	const items = () => a.client.call("sessions.open", { ref, fold: true }).then((s: Snapshot) => s.items);
	type Tool = Extract<Snapshot["items"][number], { kind: "tool" }>;
	const tool = (xs: Snapshot["items"], name: string) => xs.flatMap((i) => (i.kind === "steps" ? (i.tools as Tool[]) : [i])).filter((i): i is Tool => i.kind === "tool" && i.tool === name);
	const idle = () => until(() => a.client.call("sessions.open", { ref }).then((x: Snapshot) => x.state.status), (st) => st === "idle");

	// The offers are Piopio's tools here; the board's aren't yet.
	await a.client.call("sessions.submit", { ref, input: { text: call("offer_parallel", { why: "Three screens can be built at once.", parts: ["Settings", "Profile", "Search"] }) } });
	let xs = await until(items, (x) => tool(x, "offer_parallel").some((t) => t.status === "done") && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "offer_parallel")[0]).toMatchObject({ output: expect.stringContaining("Offered"), args: { parts: ["Settings", "Profile", "Search"] } });
	// Something to repeat isn't an offer: Piopio makes the automation, here in the project (docs/spec/27 AU4, AU6).
	await a.client.call("sessions.submit", { ref, input: { text: call("automate", { when: "0 9 * * 1-5", prompt: "Summarize yesterday's commits" }) } });
	xs = await until(items, (x) => tool(x, "automate").some((t) => t.status === "done") && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "automate")[0]).toMatchObject({ output: expect.stringContaining("Every weekday at 09:00") });
	expect((await a.client.call("automations.list", { project: added.id })).automations).toEqual([expect.objectContaining({ runsAs: "piopio", project: added.id, by: "piopio", result: "conversation", runnerName: `Piopio in ${added.name}` })]);
	await idle();

	// Another project's conversation can't accept for this one.
	const other = project();
	await a.client.call("projects.add", { path: other });
	const { ref: elsewhere } = await a.client.call("sessions.create", { kind: "build", cwd: other, approvalMode: "full_auto" });
	await expect(a.client.call("work.accept", { project: added.id, sessionId: elsewhere.id })).rejects.toThrow(/another project/);

	// Work in parallel: it's on, with the fit check's checks, and this conversation is told to plan.
	const { work } = await a.client.call("work.accept", { project: added.id, sessionId: ref.id });
	expect(work.way).toMatchObject({ parallel: true, testCommand: "npm test", playbook: "development" });
	expect(work.git).toMatchObject({ base: "main" });
	xs = await until(items, (x) => x.some((i) => i.kind === "user" && i.text.startsWith("[Board] The user chose to work in parallel")) && x.at(-1)?.kind === "assistant");
	await idle();
	await a.client.call("sessions.submit", { ref, input: { text: call("list_tasks", {}) } });
	xs = await until(items, (x) => tool(x, "list_tasks").some((t) => t.status !== "running") && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "list_tasks")[0]).toMatchObject({ status: "done" });

	// With parallel work on, Piopio no longer offers it.
	await idle();
	await a.client.call("sessions.submit", { ref, input: { text: call("offer_parallel", { why: "x", parts: ["a", "b"] }) } });
	xs = await until(items, (x) => tool(x, "offer_parallel").length === 2 && tool(x, "offer_parallel")[1]!.status !== "running" && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "offer_parallel")[1]).toMatchObject({ status: "error" });
}, 90_000);
