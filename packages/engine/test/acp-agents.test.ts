/** Antigravity CLI and Codex run a conversation over ACP (docs/spec/31, phase A3), against the pretend ACP agent. */
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo, ProviderInfo, SessionEvent, Snapshot } from "@piopio/protocol";
import { afterEach, beforeAll, describe, expect, test } from "vitest";
import { acpTool } from "../src/runtimes/acp.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

beforeAll(() => {
	process.env.PIOPIO_FAKE_ACP = "1";
});

async function start(home = mkdtempSync(join(tmpdir(), "piopio-acp-"))): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

async function stop(ctx: Ctx) {
	ctx.client.close();
	await ctx.engine.stop();
	open.splice(open.indexOf(ctx), 1);
}

afterEach(async () => {
	for (const ctx of [...open]) await stop(ctx);
});

type State = Snapshot["state"];
const states = (a: Ctx, sub: string) => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e): e is Extract<SessionEvent, { type: "state" }> => e.type === "state");
async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
	await a.client.waitFor(() => Boolean(states(a, sub).at(-1) && predicate(states(a, sub).at(-1)!.state)), 15_000);
	return states(a, sub).at(-1)!.state;
}
const answers = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "assistant" ? [i.parts.filter((p) => p.type === "text").map((p) => p.text).join("")] : []));
const AGY = { provider: "antigravity-cli", id: "gemini-4-neon" };
const CODEX = { provider: "codex-cli", id: "gpt-6.2-sol" };

async function project(a: Ctx) {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-acp-project-")));
	writeFileSync(join(folder, "package.json"), "{}");
	await a.client.call("projects.add", { path: folder });
	return folder;
}

async function turn(a: Ctx, ref: unknown, sub: string, text: string) {
	const before = states(a, sub).length;
	await a.client.call("sessions.submit", { ref, input: { text } });
	await a.client.waitFor(() => states(a, sub).slice(before).some((e) => e.state.status === "running") && states(a, sub).at(-1)!.state.status === "idle", 15_000);
}

test("Antigravity CLI and Codex are listed with their plans and models", { timeout: 30_000 }, async () => {
	const a = await start();
	const { providers } = (await a.client.call("providers.list")) as { providers: ProviderInfo[] };
	expect(providers.filter((p) => p.kind === "agent").map((p) => [p.id, p.name, p.status, p.billing])).toEqual([
		["antigravity-cli", "Antigravity CLI", "connected", "Google AI Pro plan"],
		["codex-cli", "Codex", "connected", "ChatGPT Plus plan"],
	]);
	const { models } = (await a.client.call("models.list")) as { models: ModelInfo[] };
	expect(models.filter((m) => m.agent).map((m) => `${m.provider}/${m.id}`)).toEqual([
		"antigravity-cli/gemini-4-neon",
		"antigravity-cli/gemini-4-argon",
		"antigravity-cli/gemini-3.8-flash",
		"codex-cli/gpt-6.2-sol",
		"codex-cli/gpt-6.2-astra",
		"codex-cli/gpt-6-luna",
	]);
});

describe("a Build session on Antigravity CLI", () => {
	test("a command named like one of Piopio's tools still asks: its title is the command", { timeout: 30_000 }, async () => {
		const a = await start();
		const folder = await project(a);
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: AGY });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.configure", { ref, approvalMode: "ask" });
		await a.client.call("sessions.submit", { ref, input: { text: "$ echo search_conversations && touch pwned\n$ mcp.piopio.search_conversations; touch pwned" } });
		for (const command of ["echo search_conversations && touch pwned", "mcp.piopio.search_conversations; touch pwned"]) {
			const waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval" && s.prompts![0]!.detail === command);
			expect(waiting.prompts![0]).toMatchObject({ title: "Run a command", tool: "bash" });
			await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny" } });
		}
		await stateWhere(a, sub, (s) => s.status === "idle");
		await stop(a);
	});

	test("asks in the tray before writing and running; a denial reaches the agent; reopens with its session", { timeout: 30_000 }, async () => {
		const a = await start();
		const folder = await project(a);
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: AGY });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.configure", { ref, approvalMode: "ask" });
		await a.client.call("sessions.submit", { ref, input: { text: "write: notes.md | hello\n$ rm -rf build" } });
		let waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ kind: "approval", title: "Write notes.md", tool: "write", detail: join(folder, "notes.md"), rule: { kind: "tool", pattern: "write" } });
		await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
		waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval" && s.prompts![0]!.tool === "bash");
		expect(waiting.prompts![0]).toMatchObject({ title: "Run a command", detail: "rm -rf build", rule: { kind: "command", pattern: "rm" } });
		await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);

		expect(readFileSync(join(folder, "notes.md"), "utf8")).toBe("hello");
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		const tools = snap.items.flatMap((i) => (i.kind === "tool" ? [i] : []));
		expect(tools.map((t) => [t.tool, t.status])).toEqual([
			["write", "done"],
			["bash", "error"],
		]);
		expect(tools[0]!.details).toMatchObject({ type: "diff", path: join(folder, "notes.md") });
		expect(answers(snap).at(-1)).toMatch(/^Echo: write: notes.md/);
		expect(snap.items.find((i) => i.kind === "assistant" && i.model)).toMatchObject({ model: "antigravity-cli/gemini-4-neon" });
		expect(snap.state.context).toEqual({ tokens: 1200, window: 200000 });

		// After a restart: the same session, loaded again (its replay isn't shown twice), and the settings applied.
		await stop(a);
		const b = await start(a.home);
		const sub2 = (await b.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await b.client.call("sessions.configure", { ref, model: { provider: "antigravity-cli", id: "gemini-4-argon" }, thinking: "low" });
		await turn(b, ref, sub2, "model?");
		await turn(b, ref, sub2, "effort?");
		await turn(b, ref, sub2, "mode?");
		const after: Snapshot = await b.client.call("sessions.open", { ref });
		expect(answers(after).slice(-3)).toEqual(["Model: gemini-4-argon", "Effort: low", "Mode: default"]);
		expect(answers(after).join("")).not.toContain("replayed history");
		expect(JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8")).sessionId).toMatch(/^fake-acp-/);
	});

	test("Read only refuses the agent's changes without asking", { timeout: 20_000 }, async () => {
		const a = await start();
		const folder = await project(a);
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: AGY });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.configure", { ref, approvalMode: "read_only" });
		await turn(a, ref, sub, "write: x.txt | nope");
		expect(existsSync(join(folder, "x.txt"))).toBe(false);
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		expect(snap.items.find((i) => i.kind === "tool")).toMatchObject({ tool: "write", status: "error" });
		expect(states(a, sub).some((e) => e.state.status === "waiting_approval")).toBe(false);
	});
});

