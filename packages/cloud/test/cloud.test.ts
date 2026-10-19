/**
 * Spike S4: the built Worker bundle in Miniflare (workerd), with pi-ai's faux echo model.
 * Covers the WS flow, reconnect snapshots, hibernation + wake, and alarm-driven resume after eviction.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { SessionEvent, SessionEventsNotification, Snapshot } from "@piopio/protocol";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { WsClient } from "./client.js";

const TOKEN = "test-owner-token";
const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

let mf: Miniflare;
let base: URL;
const clients: WsClient[] = [];

beforeAll(async () => {
	// Miniflare 5 (beta, what wrangler 4.151 ships) takes a new config shape; the v4 options convert.
	mf = new Miniflare(
		convertV4MiniflareOptions({
			name: config.name,
			modules: true,
			scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
			compatibilityDate: config.compatibility_date,
			compatibilityFlags: config.compatibility_flags,
			durableObjects: { AGENT: { className: "AgentDO", useSQLite: true } },
			bindings: { OWNER_TOKEN: TOKEN, PIOPIO_FAUX_MODEL: "1", PIOPIO_FAUX_TPS: "100", PIOPIO_TEST_HOOKS: "1" },
		}),
	);
	base = await mf.ready;
});

afterAll(async () => {
	for (const c of clients) c.close();
	await mf?.dispose();
});

const wsUrl = (agent: string) => `${base.href.replace(/^http/, "ws")}v1/ws?agent=${agent}`;

async function connect(agent: string, hello = true): Promise<WsClient> {
	const client = await WsClient.connect(wsUrl(agent));
	clients.push(client);
	if (hello) await client.call("engine.hello", { token: TOKEN, client: "test", protocolVersion: "1.0" });
	return client;
}

const ref = (agent: string) => ({ kind: "agent" as const, id: agent });

const idleAfter = (subscriptionId: string, after = 0) => (n: SessionEventsNotification) =>
	n.subscriptionId === subscriptionId && n.seq > after && n.events.some((e) => e.type === "state" && e.state.status === "idle");

const texts = (s: Snapshot) => s.items.map((i) => [i.kind, i.kind === "user" ? i.text : i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : ""]);

const testStatus = async (agent: string) => (await (await mf.dispatchFetch(`${base.href}__test/status?agent=${agent}`)).json()) as { instanceId: string; startedAt: number; alarm: number | null; lastAlarmAt: number | null; busy: boolean };

describe("Engine Protocol over WebSocket", () => {
	test("rejects calls before engine.hello and bad owner tokens", async () => {
		const c = await connect("auth", false);
		await expect(c.call("sessions.subscribe", { ref: ref("auth") })).rejects.toMatchObject({ data: { code: "AUTH" } });
		await expect(c.call("engine.hello", { token: "nope", client: "test", protocolVersion: "1.0" })).rejects.toMatchObject({ data: { code: "AUTH" } });
		const hello = await c.call("engine.hello", { token: TOKEN, client: "test", protocolVersion: "1.0" });
		expect(hello).toMatchObject({ kind: "cloud", engineId: "cloud:auth", capabilities: { runtimes: ["agent"], models: ["faux/echo"] } });
		await expect(c.call("sessions.subscribe", { ref: ref("someone-else") })).rejects.toMatchObject({ data: { code: "NOT_FOUND" } });
		await expect(c.call("sessions.list", {})).rejects.toThrow(/Unknown method/);
	});

	test("refuses plain HTTP on /v1/ws", async () => {
		expect((await mf.dispatchFetch(`${base.href}v1/ws`)).status).toBe(426);
		expect((await mf.dispatchFetch(`${base.href}v1/health`)).status).toBe(200);
	});

	test("streams an answer; a reconnect gets a fresh snapshot", async () => {
		const agent = "stream";
		const a = await connect(agent);
		const sub = await a.call("sessions.subscribe", { ref: ref(agent) });
		expect(sub.snapshot).toMatchObject({ ref: { kind: "agent", id: agent, conversationId: "1" }, items: [], state: { status: "idle", model: { provider: "faux", id: "echo" } } });

		expect(await a.call("sessions.submit", { ref: ref(agent), input: { text: "hello from the cloud" } })).toEqual({ accepted: true, disposition: "started" });
		await a.waitFor(idleAfter(sub.subscriptionId, 1));

		const events: SessionEvent[] = a.events.filter((n) => n.subscriptionId === sub.subscriptionId).flatMap((n) => n.events);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "user" && e.item.text === "hello from the cloud")).toBe(true);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "assistant")).toBe(true);
		// No assertion on item.delta here: pi-durable commits partial answers every 100 ms, so a short answer may have none.
		const seqs = a.events.filter((n) => n.subscriptionId === sub.subscriptionId).map((n) => n.seq);
		expect(seqs).toEqual(seqs.map((_, i) => i + 1));

		// Reconnect: no cursor, just a fresh snapshot with the whole conversation.
		a.close();
		const b = await connect(agent);
		const again = await b.call("sessions.subscribe", { ref: ref(agent) });
		expect(texts(again.snapshot)).toEqual([
			["user", "hello from the cloud"],
			["assistant", "Echo: hello from the cloud"],
		]);
		expect(again.snapshot.state.status).toBe("idle");
	});

	test("hibernates while idle and wakes on a WebSocket message with the subscription intact", async () => {
		const agent = "hibernate";
		const c = await connect(agent);
		const sub = await c.call("sessions.subscribe", { ref: ref(agent) });
		await c.call("sessions.submit", { ref: ref(agent), input: { text: "before" } });
		await c.waitFor(idleAfter(sub.subscriptionId, 1));
		const before = await testStatus(agent);
		const seqBefore = c.events.at(-1)!.seq;

		await mf.unsafeEvictDurableObject(config.name, "AgentDO", { name: agent, webSockets: "hibernate" });

		// Same socket, no reconnect. The message wakes a new instance; the subscription comes back from the attachment.
		const status = await c.call("engine.status");
		expect(status.subscriptions).toBe(1);
		const after = await testStatus(agent);
		expect(after.instanceId).not.toBe(before.instanceId);

		// The wake re-sends a snapshot, continuing the sequence numbers.
		const resnap = await c.waitFor((n) => n.seq > seqBefore && n.events.some((e) => e.type === "resnapshot"));
		expect(resnap.seq).toBe(seqBefore + 1);
		const snapshot = (resnap.events.find((e) => e.type === "resnapshot") as Extract<SessionEvent, { type: "resnapshot" }>).snapshot;
		expect(texts(snapshot)).toEqual([
			["user", "before"],
			["assistant", "Echo: before"],
		]);

		await c.call("sessions.submit", { ref: ref(agent), input: { text: "after" } });
		await c.waitFor(idleAfter(sub.subscriptionId, resnap.seq));
		const fresh = await (await connect(agent)).call("sessions.subscribe", { ref: ref(agent) });
		expect(texts(fresh.snapshot).map(([, t]) => t)).toEqual(["before", "Echo: before", "after", "Echo: after"]);
	});

	test(
		"resumes a run from its alarm after an eviction, with no client connected",
		async () => {
			const agent = "evict";
			const long = `${"x".repeat(1_600)} end`; // ~4 s of faux streaming at 100 tokens/s
			const c = await connect(agent);
			const sub = await c.call("sessions.subscribe", { ref: ref(agent) });
			await c.call("sessions.submit", { ref: ref(agent), input: { text: long } });
			await c.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "item.delta"));

			const running = await testStatus(agent);
			expect(running.busy).toBe(true);
			// The PiHarness wake job keeps an alarm armed (30 s heartbeat) while pi has live tasks.
			expect(running.alarm).not.toBeNull();

			await mf.unsafeEvictDurableObject(config.name, "AgentDO", { name: agent, webSockets: "close" });
			await c.closed;

			// Nothing touches the object until the alarm fires and pi finishes the answer on its own.
			const wakeBy = running.alarm! + 15_000;
			await new Promise((r) => setTimeout(r, Math.max(0, wakeBy - Date.now())));

			const reconnectAt = Date.now();
			const d = await connect(agent);
			const snap = (await d.call("sessions.subscribe", { ref: ref(agent) })).snapshot as Snapshot;
			expect(snap.state.status).toBe("idle");
			expect(texts(snap)).toEqual([
				["user", long],
				["assistant", `Echo: ${long}`],
			]);
			// The answer was already complete on reconnect, and a new alarm ran in between: the alarm resumed it.
			// (The run was awaited inside an alarm invocation; the eviction aborted it, so workerd retried that alarm.)
			const { lastAlarmAt } = await testStatus(agent);
			expect(lastAlarmAt).toBeGreaterThan(running.lastAlarmAt ?? 0);
			expect(lastAlarmAt).toBeLessThan(reconnectAt);
		},
		90_000,
	);
});
