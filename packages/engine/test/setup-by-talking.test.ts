import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
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

type Agent = { definition: { name: string; description?: string; avatar?: string; interview?: boolean }; instructions: string };

test("a new agent with nothing said greets, interviews and sets itself up; Undo puts it back (docs/spec/19 S2)", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-setup-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });

	const { ref } = await client.call("agents.create", { name: "New agent", owner: "Antonio", instructions: "", model: { provider: "faux", id: "faux-1" } });
	const first = (await client.call("agents.get", { ref })) as Agent;
	expect(first.definition.interview).toBe(true);
	// It speaks first: the greeting is in the owner's conversation before anyone writes.
	const opened = await client.call("sessions.subscribe", { ref });
	expect(JSON.stringify(opened.snapshot.items)).toContain("Hi Antonio! I'm your new agent. What would you like me to help with?");

	// The model, told it's new, sets itself up.
	const setUp = { name: "Invoices", description: "Watches your invoices and tells you the amounts", avatar: "🧾", instructions: "When an invoice arrives, tell Antonio the amount and due date." };
	await client.call("sessions.submit", { ref, input: { text: `call: set_up | ${JSON.stringify(setUp)}` } });
	const done = await until(() => client.call("agents.get", { ref }) as Promise<Agent>, (a) => a.definition.name === "Invoices");
	expect(done.definition).toMatchObject({ name: "Invoices", description: setUp.description, avatar: "🧾" });
	expect(done.definition.interview).toBeUndefined();
	expect(done.instructions).toBe("# Invoices\n\nWhen an invoice arrives, tell Antonio the amount and due date.\n");

	// Its result card has Undo, which brings back the name and the instructions.
	const items = (await until(() => client.call("sessions.open", { ref }), (s: { items: { kind: string }[] }) => s.items.some((i) => i.kind === "result"))).items as { kind: string; card?: { kind: string; title: string }; undo?: { id: string } }[];
	const card = items.find((i) => i.kind === "result")!;
	expect(card.card).toMatchObject({ kind: "setup", title: "Set up as Invoices" });
	await client.call("agents.undo", { ref, undoId: card.undo!.id });
	const back = await until(() => client.call("agents.get", { ref }) as Promise<Agent>, (a) => a.definition.name === "New agent");
	expect(back.instructions).toBe("# New agent\n\nYou were just created. You'll learn your job from Antonio.\n");

	// An agent made with instructions or a template doesn't interview.
	const { ref: plain } = await client.call("agents.create", { name: "Plain", owner: "Antonio", instructions: "Say hi.", model: { provider: "faux", id: "faux-1" } });
	expect(((await client.call("agents.get", { ref: plain })) as Agent).definition.interview).toBeUndefined();
}, 30_000);
