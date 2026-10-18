import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEvent, Snapshot } from "@piopio/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { titleFrom } from "../src/sessions.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-test-")), faux = true): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
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

const settled = (subscriptionId: string, after = 0) => (n: { subscriptionId: string; seq: number; events: SessionEvent[] }) =>
	n.subscriptionId === subscriptionId && n.seq > after && n.events.some((e) => e.type === "state" && e.state.status === "idle");

const texts = (s: Snapshot) => s.items.map((i) => [i.kind, i.kind === "user" ? i.text : i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : ""]);

describe.each(["thread", "build"] as const)("%s session", (kind) => {
	test("streams an answer and keeps ids stable across an engine restart", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: a.home } : {}) });
		const sub = await a.client.call("sessions.subscribe", { ref });
		expect(sub.snapshot.items).toEqual([]);

		const res = await a.client.call("sessions.submit", { ref, input: { text: "hello piopio" } });
		expect(res).toEqual({ accepted: true, disposition: "started" });
		await a.client.waitFor(settled(sub.subscriptionId, 1));

		const events = a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).flatMap((n) => n.events);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "user")).toBe(true);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "assistant")).toBe(true);

		const live: Snapshot = await a.client.call("sessions.open", { ref });
		expect(texts(live)).toEqual([
			["user", "hello piopio"],
			["assistant", "Echo: hello piopio"],
		]);
		expect(live.state.status).toBe("idle");
		const [list] = (await a.client.call("sessions.list")).sessions;
		expect(list.title).toBe("hello piopio");

		await stop(a);
		const b = await start(a.home);
		const reopened: Snapshot = await b.client.call("sessions.open", { ref });
		expect(reopened.items.map((i) => i.id)).toEqual(live.items.map((i) => i.id));
		expect(texts(reopened)).toEqual(texts(live));
	});

	test("queues a follow-up sent while busy", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: a.home } : {}) });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "first message that takes a little while to echo back" } });
		await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.status === "running"));
		const second = await a.client.call("sessions.submit", { ref, input: { text: "second" } });
		expect(second.disposition).toBe("queued");
		await a.client.waitFor((n) => {
			if (n.subscriptionId !== sub.subscriptionId) return false;
			return n.events.some((e) => (e.type === "item.updated" || e.type === "item.replaced" || e.type === "item.added") && e.item.kind === "assistant" && e.item.status === "done" && e.item.parts.some((p) => p.text === "Echo: second"));
		});
	});
});

test("asks the client for the OpenRouter key and reports AUTH when it has none", async () => {
	const a = await start(undefined, false);
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
});

test("rejects bad params and unauthenticated calls", async () => {
	const a = await start();
	await expect(a.client.call("sessions.create", { kind: "nope" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	const other = await TestClient.connect(enginePaths(a.home).socket);
	await expect(other.call("sessions.list")).rejects.toMatchObject({ data: { code: "AUTH" } });
	await expect(other.call("engine.hello", { token: "wrong", client: "x", protocolVersion: "1.0" })).rejects.toMatchObject({ data: { code: "AUTH" } });
	other.close();
});

test("configure, rename and delete a thread, with catalog notifications", async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	const sub = await a.client.call("sessions.subscribe", { ref });
	expect(sub.snapshot.state.model).toEqual({ provider: "faux", id: "faux-1" });

	const { models, defaultModel } = await a.client.call("models.list", {});
	expect(defaultModel).toEqual({ provider: "faux", id: "faux-1" });
	expect(models.some((m: { provider: string }) => m.provider === "openrouter")).toBe(true);
	const other = models.find((m: { provider: string; id: string }) => m.provider === "openrouter" && m.id === "anthropic/claude-haiku-5.5");
	expect(other).toMatchObject({ supports: { reasoning: true }, pricing: { input: expect.any(Number) } });

	await a.client.call("sessions.configure", { ref, model: { provider: "openrouter", id: other.id }, thinking: "low" });
	const opened: Snapshot = await a.client.call("sessions.open", { ref });
	expect(opened.state.model).toEqual({ provider: "openrouter", id: other.id });
	expect(opened.state.thinking).toBe("low");
	await expect(a.client.call("sessions.configure", { ref, model: { provider: "openrouter", id: "nope/nope" } })).rejects.toMatchObject({ data: { code: "INVALID" } });

	await a.client.call("sessions.rename", { ref, title: "Renamed" });
	expect(a.client.notifications.some((n) => n.method === "catalog.changed" && n.params.upserted.some((s: { title: string }) => s.title === "Renamed"))).toBe(true);

	await a.client.call("sessions.delete", { ref });
	expect((await a.client.call("sessions.list")).sessions).toEqual([]);
	expect(existsSync(join(a.home, "threads", `${ref.id}.sqlite`))).toBe(false);
	expect(a.client.notifications.some((n) => n.method === "catalog.changed" && n.params.removed.some((r: { id: string }) => r.id === ref.id))).toBe(true);
});

test("secrets.changed makes the engine ask for the key again", async () => {
	const a = await start(undefined, false);
	let asked = 0;
	a.client.secrets = new Proxy({}, { get: () => (asked++, "") }) as Record<string, string>;
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
	await a.client.call("secrets.changed", { name: "provider.openrouter.apiKey" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
	expect(asked).toBeGreaterThanOrEqual(2);
});

test("titles are plain text", () => {
	expect(titleFrom("Here is **bold**, `code` and a [link](https://example.com).\n\n- one")).toBe("Here is bold, code and a link. - one");
	expect(titleFrom("```ts\nconst a = 1\n```\nWhy?")).toBe("Why?");
	expect(titleFrom("Explain this:\n\n| Col | Val |\n|---|---|\n| x | 1 |")).toBe("Explain this:");
	expect(titleFrom("a ".repeat(50)).length).toBeLessThanOrEqual(61);
});
