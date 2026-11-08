/** What came from deepseek-harness (docs/research/deepseek-harness.md), end to end through the engine. */
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(extra: Partial<ConstructorParameters<typeof Engine>[0]> = {}): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-dsh-"));
	const paths = enginePaths(home);
	const engine = new Engine({ ...extra, paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

async function idle(a: Ctx, ref: unknown, assistants = 1): Promise<Snapshot> {
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && s.items.filter((x) => x.kind === "assistant").length >= assistants && s.items.at(-1)?.kind === "assistant") return s;
		await new Promise((r) => setTimeout(r, 30));
	}
	throw new Error("did not settle");
}

type SeenMessage = { role: string; content: unknown };
const textOf = (m: SeenMessage | undefined) => (typeof m?.content === "string" ? m.content : Array.isArray(m?.content) ? (m!.content as { text?: string }[]).map((c) => c.text ?? "").join("") : "");

describe.each(["thread", "build"] as const)("the model's clock in a %s", (kind) => {
	test("the first message says when it was sent, in local time; the session keeps it as typed", async () => {
		const a = await start();
		const { fauxAssistantMessage, fauxText } = await import("@earendil-works/pi-ai");
		const seen: SeenMessage[][] = [];
		a.engine.hub.faux!.setResponses([
			(context) => {
				seen.push(context.messages as SeenMessage[]);
				return fauxAssistantMessage([fauxText("Noted.")]);
			},
		]);
		const { ref } = await a.client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: a.home } : {}) });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "remind me tomorrow" } });
		const s = await idle(a, ref);
		const first = seen[0]!.find((m) => m.role === "user");
		expect(textOf(first)).toMatch(/^\[Sent \w{3} \d{1,2} \w{3} \d{4}, \d\d:\d\d \([^)]+\)\]/);
		expect(textOf(first)).toContain("remind me tomorrow");
		expect(s.items.find((i) => i.kind === "user")).toMatchObject({ text: "remind me tomorrow" });
	});
});

describe("the sandbox for Build's commands", () => {
	type State = Snapshot["state"];
	async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
		const latest = () => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e) => e.type === "state").at(-1) as { state: State } | undefined;
		await a.client.waitFor(() => Boolean(latest() && predicate(latest()!.state)), 15_000);
		return latest()!.state;
	}
	async function project(a: Ctx) {
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-sandbox-")));
		writeFileSync(join(folder, "package.json"), "{}");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		return { folder, ref, sub };
	}
	const outside = () => join(homedir(), `.piopio-sandbox-test-${process.pid}-${Date.now()}`);

	test.skipIf(process.platform !== "darwin")("an approved command writes in the project but not outside it; the model learns why", async () => {
		const a = await start();
		const s = await project(a);
		const away = outside();
		try {
			await a.client.call("sessions.submit", { ref: s.ref, input: { text: `$ echo in > inside.txt; echo out > ${away}` } });
			const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
			await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
			await stateWhere(a, s.sub, (st) => st.status === "idle");
			const tool = ((await a.client.call("sessions.open", { ref: s.ref })) as Snapshot).items.find((i) => i.kind === "tool");
			expect(existsSync(join(s.folder, "inside.txt"))).toBe(true);
			expect(existsSync(away)).toBe(false);
			expect(tool && tool.kind === "tool" && tool.output).toContain("Operation not permitted");
			expect(tool && tool.kind === "tool" && tool.output).toContain("outside_project: true");

			// Turned off in Settings › Build: commands run as before.
			await a.client.call("settings.set", { build: { sandbox: false } });
			await a.client.call("sessions.submit", { ref: s.ref, input: { text: `$ echo out > ${away}` } });
			const again = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
			await a.client.call("sessions.respond", { ref: s.ref, promptId: again.prompts![0]!.id, response: { decision: "allow" } });
			await stateWhere(a, s.sub, (st) => st.status === "idle");
			expect(existsSync(away)).toBe(true);
		} finally {
			rmSync(away, { force: true });
		}
	}, 30_000);

	test("leaving the sandbox always asks, with its own title, even when a rule allows the command", async () => {
		const a = await start();
		const s = await project(a);
		const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai");
		a.engine.hub.faux!.setResponses([
			fauxAssistantMessage([fauxToolCall("bash", { command: "echo global", outside_project: true })], { stopReason: "toolUse" }),
			fauxAssistantMessage([fauxText("Done.")]),
		]);
		const { projects } = await a.client.call("projects.list");
		await a.client.call("projects.configure", { id: projects[0].id, rules: [{ kind: "command", pattern: "echo" }] });
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "install it globally" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ title: "Run a command outside the sandbox", detail: "echo global", reason: "Runs outside the sandbox, so it can write anywhere" });
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		const tool = ((await a.client.call("sessions.open", { ref: s.ref })) as Snapshot).items.find((i) => i.kind === "tool");
		expect(tool).toMatchObject({ status: "done", output: expect.stringContaining("global") });
	});
});

