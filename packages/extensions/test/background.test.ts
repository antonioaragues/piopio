/** Background commands (docs/spec/05-build §9 TM4): the process manager. */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { MAX_RUNNING, ProcessManager, startedText } from "../src/background.js";

const managers: ProcessManager[] = [];
const manager = () => {
	const m = new ProcessManager();
	managers.push(m);
	return m;
};
afterEach(async () => {
	for (const m of managers.splice(0)) await m.stopAll();
});
const cwd = () => mkdtempSync(join(tmpdir(), "piopio-bg-"));
const node = (script: string) => `node -e ${JSON.stringify(script)}`;

test("a dev server: started, its address found, its output read in pieces, stopped with what it started", async () => {
	const m = manager();
	const changes: string[] = [];
	m.onChange = (list) => changes.push(list.map((p) => `${p.id}:${p.status}:${p.urls.join(",")}`).join(" "));
	const cmd = node("console.log('\\u001b[32mready\\u001b[0m on http://0.0.0.0:5173/'); setInterval(() => console.log('tick'), 100)");
	const p = m.start(cmd, cmd, cwd(), { shell: "/bin/sh" });
	expect(p).toMatchObject({ id: "p1", status: "running" });
	await m.settle("p1", 3000);
	const first = m.output("p1");
	expect(first.text).toContain("ready on http://0.0.0.0:5173/");
	expect(first.text).not.toContain("\u001b");
	expect(first.process.urls).toEqual(["http://localhost:5173/"]);
	expect(startedText(first.process, first.text)).toContain("It's serving http://localhost:5173/");
	await new Promise((r) => setTimeout(r, 350));
	const next = m.output("p1");
	expect(next.text).toMatch(/^tick\n/);
	expect(next.text).not.toContain("ready");
	expect(m.output("p1", { tail: 1 }).text).toBe("tick");
	// The app reads from a position of its own, without moving the agent's.
	expect(m.output("p1", { since: 0, markRead: false }).text).toContain("ready");
	const stopped = await m.stop("p1");
	expect(stopped).toMatchObject({ status: "stopped" });
	expect(changes.at(-1)).toBe("p1:stopped:http://localhost:5173/");
});

test("a command that ends on its own reports its exit code", async () => {
	const m = manager();
	m.start("exit 3", "echo bye; exit 3", cwd(), { shell: "/bin/sh" });
	for (let i = 0; i < 50 && m.get("p1")!.status === "running"; i++) await new Promise((r) => setTimeout(r, 50));
	expect(m.get("p1")).toMatchObject({ status: "exited", exitCode: 3 });
	expect(m.output("p1").text).toBe("bye\n");
});

test("stopping one stops its children too; at most MAX_RUNNING at once", async () => {
	const m = manager();
	m.start("parent", "sleep 30 & sleep 30 & wait", cwd(), { shell: "/bin/sh" });
	const p = await m.stop("p1", 500);
	expect(p.status).toBe("stopped");
	for (let i = 0; i < MAX_RUNNING; i++) m.start("sleep", "sleep 30", cwd(), { shell: "/bin/sh" });
	expect(() => m.start("one more", "sleep 30", cwd(), { shell: "/bin/sh" })).toThrow(/already running/);
});
