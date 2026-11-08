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