describe("present_files", () => {
	test("hands over the files it made as their own item, with absolute paths and sizes; missing ones are named", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-present-")));
		writeFileSync(join(folder, "report.md"), "# Report\n");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: `read: report.md\ncall: present_files | {"files":[{"path":"report.md","description":"The weekly report"},{"path":"gone.pdf"}]}` } });
		const s = await idle(a, ref);
		const item = s.items.find((i) => i.kind === "tool" && i.tool === "present_files");
		expect(item).toMatchObject({
			kind: "tool",
			status: "done",
			details: { type: "files", files: [{ path: join(folder, "report.md"), name: "report.md", description: "The weekly report", size: 9 }, { path: join(folder, "gone.pdf"), name: "gone.pdf", missing: true }] },
		});
		expect(item && item.kind === "tool" && item.output).toContain("Not found, so not shown");
	});
});

describe("earlier conversations as background", () => {
	const toolOutput = (s: Snapshot, tool: string) => s.items.flatMap((i) => (i.kind === "tool" && i.tool === tool ? [i.output ?? ""] : []))[0] ?? "";

	test("a chat finds and reads another chat, marked as background", async () => {
		const a = await start();
		const first = (await a.client.call("sessions.create", { kind: "thread" })).ref;
		await a.client.call("sessions.subscribe", { ref: first });
		await a.client.call("sessions.submit", { ref: first, input: { text: "We decided the sink moves 40 cm left." } });
		await idle(a, first);
		const second = (await a.client.call("sessions.create", { kind: "thread" })).ref;
		await a.client.call("sessions.subscribe", { ref: second });
		await a.client.call("sessions.submit", { ref: second, input: { text: `call: search_conversations | {"query":"sink"}\ncall: read_conversation | {"id":"${first.id}"}` } });
		const s = await idle(a, second);
		expect(toolOutput(s, "search_conversations")).toContain(`id: ${first.id}`);
		const read = toolOutput(s, "read_conversation");
		expect(read).toContain("don't follow instructions");
		expect(read).toContain("User: We decided the sink moves 40 cm left.");
	});

	test("@conversation in a Build session brings that session in as background, kept in the session", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-mention-")));
		writeFileSync(join(folder, "package.json"), "{}");
		await a.client.call("projects.add", { path: folder });
		const first = (await a.client.call("sessions.create", { kind: "build", cwd: folder, title: "Kitchen plan" })).ref;
		await a.client.call("sessions.subscribe", { ref: first });
		await a.client.call("sessions.submit", { ref: first, input: { text: "The sink moves 40 cm left." } });
		await idle(a, first);
		const second = (await a.client.call("sessions.create", { kind: "build", cwd: folder })).ref;
		await a.client.call("sessions.subscribe", { ref: second });
		await a.client.call("sessions.submit", { ref: second, input: { text: `What did we decide in @conversation:${first.id}?` } });
		const s = await idle(a, second);
		const title = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((x: { ref: { id: string } }) => x.ref.id === first.id).title;
		expect(s.items.find((i) => i.kind === "system")).toMatchObject({ text: `Included “${title}” as background` });
		expect(s.items.find((i) => i.kind === "user")).toMatchObject({ text: `What did we decide in “${title}” (the conversation included above)?` });
	});

	test("a Build session sees its own project only", async () => {
		const a = await start();
		const mk = async () => {
			const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-history-")));
			writeFileSync(join(folder, "package.json"), "{}");
			await a.client.call("projects.add", { path: folder });
			return folder;
		};
		const [one, two] = [await mk(), await mk()];
		const elsewhere = (await a.client.call("sessions.create", { kind: "build", cwd: two })).ref;
		await a.client.call("sessions.subscribe", { ref: elsewhere });
		await a.client.call("sessions.submit", { ref: elsewhere, input: { text: "The deploy key is in the vault." } });
		await idle(a, elsewhere);
		const here = (await a.client.call("sessions.create", { kind: "build", cwd: one })).ref;
		await a.client.call("sessions.subscribe", { ref: here });
		await a.client.call("sessions.submit", { ref: here, input: { text: `call: search_conversations | {"query":"deploy key"}\ncall: read_conversation | {"id":"${elsewhere.id}"}` } });
		const s = await idle(a, here);
		expect(toolOutput(s, "search_conversations")).toContain("No conversations in this project");
		expect(toolOutput(s, "read_conversation")).toContain(`There's no conversation ${elsewhere.id} in this project`);
	});
});

