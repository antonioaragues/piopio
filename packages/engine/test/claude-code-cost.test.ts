/** Claude Code on an API key: what it reports spending counts as spending (docs/spec/31 CA6 is for plans). */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterAll, beforeAll, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { billedByKey } from "../src/runtimes/claude-code.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

beforeAll(() => {
	process.env.PIOPIO_FAKE_CLAUDE_CODE = "1";
	process.env.PIOPIO_FAKE_CLAUDE_KEY = "1";
});
afterAll(() => {
	delete process.env.PIOPIO_FAKE_CLAUDE_KEY;
});

async function start(home: string) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	return { client, stop: async () => (client.close(), await engine.stop()) };
}

async function idleWithAnswers(client: TestClient, ref: unknown, n: number): Promise<Snapshot> {
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await client.call("sessions.open", { ref });
		if (s.state.status === "idle" && s.items.filter((x) => x.kind === "assistant").length >= n) return s;
		await new Promise((r) => setTimeout(r, 30));
	}
	throw new Error("no answer");
}

test("a plan (or OAuth) isn't billed by key; an API key, a helper or an org key is", () => {
	expect(billedByKey("none")).toBe(false);
	expect(billedByKey("oauth")).toBe(false);
	expect(billedByKey(undefined)).toBe(false);
	expect(billedByKey("ANTHROPIC_API_KEY")).toBe(true);
	expect(billedByKey("apiKeyHelper")).toBe(true);
	expect(billedByKey("/login managed key")).toBe(true);
});

test("on an API key, each turn's cost counts, and stays counted after a restart", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-cc-cost-"));
	const a = await start(home);
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "claude-code", id: "opus" } });
	await a.client.call("sessions.submit", { ref, input: { text: "hello" } });
	await idleWithAnswers(a.client, ref, 1);
	await a.client.call("sessions.submit", { ref, input: { text: "again" } });
	const s = await idleWithAnswers(a.client, ref, 2);
	expect(s.state.usage.costUsd).toBeCloseTo(0.02, 5);
	await a.stop();
	const b = await start(home);
	const again: Snapshot = await b.client.call("sessions.open", { ref });
	expect(again.state.usage.costUsd).toBeCloseTo(0.02, 5);
	await b.stop();
}, 60_000);
