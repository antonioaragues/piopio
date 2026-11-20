/**
 * K1 (docs/spec/30 §3.2): an agent goes up from the Mac as data and comes back. Deploy stores its definition, memory
 * and reminders and lists it in the registry; export reads all of that back; retire deletes it and stops it there.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newDefinition } from "@piopio/runtime";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { WsClient } from "./client.js";

const TOKEN = "move-token";
const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

let mf: Miniflare;
let base: URL;
const clients: WsClient[] = [];

beforeAll(async () => {
	mf = new Miniflare(
		convertV4MiniflareOptions({
			name: config.name,
			modules: true,
			scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
			compatibilityDate: config.compatibility_date,
			compatibilityFlags: config.compatibility_flags,
			durableObjects: { AGENT: { className: "AgentDO", useSQLite: true }, REGISTRY: { className: "RegistryDO", useSQLite: true } },
			bindings: { OWNER_TOKEN: TOKEN, PIOPIO_FAUX_MODEL: "1", PIOPIO_FAUX_TPS: "100", PIOPIO_TEST_HOOKS: "1" },
		}),
	);
	base = await mf.ready;
});

afterAll(async () => {
	for (const c of clients) c.close();
	await mf?.dispose();
});

async function connect(agent: string): Promise<WsClient> {
	const client = await WsClient.connect(`${base.href.replace(/^http/, "ws")}v1/ws?agent=${agent}`, TOKEN);
	clients.push(client);
	await client.call("engine.hello", { token: TOKEN, client: "test", protocolVersion: "1.0" });
	return client;
}

const registry = async () => {
	const res = await mf.dispatchFetch(`${base.href}v1/agents`, { headers: { Authorization: `Bearer ${TOKEN}` } });
	return ((await res.json()) as { agents: { id: string; name: string }[] }).agents;
};

describe("moving an agent between the Mac and the cloud (K1)", () => {
	test("/v1/agents needs the owner's token", async () => {
		expect((await mf.dispatchFetch(`${base.href}v1/agents`)).status).toBe(401);
		expect((await mf.dispatchFetch(`${base.href}v1/agents`, { headers: { Authorization: "Bearer nope" } })).status).toBe(401);
	});

	test("deploy, export, retire", async () => {
		const id = "agt_movetest";
		const made = newDefinition({ id, slug: "helper", name: "Helper", owner: "Ana", model: "faux:echo", template: "personal-assistant" });
		const c = await connect(id);
		const ref = { kind: "agent" as const, id };

		// A definition for another agent, or one that doesn't validate, is refused and nothing is stored.
		await expect(c.call("agents.deploy", { ref, definition: { ...made.definition, id: "agt_other" }, instructions: made.instructions })).rejects.toMatchObject({ data: { code: "INVALID" } });
		await expect(c.call("agents.deploy", { ref, definition: { ...made.definition, contacts: "nope" }, instructions: made.instructions })).rejects.toMatchObject({ data: { code: "INVALID" } });

		const at = Date.now() + 3600_000;
		const reminder = { id: "r1", prompt: "Water the plants", at, createdAt: new Date().toISOString(), by: "owner" };
		const passed = { ...reminder, id: "r0", at: Date.now() - 1000 };
		const deployed = await c.call<{ deployedAt: string; lines: string[] }>("agents.deploy", {
			ref,
			definition: made.definition,
			instructions: made.instructions,
			memory: [
				{ partition: "owner", text: "Ana lives in Bilbao", kind: "fact", createdBy: "agent", at: "2026-11-01T10:00:00.000Z", pinned: true },
				{ partition: "owner", text: "Ana runs in the mornings", kind: "fact", createdBy: "user", at: "2026-11-02T10:00:00.000Z", tags: ["habits"] },
			],
			reminders: [reminder, passed],
		});
		expect(deployed.lines).toEqual(["Memory: 2 records.", "Reminders: 1."]);
		expect(await registry()).toEqual([{ id, name: "Helper", avatar: "symbol:calendar", deployedAt: deployed.deployedAt }]);

		const people = await c.call<{ people: { contactId: string; name: string; role: string }[] }>("agents.conversations", { ref });
		expect(people.people.map((p) => [p.name, p.role])).toEqual([["Ana", "owner"]]);
		const runs = await c.call<{ upcoming: { kind: string; label: string }[] }>("agents.runs", { ref });
		expect(runs.upcoming.map((u) => u.kind)).toContain("reminder");

		// Run now, pause and the Inbox, as the Mac's engine asks for them (K1's gaps).
		const { runId } = await c.call<{ runId: string }>("agents.runNow", { ref, prompt: "Check the plants" });
		const ran = async () => (await c.call<{ runs: { id: string; status: string; prompt: string }[] }>("agents.runs", { ref })).runs.find((r) => r.id === runId);
		for (let i = 0; i < 100 && (await ran())?.status === "running"; i++) await new Promise((r) => setTimeout(r, 50));
		expect(await ran()).toMatchObject({ prompt: "Check the plants", status: "done" });
		await expect(c.call("agents.runNow", { ref })).rejects.toMatchObject({ data: { code: "INVALID" } });
		expect(await c.call("agents.status", { ref })).toMatchObject({ paused: false, inbox: 0, nextRun: new Date(at).toISOString() });
		await c.call("agents.pause", { ref, paused: true });
		expect(await c.call("agents.status", { ref })).toMatchObject({ paused: true });
		expect(await c.call<{ nextRun?: string }>("agents.status", { ref })).not.toHaveProperty("nextRun");
		await c.call("agents.pause", { ref, paused: false });
		const inbox = await c.call<{ items: { agent: { id: string }; kind: string }[] }>("inbox.list", {});
		expect(inbox.items.every((i) => i.agent.id === id)).toBe(true);
		await c.call("inbox.read", { items: inbox.items.map((i) => ({ agentId: id, id: (i as unknown as { id: string }).id })) });
		await expect(c.call("agents.decide", { ref, approvalId: "nope", approve: true })).rejects.toMatchObject({ data: { code: "INVALID" } });

		const exported = await c.call<{ definition: { name: string }; instructions: string; memory: { text: string; pinned?: boolean; tags?: string[] }[]; reminders: { id: string }[] }>("agents.export", { ref });
		expect(exported.definition.name).toBe("Helper");
		expect(exported.instructions).toBe(made.instructions);
		expect(exported.memory).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ partition: "owner", text: "Ana lives in Bilbao", kind: "fact", pinned: true }),
				expect.objectContaining({ partition: "owner", text: "Ana runs in the mornings", tags: ["habits"] }),
			]),
		);
		expect(exported.reminders.map((r) => r.id)).toEqual(["r1"]);

		await c.call("agents.retire", { ref });
		expect(await registry()).toEqual([]);
		await expect(c.call("agents.runs", { ref })).rejects.toThrow(/moved back to the Mac/);

		// Deployed again later, it starts fresh: nothing from before the move back. The object restarted after retiring
		// (its storage, the SDK's tables included, was deleted), so this is a new socket to a new instance.
		await c.closed;
		const c2 = await connect(id);
		const again = await c2.call<{ lines: string[] }>("agents.deploy", { ref, definition: made.definition, instructions: made.instructions });
		expect(again.lines).toEqual([]);
		const fresh = await c2.call<{ memory: unknown[]; reminders: unknown[] }>("agents.export", { ref });
		expect(fresh).toMatchObject({ memory: [], reminders: [] });
		expect((await registry()).map((a) => a.id)).toEqual([id]);

		// And it answers: the first message after coming back up (2026-11-20: "no such table: cf_agents_jobs").
		const sub = await c2.call<{ subscriptionId: string }>("sessions.subscribe", { ref });
		await c2.call("sessions.submit", { ref, input: { text: "Back again" } });
		const answered = await c2.waitFor((n) => n.subscriptionId === sub.subscriptionId && JSON.stringify(n.events).includes("Echo: Back again"));
		expect(JSON.stringify(answered.events)).not.toContain("SQLITE_ERROR");
	});

	test("a conversation names the agent's own model, saved as a bare OpenRouter id", async () => {
		// The Mac saves OpenRouter models without a provider ("deepseek/…"); the Worker once read that as no model and
		// named its default (Haiku) in the composer while the agent answered with its own (2026-11-20).
		const id = "agt_modeltest";
		const made = newDefinition({ id, slug: "pinpin", name: "Pinpin", owner: "Ana", model: "deepseek/deepseek-v4.1-flash-1017", template: "personal-assistant" });
		const c = await connect(id);
		const ref = { kind: "agent" as const, id };
		await c.call("agents.deploy", { ref, definition: made.definition, instructions: made.instructions });
		const { snapshot } = await c.call<{ snapshot: { state: { model?: { provider: string; id: string } } } }>("sessions.subscribe", { ref });
		expect(snapshot.state.model).toEqual({ provider: "openrouter", id: "deepseek/deepseek-v4.1-flash-1017" });
		await c.call("agents.retire", { ref });
	});
});
