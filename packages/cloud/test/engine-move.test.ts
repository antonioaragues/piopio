/**
 * K1 end to end (docs/spec/30 §3.2): the Mac's engine connects to the Worker (Miniflare here), moves an agent up with
 * its memory and automations, relays its conversation, and brings it back. The engine is the real one, from source.
 */
import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, expect, test } from "vitest";
import { enginePaths } from "../../engine/src/paths.js";
import { Engine } from "../../engine/src/server.js";
import { TestClient } from "../../engine/test/client.js";

const TOKEN = "engine-move-token";
const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

let mf: Miniflare;
let base: string;
let engine: Engine;
let client: TestClient;
let home: string;

beforeAll(async () => {
	mf = new Miniflare(
		convertV4MiniflareOptions({
			name: config.name,
			modules: true,
			scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
			compatibilityDate: config.compatibility_date,
			compatibilityFlags: config.compatibility_flags,
			durableObjects: { AGENT: { className: "AgentDO", useSQLite: true }, REGISTRY: { className: "RegistryDO", useSQLite: true } },
			bindings: { OWNER_TOKEN: TOKEN, PIOPIO_FAUX_MODEL: "1", PIOPIO_FAUX_TPS: "200" },
		}),
	);
	base = (await mf.ready).href.replace(/\/$/, "");
	home = mkdtempSync(join(tmpdir(), "piopio-k1-"));
	const paths = enginePaths(home);
	engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
}, 60_000);

afterAll(async () => {
	client?.close();
	await engine?.stop();
	await mf?.dispose();
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 10_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 500)}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

const text = (items: { kind: string; text?: string; parts?: { text: string }[] }[]) => items.map((i) => i.text ?? i.parts?.map((p) => p.text).join("") ?? "").join("\n");

test("connect, move up, talk through the Mac's engine, move back", async () => {
	expect(await client.call("cloud.status")).toEqual({ connected: false, agents: [] });
	await expect(client.call("cloud.connect", { url: base, token: "wrong" })).rejects.toThrow(/refused that owner token/);
	await expect(client.call("cloud.connect", { url: "ftp://nope", token: TOKEN })).rejects.toThrow(/https/);
	expect(await client.call("cloud.connect", { url: base, token: TOKEN })).toMatchObject({ connected: true, reachable: true, url: base, agents: [] });
	expect(client.secrets.CLOUD_OWNER_TOKEN).toBe(TOKEN);

	const { ref } = await client.call("agents.create", { name: "Helper", owner: "Ana", template: "personal-assistant", model: { provider: "faux", id: "faux-1" } });
	await client.call("automations.add", { runsAs: ref.id, when: "0 8 * * 1-5", prompt: "Tell me what's ahead today" });
	await client.call("automations.add", { runsAs: ref.id, on: "folder", folder: join(home, "Inbox"), prompt: "Sort the new file" });
	await engine.memory.builtin.retain(`${ref.id}/owner`, { content: "Ana lives in Bilbao", kind: "fact", createdBy: "agent" });

	// Up: its time automation becomes a schedule there; the folder one stays here, off; memory goes along.
	const up = await client.call<{ lines: string[] }>("agents.move", { ref, to: "cloud" });
	expect(up.lines[0]).toBe("Helper runs in your cloud now: it keeps going with your Mac off.");
	expect(up.lines).toEqual(expect.arrayContaining([expect.stringMatching(/needs this Mac, so in the cloud it uses echo/), expect.stringMatching(/watches a folder on this Mac/), "Automations: 1 now run in the cloud.", "Memory: 1 record."]));
	const listed = (await client.call<{ sessions: { ref: { id: string }; agent?: { location: string } }[] }>("sessions.list", { kind: "agent" })).sessions.find((s) => s.ref.id === ref.id);
	expect(listed?.agent?.location).toBe("cloud");
	expect((await client.call("cloud.status")).agents).toEqual([expect.objectContaining({ id: ref.id, name: "Helper" })]);
	expect((await client.call<{ automations: { runsAs: string }[] }>("automations.list", {})).automations.filter((a) => a.runsAs === ref.id)).toEqual([]);
	expect(engine.memory.builtin.banks().filter((b) => b.bank.startsWith(ref.id))).toEqual([]);
	await expect(client.call("agents.move", { ref, to: "cloud" })).rejects.toThrow(/already runs in your cloud/);

	// Its conversation, through this engine: the snapshot and answers come from the cloud.
	const people = await client.call<{ people: { contactId: string; name: string }[] }>("agents.conversations", { ref });
	expect(people.people.map((p) => p.name)).toEqual(["Ana"]);
	const mine = { ...ref, conversationId: `person:${people.people[0]!.contactId}` };
	await client.call("sessions.subscribe", { ref: mine });
	await client.call("sessions.submit", { ref: mine, input: { text: "Hello from the Mac" } });
	await until(() => client.call<{ items: never[] }>("sessions.open", { ref: mine }).then((s) => text(s.items)), (s) => s.includes("Echo: Hello from the Mac"));
	const runs = await client.call<{ upcoming: { kind: string; cron?: string }[] }>("agents.runs", { ref });
	expect(runs.upcoming).toEqual(expect.arrayContaining([expect.objectContaining({ kind: "schedule", cron: "0 8 * * 1-5" })]));
	await expect(client.call("agents.pause", { ref, paused: true })).rejects.toThrow(/runs in your cloud/);

	// Disconnecting is refused while it's up there.
	await expect(client.call("cloud.disconnect")).rejects.toThrow(/Helper runs in your cloud/);

	// Back: memory, the schedule as an automation again, the parked folder one; the cloud's conversation as text.
	const down = await client.call<{ lines: string[] }>("agents.move", { ref, to: "local" });
	expect(down.lines[0]).toBe("Helper runs on this Mac again: it stops while your Mac sleeps or is off.");
	// Memory comes back with what was said up there too (the message and its answer).
	expect(down.lines).toEqual(expect.arrayContaining([expect.stringMatching(/saved as text in its folder/), "Memory: 3 records.", "Automations: 2 run on this Mac again."]));
	const back = (await client.call<{ automations: { runsAs: string; on: string; cron?: string }[] }>("automations.list", {})).automations.filter((a) => a.runsAs === ref.id);
	expect(back.map((a) => a.on).sort()).toEqual(["folder", "time"]);
	expect(back.find((a) => a.on === "time")?.cron).toBe("0 8 * * 1-5");
	expect((await engine.memory.builtin.recall([`${ref.id}/owner`], "Bilbao")).map((h) => h.text)).toContain("Ana lives in Bilbao");
	expect((await client.call("cloud.status")).agents).toEqual([]);
	const def = await client.call<{ folder: string; definition: { schedules?: unknown } }>("agents.get", { ref });
	expect(def.definition).not.toHaveProperty("schedules");
	const saved = join(def.folder, "cloud-conversations");
	expect(existsSync(saved) && readdirSync(saved).map((f) => readFileSync(join(saved, f), "utf8")).join("\n")).toContain("Echo: Hello from the Mac");

	// On the Mac again, it answers here.
	await client.call("agents.pause", { ref, paused: false });
	await client.call("cloud.disconnect");
	expect(await client.call("cloud.status")).toEqual({ connected: false, agents: [] });
}, 90_000);
