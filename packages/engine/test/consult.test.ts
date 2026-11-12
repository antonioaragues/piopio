import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { mentioned } from "../src/consult.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { detectChecks } from "../src/teams/fit.js";
import { TestClient } from "./client.js";

// Working with a team (docs/spec/21 D6): your agents in a conversation (@Name, ask_agent) and the fit check.

type Ctx = { engine: Engine; client: TestClient };
const open: Ctx[] = [];
async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-d6-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {}, agentAskTimeoutMs: 30_000 });
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

test("@mentions find your agents by name, longest first, and not inside a longer word", () => {
	const agents = [
		{ id: "a1", name: "Code" },
		{ id: "a2", name: "Code reviewer" },
		{ id: "a3", name: "Rita" },
	];
	expect(mentioned("@Code reviewer, is this safe?", agents).map((a) => a.id)).toEqual(["a2"]);
	expect(mentioned("ask @code and @RITA", agents).map((a) => a.id).sort()).toEqual(["a1", "a3"]);
	expect(mentioned("@Ritas list", agents)).toEqual([]);
	expect(mentioned("no mention", agents)).toEqual([]);
});

test("a conversation asks one of your agents: it answers in its conversation with Piopio, and the call says whether @ brought it in", async () => {
	const a = await start();
	const faux = { provider: "faux", id: "faux-1" };
	const { ref: rita } = await a.client.call("agents.create", { name: "Rita", owner: "Antonio", instructions: "You review code.", model: faux });
	// Rita accepts only one agent: your conversations still reach her.
	const got = await a.client.call("agents.get", { ref: rita });
	await a.client.call("agents.save", { ref: rita, definition: { ...got.definition, acceptFrom: ["nobody"] }, instructions: got.instructions });

	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-d6-p-")));
	await a.client.call("projects.add", { path: folder });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: "full_auto" });
	const items = () => a.client.call("sessions.open", { ref, fold: true }).then((s: Snapshot) => s.items);
	const tools = (xs: Snapshot["items"]) => xs.filter((i): i is Extract<Snapshot["items"][number], { kind: "tool" }> => i.kind === "tool" && i.tool === "ask_agent");

	await a.client.call("sessions.submit", { ref, input: { text: `call: ask_agent | ${JSON.stringify({ agent: "Rita", message: "@Rita is this safe?" })}` } });
	let xs = await until(items, (x) => tools(x).some((t) => t.status === "done") && x.at(-1)?.kind === "assistant");
	const call = tools(xs)[0]!;
	expect(call.output).toContain("Echo: For the user, from their conversation");
	expect(call.output).toContain("@Rita is this safe?");
	expect(call.details).toEqual({ type: "agent", agent: { id: rita.id, name: "Rita" }, joined: true, status: "replied" });

	// Asked on its own (no @): not "joined".
	await a.client.call("sessions.submit", { ref, input: { text: `call: ask_agent | ${JSON.stringify({ agent: "rita", message: "Any risks?" })}` } });
	xs = await until(items, (x) => tools(x).filter((t) => t.status === "done").length === 2 && x.at(-1)?.kind === "assistant");
	expect(tools(xs)[1]!.details).toEqual({ type: "agent", agent: { id: rita.id, name: "Rita" }, status: "replied" });

	// Someone who isn't one of your agents.
	await a.client.call("sessions.submit", { ref, input: { text: `call: ask_agent | ${JSON.stringify({ agent: "Bob", message: "hi" })}` } });
	xs = await until(items, (x) => tools(x).length === 3 && tools(x)[2]!.status !== "running" && x.at(-1)?.kind === "assistant");
	expect(tools(xs)[2]).toMatchObject({ status: "error", output: expect.stringContaining("No agent called “Bob”") });

	// Rita's side: she answered in her own conversation, which isn't one of her people.
	const people = (await a.client.call("agents.conversations", { ref: rita })).people as { role: string }[];
	expect(people.filter((p) => p.role === "agent")).toEqual([]);
}, 60_000);

test("the fit check: git, the checks it can run, AGENTS.md", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-d6-f-")));
	expect(await a.client.call("teams.fitCheck", { cwd: folder })).toEqual({ git: false, agentsMd: false });
	mkdirSync(join(folder, ".git"));
	writeFileSync(join(folder, "AGENTS.md"), "# Agents\n");
	writeFileSync(join(folder, "package.json"), JSON.stringify({ scripts: { test: "vitest run" } }));
	writeFileSync(join(folder, "pnpm-lock.yaml"), "");
	expect(await a.client.call("teams.fitCheck", { cwd: folder })).toEqual({ git: true, checks: "pnpm test", agentsMd: true, language: "JavaScript" });

	const other = realpathSync(mkdtempSync(join(tmpdir(), "piopio-d6-g-")));
	writeFileSync(join(other, "package.json"), JSON.stringify({ scripts: { test: 'echo "Error: no test specified" && exit 1' } }));
	expect(detectChecks(other)).toBeUndefined();
	writeFileSync(join(other, "Package.swift"), "// swift-tools-version:5.9\n");
	expect(detectChecks(other)).toBe("swift test");
	writeFileSync(join(other, "Makefile"), "build:\n\tcc x.c\ntest:\n\t./run\n");
	expect(detectChecks(other)).toBe("swift test");
});
