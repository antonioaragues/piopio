/** Claude Code runs a whole conversation (docs/spec/31, phase A1), against the pretend Claude Code (claude-code-fake.ts). */
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo, ProviderInfo, SessionEvent, Snapshot } from "@piopio/protocol";
import { afterEach, beforeAll, describe, expect, test } from "vitest";
import { claudeBilling, ClaudeCodeAgent } from "../src/coding-agents.js";
import { enginePaths } from "../src/paths.js";
import { editPatch, permissionMode, piopioTool } from "../src/runtimes/claude-code.js";
import { fakeQueryOptions } from "../src/runtimes/claude-code-fake.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

beforeAll(() => {
	process.env.PIOPIO_FAKE_CLAUDE_CODE = "1";
});

async function start(home = mkdtempSync(join(tmpdir(), "piopio-cc-"))): Promise<Ctx> {
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
const texts = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "user" ? [["user", i.text]] : i.kind === "assistant" ? [["assistant", i.parts.map((p) => p.text).join(""), i.model]] : i.kind === "tool" ? [["tool", i.tool, i.status]] : i.kind === "system" ? [["system", i.text]] : []));
const CLAUDE = { provider: "claude-code", id: "opus" };

async function project(a: Ctx) {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-cc-project-")));
	writeFileSync(join(folder, "package.json"), "{}");
	await a.client.call("projects.add", { path: folder });
	return folder;
}

test("Claude Code is listed with its plan and models, as an agent", async () => {
	const a = await start();
	const { providers } = (await a.client.call("providers.list")) as { providers: ProviderInfo[] };
	expect(providers[0]).toMatchObject({ id: "claude-code", name: "Claude Code", kind: "agent", status: "connected", billing: "Claude Pro plan", agent: { signedIn: true } });
	const { models } = (await a.client.call("models.list")) as { models: ModelInfo[] };
	expect(models.filter((m) => m.provider === "claude-code").map((m) => [m.id, m.name, m.agent, m.billing])).toEqual([
		["opus", "Opus 5.5", true, "Claude Pro plan"],
		["sonnet", "Sonnet 5.5", true, "Claude Pro plan"],
		["haiku", "Haiku 5.5", true, "Claude Pro plan"],
	]);
});

describe.each(["thread", "build"] as const)("a %s on Claude Code", (kind) => {
	test("answers, streams, and reopens after a restart with its history and Claude Code's session", async () => {
		const a = await start();
		const cwd = kind === "build" ? await project(a) : undefined;
		const { ref } = await a.client.call("sessions.create", { kind, model: CLAUDE, ...(cwd ? { cwd } : {}) });
		const sub = await a.client.call("sessions.subscribe", { ref });
		expect(await a.client.call("sessions.submit", { ref, input: { text: "hello claude" } })).toMatchObject({ disposition: "started" });
		await stateWhere(a, sub.subscriptionId, (s) => s.status === "idle" && s.usage.outputTokens > 0);
		const events = a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).flatMap((n) => n.events);
		expect(events.some((e) => e.type === "item.delta")).toBe(true);
		const live: Snapshot = await a.client.call("sessions.open", { ref });
		expect(texts(live)).toEqual([
			["user", "hello claude"],
			["assistant", "Echo: hello claude", "claude-code/opus"],
		]);
		expect(live.state.model).toEqual(CLAUDE);
		// The plan pays: nothing counts as spending (CA6).
		expect(live.state.usage.costUsd).toBe(0);

		await stop(a);
		const b = await start(a.home);
		expect(texts(await b.client.call("sessions.open", { ref }))).toEqual(texts(live));
		const sub2 = await b.client.call("sessions.subscribe", { ref });
		await b.client.call("sessions.submit", { ref, input: { text: "again" } });
		await stateWhere(b, sub2.subscriptionId, (s) => s.status === "idle" && s.usage.outputTokens >= 10);
		const stored = JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8"));
		expect(stored.sessionId).toMatch(/^fake-session-/);
		expect(texts(await b.client.call("sessions.open", { ref })).map((t) => t[1])).toEqual(["hello claude", "Echo: hello claude", "again", "Echo: again"]);

		await b.client.call("sessions.delete", { ref });
		expect(existsSync(join(a.home, "chats", "agents", `${ref.id}.json`))).toBe(false);
		// Re-audit 2026-11-25 evals E1 and E3: its own ReportFindings is off, and its Bash gets Piopio's shell setup.
		const options = fakeQueryOptions.at(-1)!;
		expect(options.disallowedTools).toEqual(["ReportFindings"]);
		expect((options.env as Record<string, string>).CLAUDE_ENV_FILE).toMatch(/env\.sh$/);
		expect((options.env as Record<string, string>).PATH).toBe(process.env.PATH);
	});
});

