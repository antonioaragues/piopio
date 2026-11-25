/**
 * What follows a person's turn with an agent (its memory, the answer's delivery, the budget) is a durable task the
 * agent starts from pi-durable's `afterRun` hook (runtime/src/agents/core.ts `turnEnded`), not something a chat view
 * remembers to do: it happens for a turn whose answer came after a restart too.
 */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-turn-end-"))): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
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

test("a turn cut by a restart is still kept in memory once its answer comes", async () => {
	let a = await start();
	const { ref } = await a.client.call("agents.create", { name: "Helper", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const kept = async () => ((await a.client.call("memory.list", { provider: "builtin", bank: `${ref.id}/owner` })) as { records: { text: string }[] }).records.map((r) => r.text);
	const until = async <T>(read: () => Promise<T>, ready: (v: T) => boolean) => {
		for (let i = 0; i < 400; i++) {
			const v = await read();
			if (ready(v)) return v;
			await new Promise((r) => setTimeout(r, 100));
		}
		throw new Error("it didn't get there");
	};

	// A turn that ends normally: what was said and the answer are kept.
	await a.client.call("sessions.submit", { ref, input: { text: "Short one" } });
	expect(await until(kept, (xs) => xs.some((t) => t.includes("Echo: Short one")))).toEqual(expect.arrayContaining([expect.stringContaining("Antonio: Short one")]));

	// Long enough to still be answering when the engine stops (the faux model streams 40 tokens a second).
	const long = Array.from({ length: 120 }, (_, i) => `word${i}`).join(" ");
	await a.client.call("sessions.submit", { ref, input: { text: long } });
	await until(async () => ((await a.client.call("sessions.open", { ref })) as Snapshot).state.status, (s) => s === "running");
	await stop(a);
	a = await start(a.home);
	// The new engine has no view that saw the message go out; the agent's own task follows the answer.
	await a.client.call("sessions.open", { ref });
	const after = await until(kept, (xs) => xs.some((t) => t.includes("Echo: word0 word1")));
	expect(after.filter((t) => t.startsWith("Antonio: word0")).length).toBe(1);
	expect(after.filter((t) => t.includes("Echo: word0 word1")).length).toBe(1);
}, 120_000);
