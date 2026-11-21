/** Background commands in a Build session (docs/spec/05-build §9 TM4, roadmap PAR2), with the scripted model. */
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEvent, Snapshot } from "@piopio/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { decide } from "@piopio/pi-extensions";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-bg-")), app?: (params: any) => any): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	if (app) client.appTool = app;
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set", ...(app ? ["app.tool", "browser"] : [])] });
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

type State = Snapshot["state"];
const states = (a: Ctx, sub: string) => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e): e is Extract<SessionEvent, { type: "state" }> => e.type === "state");
async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
	await a.client.waitFor(() => Boolean(states(a, sub).at(-1) && predicate(states(a, sub).at(-1)!.state)), 20_000);
	return states(a, sub).at(-1)!.state;
}

async function session(a: Ctx, mode: string) {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-bg-project-")));
	writeFileSync(join(folder, "package.json"), "{}");
	await a.client.call("projects.add", { path: folder });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await a.client.call("sessions.configure", { ref, approvalMode: mode });
	return { ref, sub, folder };
}

const SERVER = `node -e "console.log('Local: http://localhost:4321/'); setInterval(() => console.log('request'), 200)"`;
const call = (tool: string, args: unknown) => `call: ${tool} | ${JSON.stringify(args)}`;

test("a dev server keeps running: its address and output reach the agent and the app; process_stop stops it", { timeout: 40_000 }, async () => {
	const a = await start();
	const { ref, sub } = await session(a, "full_auto");
	await a.client.call("sessions.submit", { ref, input: { text: call("bash", { command: SERVER, background: true, description: "Starting the dev server" }) } });
	const running = await stateWhere(a, sub, (s) => s.status === "idle" && (s.processes?.length ?? 0) > 0);
	expect(running.processes).toMatchObject([{ id: "p1", command: SERVER, status: "running", urls: ["http://localhost:4321/"], description: "Starting the dev server" }]);
	let snap: Snapshot = await a.client.call("sessions.open", { ref });
	const card = snap.items.find((i) => i.kind === "tool");
	expect(card).toMatchObject({ tool: "bash", status: "done" });
	expect(card?.kind === "tool" && card.output).toContain("Started in the background as p1");
	expect(card?.kind === "tool" && card.output).toContain("It's serving http://localhost:4321/");

	// The app reads it from the start; the agent reads what's new.
	await new Promise((r) => setTimeout(r, 500));
	const out = await a.client.call("sessions.processOutput", { ref, id: "p1" });
	expect(out.text).toContain("Local: http://localhost:4321/");
	expect(out.text).toContain("request");
	await a.client.call("sessions.submit", { ref, input: { text: call("process_output", { id: "p1" }) } });
	await stateWhere(a, sub, (s) => s.status === "idle" && (s.usage.outputTokens ?? 0) >= 0 && states(a, sub).length > 3);
	await a.client.call("sessions.submit", { ref, input: { text: call("process_stop", { id: "p1" }) } });
	const stopped = await stateWhere(a, sub, (s) => s.status === "idle" && s.processes?.[0]?.status === "stopped");
	expect(stopped.processes![0]).toMatchObject({ id: "p1", status: "stopped" });
	snap = await a.client.call("sessions.open", { ref });
	const tools = snap.items.flatMap((i) => (i.kind === "tool" ? [[i.tool, i.status, (i.output ?? "").split("\n")[0]]] : []));
	expect(tools.slice(1)).toEqual([
		["process_output", "done", expect.stringMatching(/^p1 · running · /)],
		["process_stop", "done", expect.stringMatching(/^Stopped: p1 · stopped/)],
	]);
});

test("in Auto-edit it asks first, as a background command; the app can stop it", { timeout: 40_000 }, async () => {
	const a = await start();
	const { ref, sub } = await session(a, "auto_edit");
	await a.client.call("sessions.submit", { ref, input: { text: call("bash", { command: SERVER, background: true }) } });
	const waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval");
	expect(waiting.prompts![0]).toMatchObject({ title: "Start a command in the background", detail: SERVER });
	await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
	await stateWhere(a, sub, (s) => s.status === "idle" && s.processes?.[0]?.status === "running");
	const { process } = await a.client.call("sessions.processStop", { ref, id: "p1" });
	expect(process.status).toBe("stopped");
	await stateWhere(a, sub, (s) => s.processes?.[0]?.status === "stopped");
});