test("Ask before edits: Claude Code's write waits in the tray, then runs once allowed; a denial reaches it", async () => {
	const a = await start();
	const folder = await project(a);
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: CLAUDE });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await a.client.call("sessions.configure", { ref, approvalMode: "ask" });
	await a.client.call("sessions.submit", { ref, input: { text: "write: out.txt | done\n$ rm -rf build" } });
	let waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval");
	expect(waiting.prompts![0]).toMatchObject({ kind: "approval", title: "Write out.txt", tool: "write", detail: join(folder, "out.txt") });
	expect(existsSync(join(folder, "out.txt"))).toBe(false);
	await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });

	waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval" && s.prompts![0]!.tool === "bash");
	expect(waiting.prompts![0]).toMatchObject({ title: "Run a command", detail: "rm -rf build", rule: { kind: "command", pattern: "rm" } });
	await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny", text: "not that" } });
	await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);

	expect(readFileSync(join(folder, "out.txt"), "utf8")).toBe("done");
	const snap: Snapshot = await a.client.call("sessions.open", { ref });
	const tools = snap.items.flatMap((i) => (i.kind === "tool" ? [i] : []));
	expect(tools.map((t) => [t.tool, t.status])).toEqual([
		["write", "done"],
		["bash", "error"],
	]);
	expect(tools[0]!.details).toMatchObject({ type: "diff", path: join(folder, "out.txt") });
	expect(tools[1]!.output).toBe("The user said no: not that");
});

test("Claude Code's questions are Piopio's questions", async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: CLAUDE });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await a.client.call("sessions.submit", { ref, input: { text: "ask: Which color? | Red | Blue" } });
	const waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval");
	expect(waiting.prompts![0]).toMatchObject({ kind: "question", title: "Which color?", options: ["Red", "Blue"] });
	await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { choice: "Blue" } });
	await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);
	const snap: Snapshot = await a.client.call("sessions.open", { ref });
	expect(snap.items.find((i) => i.kind === "tool")).toMatchObject({ status: "done", output: 'The user answered: {"Which color?":"Blue"}' });
});

