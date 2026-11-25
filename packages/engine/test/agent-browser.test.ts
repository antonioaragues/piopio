import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import type { Snapshot } from "@piopio/protocol";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// An agent's browser (docs/spec/22 W3): a row in its Setup, its own profile, and acting on a site asks the owner the
// way its other approvals do (its chat, Needs you), unless its Setup allows that site.

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-agent-browser-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
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

async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 15_000): Promise<T> {
	const end = Date.now() + timeout;
	for (;;) {
		const value = await read();
		if (ready(value)) return value;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
		await new Promise((r) => setTimeout(r, 150));
	}
}

type Item = Snapshot["items"][number];
const approvals = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "approval" }> => i.kind === "approval");
const tools = (items: Item[]) => items.flatMap((i) => (i.kind === "steps" ? i.tools : []));
const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;

test("an agent browses in its own profile; acting asks the owner per site, Always allow remembers it, its Setup's sites don't ask", async () => {
	const a = await start();
	const paths = enginePaths(a.home);
	const app = await TestClient.connect(paths.socket);
	await app.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "fake app", protocolVersion: "1.0", services: ["app.tool", "browser"] });
	let site = "example.com";
	const calls: any[] = [];
	app.appTool = (p) => {
		calls.push(p);
		if (p.name === "browser_open") return { ok: true, output: `Example · https://${site}/\n[e3] button "Go" @(10,10)` };
		if (!(p.sites ?? []).includes(site)) return { ok: false, output: "", needsSite: site };
		return { ok: true, output: `Clicked ${p.args.ref} on ${site}.` };
	};

	const { ref } = await a.client.call("agents.create", { name: "Scout", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const got = await a.client.call("agents.get", { ref });
	const def = got.definition as Record<string, any>;
	const save = async (browser?: object) => expect(await a.client.call("agents.save", { ref, definition: { ...def, tools: { ...def.tools, ...(browser ? { browser } : {}) } }, instructions: got.instructions })).toEqual({ saved: true, errors: [] });
	const owner = () => a.client.call("sessions.open", { ref }).then((s: Snapshot) => s.items);
	const finished = (n: number) => until(owner, (xs) => tools(xs).filter((t) => t.status === "done" || t.status === "error").length >= n);

	// Off (a new agent): no browser tools.
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_open", { url: "https://example.com/" }) } });
	expect(tools(await finished(1))[0]).toMatchObject({ status: "error" });
	expect(calls).toEqual([]);

	// Asks: reading runs, in the agent's own profile and under its ref.
	await save({ use: "asks" });
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_open", { url: "https://example.com/" }) } });
	expect(tools(await finished(2))[1]).toMatchObject({ tool: "browser_open", status: "done" });
	expect(calls[0]).toMatchObject({ name: "browser_open", ref: { kind: "agent", id: ref.id }, groups: ["browser"], profile: `agent:${ref.id}` });

	// The first click on a site is an approval for the owner, in its chat and in Needs you.
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	let items = await until(owner, (xs) => approvals(xs).some((x) => x.status === "pending"));
	const asked = approvals(items).find((x) => x.status === "pending")!;
	expect(asked).toMatchObject({ tool: "browser_site", title: "Click and type on example.com", always: "Always allow example.com" });
	expect((await until(() => a.client.call("inbox.list", {}), (b) => b.count === 1)).items[0]).toMatchObject({ kind: "approval", needsYou: true, approval: { approvalId: asked.approvalId } });
	await a.client.call("agents.decide", { ref, approvalId: asked.approvalId, approve: true, always: true });
	expect(tools(await finished(3))[2]).toMatchObject({ tool: "browser_click", status: "done", output: "Clicked e3 on example.com." });

	// Remembered: the next click there doesn't ask, and nothing reached your sites in Settings › Browser.
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	items = await finished(4);
	expect(tools(items)[3]).toMatchObject({ status: "done" });
	expect(approvals(items).filter((x) => x.status === "pending")).toEqual([]);
	expect((await a.client.call("browser.sites", {})).sites).toEqual([]);

	// Denied on another site: the model is told not to try another way.
	site = "shop.example";
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	items = await until(owner, (xs) => approvals(xs).some((x) => x.status === "pending"));
	await a.client.call("agents.decide", { ref, approvalId: approvals(items).find((x) => x.status === "pending")!.approvalId, approve: false, reason: "not that shop" });
	expect(tools(await finished(5))[4]).toMatchObject({ status: "error", output: expect.stringContaining("didn't let Piopio act on shop.example (not that shop)") });

	// Allowed with its sites: those never ask; a site blocked in Settings › Browser is refused all the same.
	await save({ use: "allowed", sites: ["shop.example"], profile: "yours" });
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	expect(tools(await finished(6))[5]).toMatchObject({ status: "done", output: "Clicked e3 on shop.example." });
	expect(calls.at(-1).profile).toBeUndefined();
	await a.client.call("browser.setSite", { site: "shop.example", level: "blocked" });
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	expect(tools(await finished(7))[6]).toMatchObject({ status: "error", output: expect.stringContaining("blocked in Settings") });
	app.close();
}, 60_000);

// Re-audit 2026-11-25 V4: "Allow once" was recorded for the agent in your conversations' list, so every later call of
// that agent, from any contact or run, acted on the site without asking until the engine restarted.
test("an agent's Allow once covers that call only; your sites in Settings › Browser are untouched", async () => {
	const a = await start();
	const paths = enginePaths(a.home);
	const app = await TestClient.connect(paths.socket);
	await app.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "fake app", protocolVersion: "1.0", services: ["app.tool", "browser"] });
	app.appTool = (p) => ((p.sites ?? []).includes("example.com") ? { ok: true, output: `Clicked ${p.args.ref}.` } : { ok: false, output: "", needsSite: "example.com" });
	const { ref } = await a.client.call("agents.create", { name: "Scout", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const got = await a.client.call("agents.get", { ref });
	const def = got.definition as Record<string, any>;
	await a.client.call("agents.save", { ref, definition: { ...def, tools: { ...def.tools, browser: { use: "asks" } } }, instructions: got.instructions });
	const owner = () => a.client.call("sessions.open", { ref }).then((s: Snapshot) => s.items);
	const pending = () => until(owner, (xs) => approvals(xs).some((x) => x.status === "pending")).then((xs) => approvals(xs).find((x) => x.status === "pending")!);
	const finished = (n: number) => until(owner, (xs) => tools(xs).filter((t) => t.status === "done" || t.status === "error").length >= n);

	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e3" }) } });
	await a.client.call("agents.decide", { ref, approvalId: (await pending()).approvalId, approve: true });
	expect(tools(await finished(1))[0]).toMatchObject({ status: "done" });
	// The next click asks again.
	await a.client.call("sessions.submit", { ref, input: { text: call("browser_click", { ref: "e4" }) } });
	const again = await pending();
	expect(again).toMatchObject({ tool: "browser_site", title: "Click and type on example.com" });
	await a.client.call("agents.decide", { ref, approvalId: again.approvalId, approve: true });
	expect(tools(await finished(2))[1]).toMatchObject({ status: "done", output: "Clicked e4." });
	expect((await a.client.call("browser.sites", {})).sites).toEqual([]);
	app.close();
}, 60_000);