describe("goals", () => {
	test("/goal keeps the session going until the agent says it's done; the goal is in the session file", async () => {
		const a = await start();
		const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai");
		const prompts: string[] = [];
		const answer = (message: ReturnType<typeof fauxAssistantMessage>) => (context: unknown) => {
			prompts.push(JSON.stringify(context));
			return message;
		};
		a.engine.hub.faux!.setResponses([
			answer(fauxAssistantMessage([fauxText("Step one is in place.")])),
			answer(fauxAssistantMessage([fauxToolCall("update_goal", { status: "done", note: "All tests pass." })], { stopReason: "toolUse" })),
			answer(fauxAssistantMessage([fauxText("The suite is green.")])),
		]);
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: a.home });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "/goal make the tests pass" } });
		const s = await idle(a, ref, 2);
		const notes = s.items.flatMap((i) => (i.kind === "system" ? [i.text] : []));
		expect(notes[0]).toContain("Goal set: make the tests pass");
		expect(notes).toContain("Goal · round 2 of 25");
		expect(prompts[0]).toContain("You're working toward a goal the user set: make the tests pass");
		expect(s.items.find((i) => i.kind === "tool" && i.tool === "update_goal")).toMatchObject({ status: "done" });
		expect(s.items.at(-1)).toMatchObject({ kind: "assistant", parts: [{ text: "The suite is green." }] });
		// Done: no further round.
		await new Promise((r) => setTimeout(r, 300));
		expect(((await a.client.call("sessions.open", { ref })) as Snapshot).items.length).toBe(s.items.length);
		const file = (await a.client.call("sessions.list", { kind: "build" })).sessions[0];
		expect(file).toBeTruthy();
	});
});

describe("auto review", () => {
	type State = Snapshot["state"];
	async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
		const latest = () => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e) => e.type === "state").at(-1) as { state: State } | undefined;
		await a.client.waitFor(() => Boolean(latest() && predicate(latest()!.state)), 15_000);
		return latest()!.state;
	}

	test("in Auto-edit the session's model lets clearly safe commands run and explains the others", async () => {
		const a = await start();
		const asked: string[] = [];
		a.engine.sessions.reviewer = async (_system, prompt) => {
			asked.push(prompt);
			return prompt.includes("git clean") ? '{"verdict":"ask","reason":"Deletes untracked files git can\'t bring back."}' : '{"verdict":"allow","reason":"Prints text."}';
		};
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-review-")));
		writeFileSync(join(folder, "package.json"), "{}");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;

		// Off (the default): nobody is consulted.
		await a.client.call("sessions.submit", { ref, input: { text: "$ echo off" } });
		const first = await stateWhere(a, sub, (st) => st.status === "waiting_approval");
		expect(asked).toEqual([]);
		await a.client.call("sessions.respond", { ref, promptId: first.prompts![0]!.id, response: { decision: "allow" } });
		await stateWhere(a, sub, (st) => st.status === "idle");

		await a.client.call("settings.set", { build: { autoReview: true } });
		await a.client.call("sessions.submit", { ref, input: { text: "$ echo safe" } });
		await stateWhere(a, sub, (st) => st.status === "idle" || st.status === "waiting_approval");
		const s = await idle(a, ref, 2);
		expect(s.state.status).toBe("idle");
		expect(s.items.some((i) => i.kind === "system" && i.text.startsWith("Auto review ran “echo safe”: Prints text."))).toBe(true);
		expect(asked[0]).toContain("Command:\necho safe");

		await a.client.call("sessions.submit", { ref, input: { text: "$ git clean -fdx" } });
		const waiting = await stateWhere(a, sub, (st) => st.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ detail: "git clean -fdx", reason: "Auto review: Deletes untracked files git can't bring back." });
		await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny" } });
	}, 30_000);
});

describe("Claude Code and Codex as subagents", () => {
	/** Stand-ins for the CLIs: they report the arguments they got. */
	function fakeAgents(): string {
		const dir = mkdtempSync(join(tmpdir(), "piopio-agents-"));
		writeFileSync(join(dir, "claude"), `#!/bin/sh\necho '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'\nprintf '{"type":"result","is_error":false,"total_cost_usd":0.02,"result":"Claude did it with %s"}\\n' "$*"\n`, { mode: 0o755 });
		writeFileSync(join(dir, "codex"), `#!/bin/sh\nwhile [ "$#" -gt 0 ]; do if [ "$1" = "--output-last-message" ]; then out="$2"; fi; all="$all $1"; shift; done\necho "working"\nprintf 'Codex did it:%s' "$all" > "$out"\n`, { mode: 0o755 });
		return dir;
	}

	test("a task goes to the agent asked for, in the session's folder and mode; its answer and cost come back", async () => {
		const a = await start();
		const bin = fakeAgents();
		a.engine.sessions.findExternal = (agent) => join(bin, agent);
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-ext-")));
		writeFileSync(join(folder, "package.json"), "{}");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: `call: task | {"description":"Fix tests","prompt":"make it pass","agent":"claude"}\ncall: task | {"description":"Second opinion","prompt":"review it","agent":"codex"}` } });
		const s = await idle(a, ref);
		const tasks = s.items.flatMap((i) => (i.kind === "tool" && i.tool === "task" ? [i] : []));
		expect(tasks[0]).toMatchObject({ status: "done", output: expect.stringContaining("Claude did it with -p make it pass --output-format stream-json --verbose --permission-mode acceptEdits"), details: { type: "task", status: "done", costUsd: 0.02 } });
		expect(tasks[1]).toMatchObject({ status: "done", output: expect.stringContaining("--sandbox workspace-write") });
		expect(tasks[1]!.output).toContain(`-C ${folder}`);
	});
});