describe("switching between Piopio's agent and Claude Code (docs/spec/31 CA7)", () => {
	const FAUX = { provider: "faux", id: "faux-1" };
	const said = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "user" ? [`you: ${i.text}`] : i.kind === "assistant" ? [`${i.model}: ${i.parts.map((p) => p.text).join("").slice(0, 40)}`] : i.kind === "system" ? [`— ${i.text}`] : []));

	test("mid-conversation, with a summary; back again; the earlier parts stay in the transcript, after a restart and a folder sync", { timeout: 30_000 }, async () => {
		const a = await start();
		const folder = await project(a);
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: FAUX });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref, input: { text: "first on pi" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);

		await a.client.call("sessions.configure", { ref, model: CLAUDE });
		await a.client.waitFor((n) => n.subscriptionId === sub && n.events.some((e) => e.type === "resnapshot" && e.snapshot.state.model?.provider === "claude-code"));
		await a.client.call("sessions.submit", { ref, input: { text: "now claude" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.model?.provider === "claude-code" && s.usage.outputTokens > 0);
		let snap: Snapshot = await a.client.call("sessions.open", { ref });
		expect(said(snap)).toEqual([
			"you: first on pi",
			expect.stringMatching(/^faux\/faux-1: Echo: first on pi/),
			"— Now running in Claude Code · it starts from a summary of the 2 messages above",
			"you: now claude",
			expect.stringMatching(/^claude-code\/opus: Echo: /),
		]);
		// The summary went with the first message, as a file you can see.
		const first = snap.items.find((i) => i.kind === "user" && i.text === "now claude");
		expect(first).toMatchObject({ attachments: [{ name: "Conversation so far.md", kind: "text" }] });
		const echoed = snap.items.at(-1)!;
		expect(echoed.kind === "assistant" && echoed.parts[0]!.text).toContain("User: first on pi");

		await a.client.call("sessions.configure", { ref, model: FAUX });
		await a.client.call("sessions.submit", { ref, input: { text: "back on pi" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.model?.provider === "faux" && s.usage.outputTokens > 0);
		snap = await a.client.call("sessions.open", { ref });
		expect(said(snap).filter((l) => l.startsWith("—"))).toEqual([
			"— Now running in Claude Code · it starts from a summary of the 2 messages above",
			"— Now running on Piopio's agent · it starts from a summary of the 4 messages above",
		]);
		expect(said(snap).at(-2)).toBe("you: back on pi");

		// One conversation, after a restart and a sync of the project's pi sessions.
		await stop(a);
		const b = await start(a.home);
		await b.client.call("projects.add", { path: folder });
		expect(said(await b.client.call("sessions.open", { ref }))).toEqual(said(snap));
		expect((await b.client.call("sessions.list", { kind: "build" })).sessions).toHaveLength(1);
	});

	test("switching back before sending anything is an undo: the earlier part goes on as it was", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: FAUX });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref, input: { text: "hello" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);
		const before = said(await a.client.call("sessions.open", { ref }));
		await a.client.call("sessions.configure", { ref, model: CLAUDE });
		expect(said(await a.client.call("sessions.open", { ref })).at(-1)).toMatch(/^— Now running in Claude Code/);
		await a.client.call("sessions.configure", { ref, model: FAUX });
		expect(said(await a.client.call("sessions.open", { ref }))).toEqual(before);
		await a.client.call("sessions.submit", { ref, input: { text: "again" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 5);
		const after: Snapshot = await a.client.call("sessions.open", { ref });
		expect(said(after).slice(-2)).toEqual(["you: again", expect.stringMatching(/Echo: again/)]);
		expect(after.items.some((i) => i.kind === "user" && i.attachments?.length)).toBe(false);
	});

	/** A chat that started in Claude Code and went on on Piopio's agent, and a branch of it from the last answer. */
	async function chatAndBranch(a: Ctx) {
		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: CLAUDE });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref, input: { text: "on claude code" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);
		await a.client.call("sessions.configure", { ref, model: FAUX });
		await a.client.call("sessions.submit", { ref, input: { text: "on pi" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.model?.provider === "faux" && s.usage.outputTokens > 0);
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		const { ref: branch } = await a.client.call("sessions.fork", { ref, itemId: snap.items.filter((i) => i.kind === "assistant").at(-1)!.id });
		return { ref, branch: branch as typeof ref, said: said(snap).filter((l) => !l.startsWith("—")) };
	}
	const transcript = async (a: Ctx, ref: unknown) => said(await a.client.call("sessions.open", { ref })).filter((l) => !l.startsWith("—"));

	for (const gone of ["branch", "original"] as const) {
		test(`a branch has its own earlier parts: deleting the ${gone} leaves the other whole, after a restart`, { timeout: 30_000 }, async () => {
			const a = await start();
			const { ref, branch, said: before } = await chatAndBranch(a);
			expect(before).toEqual(["you: on claude code", expect.stringMatching(/^claude-code\/opus: /), "you: on pi", expect.stringMatching(/^faux\/faux-1: /)]);
			const [deleted, kept] = gone === "branch" ? [branch, ref] : [ref, branch];
			await a.client.call("sessions.delete", { ref: deleted });
			await stop(a);
			const entries = JSON.parse(readFileSync(enginePaths(a.home).catalogIndex, "utf8")) as { ref: { id: string }; segments?: { agentFile?: string }[] }[];
			const part = entries.find((e) => e.ref.id === kept.id)!.segments![0]!;
			expect(part.agentFile && existsSync(part.agentFile)).toBe(true);
			// The branch's copy says what was said, without the original's Claude Code session.
			if (gone === "original") expect(JSON.parse(readFileSync(part.agentFile!, "utf8")).sessionId).toBeUndefined();
			const b = await start(a.home);
			expect(await transcript(b, kept)).toEqual(before);
		});

		test(`a branch made before 2026-11-22 shares the earlier parts: deleting the ${gone} keeps them for the other`, { timeout: 30_000 }, async () => {
			const a = await start();
			const { ref, branch, said: before } = await chatAndBranch(a);
			await stop(a);
			// What fork used to write: the branch pointing at the original's files.
			const catalog = enginePaths(a.home).catalogIndex;
			const entries = JSON.parse(readFileSync(catalog, "utf8")) as { ref: { id: string }; segments?: unknown }[];
			const original = entries.find((e) => e.ref.id === ref.id)!;
			const copy = entries.find((e) => e.ref.id === branch.id)!;
			copy.segments = original.segments;
			writeFileSync(catalog, JSON.stringify(entries));
			const b = await start(a.home);
			const [deleted, kept] = gone === "branch" ? [branch, ref] : [ref, branch];
			await b.client.call("sessions.delete", { ref: deleted });
			await stop(b);
			const c = await start(a.home);
			expect(await transcript(c, kept)).toEqual(before);
			// The last one to go takes them.
			await c.client.call("sessions.delete", { ref: kept });
		});
	}

	test("back in Claude Code after Piopio's agent: a new part of its own, the first one as it was", { timeout: 30_000 }, async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: CLAUDE });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		for (const [i, [model, text]] of ([[CLAUDE, "one"], [FAUX, "two"], [CLAUDE, "three"]] as const).entries()) {
			if (i) await a.client.call("sessions.configure", { ref, model });
			await a.client.call("sessions.submit", { ref, input: { text } });
			await stateWhere(a, sub, (s) => s.status === "idle" && s.model?.provider === model.provider && s.usage.outputTokens > 0);
			for (let tries = 0; (await transcript(a, ref)).at(-2) !== `you: ${text}`; tries++) {
				expect(tries).toBeLessThan(50);
				await new Promise((r) => setTimeout(r, 100));
			}
		}
		await stop(a);
		const b = await start(a.home);
		expect((await transcript(b, ref)).filter((l) => l.startsWith("you:"))).toEqual(["you: one", "you: two", "you: three"]);
	});

	test("an empty conversation just changes runner", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.configure", { ref, model: CLAUDE });
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		expect(snap.items).toEqual([]);
		expect(snap.state.model).toEqual(CLAUDE);
	});
});