test("Codex: Piopio's modes are Codex's own; a chat on Piopio's agent switches to it with the summary", { timeout: 30_000 }, async () => {
	const a = await start();
	const folder = await project(a);
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: { provider: "faux", id: "faux-1" } });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await a.client.call("sessions.configure", { ref, approvalMode: "auto_edit" });
	await turn(a, ref, sub, "the export breaks on folders");
	await a.client.call("sessions.configure", { ref, model: CODEX });
	await a.client.waitFor((n) => n.subscriptionId === sub && n.events.some((e) => e.type === "resnapshot" && e.snapshot.state.model?.provider === "codex-cli"));
	await turn(a, ref, sub, "fix it");
	let snap: Snapshot = await a.client.call("sessions.open", { ref });
	expect(snap.items.some((i) => i.kind === "system" && i.text.startsWith("Now running in Codex"))).toBe(true);
	expect(answers(snap).at(-1)).toContain("User: the export breaks on folders");
	await turn(a, ref, sub, "mode?");
	snap = await a.client.call("sessions.open", { ref });
	expect(answers(snap).at(-1)).toBe("Mode: workspace-write");
});

test.each([
	["Codex, by HTTP", CODEX],
	["Antigravity CLI, through the stdio bridge", AGY],
])("Piopio's tools reach %s; their cards use Piopio's names", { timeout: 30_000 }, async (_name, model) => {
	const a = await start();
	const other = await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } });
	const otherSub = (await a.client.call("sessions.subscribe", { ref: other.ref })).subscriptionId as string;
	await turn(a, other.ref, otherSub, "pineapple pizza plans for Friday");
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await turn(a, ref, sub, 'call: search_conversations | {"query":"pineapple"}');
	const tool = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.find((i) => i.kind === "tool");
	expect(tool).toMatchObject({ tool: "search_conversations", status: "done" });
	expect(tool?.kind === "tool" && tool.output).toContain("pineapple pizza");
	expect(states(a, sub).some((e) => e.state.status === "waiting_approval")).toBe(false);
});

test.each([
	["Codex, as ACP's systemPrompt", CODEX],
	["Antigravity CLI, in its _meta", AGY],
])("Piopio's instructions reach %s", { timeout: 20_000 }, async (_name, model) => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await turn(a, ref, sub, "instructions?");
	const said = answers((await a.client.call("sessions.open", { ref })) as Snapshot).at(-1)!;
	expect(said).toMatch(/^Instructions: /);
	expect(said).toContain("Visuals");
});

test("after a switch, the state says who ran it before (the composer's Undo) until the first message", { timeout: 20_000 }, async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await turn(a, ref, sub, "hello");
	await a.client.call("sessions.configure", { ref, model: CODEX });
	expect(((await a.client.call("sessions.open", { ref })) as Snapshot).state.handoff).toEqual({ from: { provider: "faux", id: "faux-1" } });
	await turn(a, ref, sub, "go on");
	expect(((await a.client.call("sessions.open", { ref })) as Snapshot).state.handoff).toBeUndefined();
	expect(states(a, sub).at(-1)!.state.handoff).toBeUndefined();
});

test("ACP tool calls get Piopio's names and arguments", () => {
	expect(acpTool({ kind: "execute", title: "ls", rawInput: { CommandLine: "ls -la" } })).toEqual({ name: "bash", args: { CommandLine: "ls -la", command: "ls -la" } });
	expect(acpTool({ kind: "execute", rawInput: { command: ["git", "status"] } }).args.command).toBe("git status");
	expect(acpTool({ kind: "edit", locations: [{ path: "/a/b.ts" }], content: [{ type: "diff", path: "/a/b.ts", oldText: "x", newText: "y" }] })).toEqual({ name: "edit", args: { path: "/a/b.ts" } });
	expect(acpTool({ kind: "edit", content: [{ type: "diff", path: "/a/new.md", oldText: null, newText: "hi" }] })).toEqual({ name: "write", args: { path: "/a/new.md", content: "hi" } });
	expect(acpTool({ kind: "read", locations: [{ path: "/a/c.ts" }] }).name).toBe("read");
});
