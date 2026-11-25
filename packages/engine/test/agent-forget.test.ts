import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import type { Snapshot } from "@piopio/protocol";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Re-audit 2026-11-25: an agent's `forget` kept the text in memory's history and in an Undo record, even when the
// person had asked to forget it. Asked: nothing of it stays. Wrong: it can be undone, as before.

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

test("an agent forgets what the person asked to forget for good, and a wrong fact so it can be undone", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-agent-forget-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	open.push({ engine, client });

	const { ref } = await client.call("agents.create", { name: "Scout", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const bank = `${ref.id}/owner`;
	const memory = engine.memory.builtin;
	const [secret] = await memory.retain(bank, { content: "Sees Dr. Ortega about the knee", kind: "fact", createdBy: "user" });
	const [wrong] = await memory.retain(bank, { content: "Lives in Bilbao", kind: "fact", createdBy: "agent" });
	const tools = async () => ((await client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "steps" ? i.tools : i.kind === "tool" ? [i] : []));
	const done = async (n: number) => {
		for (let i = 0; i < 150; i++) {
			const ts = await tools();
			if (ts.filter((t) => t.status === "done" || t.status === "error").length >= n) return ts;
			await new Promise((r) => setTimeout(r, 100));
		}
		throw new Error(`timed out: ${JSON.stringify(await tools())}`);
	};

	await client.call("sessions.submit", { ref, input: { text: `call: forget | ${JSON.stringify({ id: secret!.id, asked: true })}` } });
	expect((await done(1))[0]).toMatchObject({ tool: "forget", status: "done", output: expect.stringContaining("for good") });
	expect((await memory.list(bank)).records.map((r) => r.text)).toEqual(["Lives in Bilbao"]);
	expect((await memory.history(bank)).map((e) => e.text)).not.toContain("Sees Dr. Ortega about the knee");
	expect(JSON.stringify(await tools())).not.toContain("Ortega");

	await client.call("sessions.submit", { ref, input: { text: `call: forget | ${JSON.stringify({ id: wrong!.id })}` } });
	const second = (await done(2))[1]!;
	expect(second).toMatchObject({ tool: "forget", status: "done", output: "Forgotten." });
	expect((await memory.history(bank)).map((e) => e.text)).toContain("Lives in Bilbao");
}, 60_000);