describe("Piopio's tools in Claude Code (docs/spec/31 CA8)", () => {
	test("it searches your other conversations and shows a visual, through the piopio MCP server; the cards use Piopio's names", { timeout: 30_000 }, async () => {
		const a = await start();
		const other = await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } });
		const otherSub = (await a.client.call("sessions.subscribe", { ref: other.ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref: other.ref, input: { text: "pineapple pizza plans for Friday" } });
		await stateWhere(a, otherSub, (s) => s.status === "idle" && s.usage.outputTokens > 0);

		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: CLAUDE });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		const script = ['call: search_conversations | {"query":"pineapple"}', 'call: show_visual | {"title":"Plan","html":"<p>Friday</p>"}'].join("\n");
		await a.client.call("sessions.submit", { ref, input: { text: script } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);
		const tools = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "tool" ? [i] : []));
		expect(tools.map((t) => [t.tool, t.status])).toEqual([
			["search_conversations", "done"],
			["show_visual", "done"],
		]);
		expect(tools[0]!.output).toContain("pineapple pizza");
		expect(tools[1]!.output).toContain('Shown to the user as "Plan"');
	});

	test("a new thinking level starts Claude Code's session again with that effort, resumed", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: CLAUDE });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref, input: { text: "effort?" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens > 0);
		await a.client.call("sessions.configure", { ref, thinking: "high" });
		await a.client.call("sessions.submit", { ref, input: { text: "effort?" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.usage.outputTokens >= 10);
		const answers = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "assistant" ? [i.parts.map((p) => p.text).join("")] : []));
		expect(answers).toEqual(["Effort: default", "Effort: high"]);
		const stored = JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8"));
		expect(stored.sessionId).toMatch(/^fake-session-/);
	});
});

test("Claude Code's tools get Piopio's names and details; modes map to its permission modes", () => {
	expect(piopioTool("Read", { file_path: "/a/b.ts" })).toEqual({ name: "read", args: { file_path: "/a/b.ts", path: "/a/b.ts" } });
	expect(piopioTool("Bash", { command: "ls" }).name).toBe("bash");
	expect(piopioTool("TodoWrite", { todos: [{ content: "x", status: "completed" }] }).args.items).toEqual([{ text: "x", status: "done" }]);
	expect(piopioTool("mcp__github__list", {}).name).toBe("mcp__github__list");
	expect(editPatch({ old_string: "a\nb", new_string: "c" })).toBe("@@ -1,2 +1,1 @@\n-a\n-b\n+c");
	expect(["read_only", "ask", "auto_edit", "full_auto"].map((m) => permissionMode(m as never))).toEqual(["plan", "default", "acceptEdits", "bypassPermissions"]);
	expect(claudeBilling({ plan: "max", method: "claude.ai" })).toBe("Claude Max plan");
	expect(claudeBilling({ method: "api_key" })).toBe("Anthropic API via Claude Code");
});

test("detection reads claude --version and claude auth status", async () => {
	const runs: string[][] = [];
	const agent = new ClaudeCodeAgent({
		find: () => "/opt/claude",
		run: async (_path, args) => {
			runs.push(args);
			return args[0] === "--version" ? { stdout: "2.1.319 (Claude Code)\n", code: 0 } : { stdout: JSON.stringify({ loggedIn: false }), code: 1 };
		},
	});
	expect(await agent.status()).toEqual({ path: "/opt/claude", version: "2.1.319 (Claude Code)", signedIn: false, problem: "Claude Code is signed out. Run `claude` in Terminal to sign in." });
	expect(await agent.providerInfo()).toMatchObject({ status: "needs_attention", message: expect.stringContaining("signed out"), models: 0 });
	expect(await new ClaudeCodeAgent({ find: () => undefined }).providerInfo()).toMatchObject({ status: "not_connected", agent: { signedIn: false, install: expect.stringContaining("claude-code") } });
	expect(runs).toEqual([["--version"], ["auth", "status"]]);
});