test("closing the session stops what it left running", { timeout: 40_000 }, async () => {
	const a = await start();
	const { ref, sub, folder } = await session(a, "full_auto");
	// Writes a line every 100 ms while it lives.
	const ticker = `node -e "setInterval(() => require('fs').appendFileSync('ticks.txt', 'x'), 100)"`;
	await a.client.call("sessions.submit", { ref, input: { text: call("bash", { command: ticker, background: true }) } });
	await stateWhere(a, sub, (s) => s.status === "idle" && s.processes?.[0]?.status === "running");
	await new Promise((r) => setTimeout(r, 400));
	await a.client.call("sessions.delete", { ref });
	const size = () => {
		try {
			return readFileSync(join(folder, "ticks.txt"), "utf8").length;
		} catch {
			return 0;
		}
	};
	const before = size();
	expect(before).toBeGreaterThan(0);
	await new Promise((r) => setTimeout(r, 500));
	expect(size()).toBe(before);
});

describe("the project preview (docs/spec/22 §6, roadmap PAR3)", () => {
	test("the dev server's address opens as the preview, with the project's profile; other local addresses ask", { timeout: 40_000 }, async () => {
		const calls: any[] = [];
		const a = await start(undefined, (p) => {
			calls.push(p);
			return { ok: true, output: `did ${p.name}` };
		});
		const { ref, sub, folder } = await session(a, "full_auto");
		await a.client.call("sessions.submit", { ref, input: { text: call("bash", { command: SERVER, background: true }) } });
		await stateWhere(a, sub, (s) => s.status === "idle" && s.processes?.[0]?.urls.length === 1);
		await a.client.call("sessions.submit", { ref, input: { text: [call("browser_open", { url: "http://localhost:4321/" }), call("browser_console", {}), call("browser_open", { url: "http://localhost:9999/" })].join("\n") } });
		const waiting = await stateWhere(a, sub, (s) => s.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ kind: "approval", title: "Let Piopio open localhost:9999, a local address" });
		await a.client.call("sessions.respond", { ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny" } });
		await stateWhere(a, sub, (s) => s.status === "idle" && !s.prompts?.length && states(a, sub).length > 8);
		expect(calls.map((c) => [c.name, c.args.url ?? "", c.preview?.profile, c.preview?.local?.includes("localhost:4321")])).toEqual([
			["browser_open", "http://localhost:4321/", folder, true],
			["browser_console", "", folder, true],
		]);
		const tools = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "tool" ? [[i.tool, i.status, (i.output ?? "").split("\n")[0]]] : []));
		expect(tools.slice(1)).toEqual([
			["browser_open", "done", "did browser_open"],
			["browser_console", "done", "did browser_console"],
			["browser_open", "error", "The user didn't let Piopio open localhost:9999."],
		]);
	});

	test("a chat has no preview tools", { timeout: 20_000 }, async () => {
		const a = await start(undefined, (p) => ({ ok: true, output: `did ${p.name}` }));
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
		await a.client.call("sessions.submit", { ref, input: { text: call("browser_console", {}) } });
		await stateWhere(a, sub, (s) => s.status === "idle" && states(a, sub).length > 2);
		const tool = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.find((i) => i.kind === "tool");
		expect(tool).toMatchObject({ tool: "browser_console", status: "error" });
	});

	test("reading the preview is allowed in every mode; a script asks unless Full auto", () => {
		expect(decide("read_only", "browser_console", {}, "/p", []).action).toBe("allow");
		expect(decide("read_only", "browser_requests", {}, "/p", []).action).toBe("allow");
		expect(decide("auto_edit", "browser_eval", { script: "return 1" }, "/p", [])).toEqual({ action: "ask", rule: { kind: "tool", pattern: "browser_eval" } });
		expect(decide("full_auto", "browser_eval", { script: "return 1" }, "/p", []).action).toBe("allow");
	});
});
