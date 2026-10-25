/**
 * Spike S7: Piopio's agent runtime (`AgentCore`) inside the AgentDO, in workerd (Miniflare) with the faux model.
 * A person's turn with memory, a reminder that fires from its own alarm after the object was evicted, and a turn
 * interrupted by an eviction that finishes on its own.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, describe, expect, test } from "vitest";

const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

let mf: Miniflare;
let base: URL;

beforeAll(async () => {
	mf = new Miniflare(
		convertV4MiniflareOptions({
			name: config.name,
			modules: true,
			scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
			compatibilityDate: config.compatibility_date,
			compatibilityFlags: config.compatibility_flags,
			durableObjects: { AGENT: { className: "AgentDO", useSQLite: true } },
			bindings: { OWNER_TOKEN: "t", PIOPIO_FAUX_MODEL: "1", PIOPIO_FAUX_TPS: "100", PIOPIO_TEST_HOOKS: "1", PIOPIO_TEST_WAKE_MS: "1000" },
		}),
	);
	base = await mf.ready;
});

afterAll(async () => {
	await mf?.dispose();
});

async function call<T = Record<string, unknown>>(agent: string, route: string, body?: unknown): Promise<T> {
	const res = await mf.dispatchFetch(`${base.href}__test/agent/${route}${route.includes("?") ? "&" : "?"}agent=${agent}`, body === undefined ? {} : { method: "POST", body: JSON.stringify(body) });
	if (!res.ok) throw new Error(`${route}: ${res.status} ${await res.text()}`);
	return (await res.json()) as T;
}

const status = async (agent: string) => (await (await mf.dispatchFetch(`${base.href}__test/status?agent=${agent}`)).json()) as { instanceId: string; alarm: number | null; lastAlarmAt: number | null };
const evict = (agent: string) => mf.unsafeEvictDurableObject(config.name, "AgentDO", { name: agent, webSockets: "close" });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Overview = { runs: { kind: string; status: string; firedAt: string; prompt: string; summary?: string }[]; upcoming: { kind: string; next?: number }[]; alarm: number | null; nextWake?: number; instanceId: string; rests: number[] };

describe("Piopio's agent in a Durable Object (spike S7)", () => {
	test("a person's turn runs through AgentCore; what they said is in memory on the object's SQLite, after an eviction too", async () => {
		const agent = "s7-memory";
		const turn = await call<{ status: string; text: string }>(agent, "say", { contact: "owner", text: "I live in Bilbao and I run in the mornings" });
		expect(turn).toMatchObject({ status: "done", text: expect.stringContaining("Echo: ") });
		expect(turn.text).toContain("I live in Bilbao");

		const found = await call<{ hits: { text: string }[] }>(agent, "recall?q=Bilbao");
		expect(found.hits.map((h) => h.text).join("\n")).toContain("Bilbao");

		const before = await status(agent);
		await evict(agent);
		const again = await call<{ hits: { text: string }[] }>(agent, "recall?q=mornings");
		expect(again.hits.map((h) => h.text).join("\n")).toContain("mornings");
		expect((await status(agent)).instanceId).not.toBe(before.instanceId);

		// The next turn recalls it (the faux model echoes; the turn just has to run with memory in its section).
		const second = await call<{ status: string }>(agent, "say", { contact: "owner", text: "Where do I live?" });
		expect(second.status).toBe("done");
	});

	test(
		"between wakes the agent rests (pi closed, no timers); a reminder then fires from its alarm, with nothing else waking it",
		async () => {
			const agent = "s7-reminder";
			await call(agent, "say", { contact: "owner", text: "hi" }); // the owner's conversation exists
			const { at, wake } = await call<{ at: number; wake: number }>(agent, "remind", { inMs: 8000, prompt: "Stretch your legs" });
			expect(wake).toBe(at);
			const armed = await call<Overview>(agent, "overview");
			expect(armed.upcoming).toEqual([expect.objectContaining({ kind: "reminder", next: at })]);

			// The settle check (1 s in tests) finds nothing running and the reminder far enough away: it rests.
			await sleep(3000);
			// With pi closed nothing pins the object: the eviction is immediate (a sleeping task's timer would hold it).
			const evictStarted = Date.now();
			await evict(agent);
			expect(Date.now() - evictStarted).toBeLessThan(1500);

			// Nothing touches the object until well after the reminder's moment.
			await sleep(Math.max(0, at + 5000 - Date.now()));
			const lookedAt = Date.now();
			const after = await call<Overview>(agent, "overview");
			// It rested before the reminder (and again after its run).
			expect(after.rests.some((t) => t < at)).toBe(true);
			expect(after.rests.some((t) => t > at)).toBe(true);
			const run = after.runs.find((r) => r.kind === "reminder");
			expect(run).toBeDefined();
			expect(run!.prompt).toBe("Stretch your legs");
			// It fired from the alarm: at its moment, before we looked, not because we looked.
			expect(Date.parse(run!.firedAt)).toBeGreaterThanOrEqual(at);
			expect(Date.parse(run!.firedAt)).toBeLessThan(lookedAt - 1000);
			expect(run!.status).toBe("done");
			// A one-off reminder: nothing left to wake for.
			expect(after.upcoming).toEqual([]);
		},
		60_000,
	);

	test(
		"a person's turn interrupted by an eviction finishes on its own",
		async () => {
			const agent = "s7-evict";
			const long = `${"y".repeat(1_600)} end`; // ~4 s of faux streaming
			const { session, operationId } = await call<{ session: string; operationId: string }>(agent, "say", { contact: "owner", text: long, wait: false });
			await sleep(800);
			const running = await status(agent);
			expect(running.alarm).not.toBeNull();
			await evict(agent);

			await sleep(Math.max(0, running.alarm! + 15_000 - Date.now()));
			const lookedAt = Date.now();
			const result = await call<{ status: string; text: string }>(agent, "wait", { session, operationId });
			expect(result.status).toBe("done");
			expect(result.text).toBe(`Echo: ${long}`);
			expect((await status(agent)).lastAlarmAt).toBeLessThan(lookedAt);
		},
		90_000,
	);
});
