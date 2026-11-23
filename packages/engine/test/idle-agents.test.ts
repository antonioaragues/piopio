/**
 * A coding agent's process ends once its conversation has been idle a while, and the next message resumes the same
 * session in a new one (docs/research/memory-and-cpu.md: each process costs 40 to 300 MB).
 */
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterAll, beforeAll, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

beforeAll(() => {
	process.env.PIOPIO_FAKE_CLAUDE_CODE = "1";
	process.env.PIOPIO_FAKE_ACP = "1";
	process.env.PIOPIO_AGENT_IDLE_MS = "400";
});
afterAll(() => {
	delete process.env.PIOPIO_AGENT_IDLE_MS;
});

async function start() {
	const home = mkdtempSync(join(tmpdir(), "piopio-idle-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	return { home, client, stop: async () => (client.close(), await engine.stop()) };
}

const answers = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "assistant" ? [i.parts.filter((p) => p.type === "text").map((p) => p.text).join("")] : []));

/** Sends a message and returns the answer, once the conversation is idle again. */
async function ask(client: TestClient, ref: unknown, text: string): Promise<string> {
	const before = answers(await client.call("sessions.open", { ref })).length;
	await client.call("sessions.submit", { ref, input: { text } });
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await client.call("sessions.open", { ref });
		if (s.state.status === "idle" && answers(s).length > before) return answers(s).at(-1)!;
		await new Promise((r) => setTimeout(r, 20));
	}
	throw new Error("no answer");
}

const alive = (pid: number) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

test("Claude Code: an idle conversation's process ends, and the next message resumes its session", async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "claude-code", id: "opus" } });
	const first = await ask(a.client, ref, "process?");
	expect(first).toMatch(/^Process: \d+ new$/);
	// Busy again before the idle time: the same process.
	expect(await ask(a.client, ref, "process?")).toBe(first);
	await new Promise((r) => setTimeout(r, 700));
	const sessionId = JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8")).sessionId as string;
	const later = await ask(a.client, ref, "process?");
	expect(later).not.toBe(first);
	expect(later).toMatch(new RegExp(`^Process: \\d+ resumed ${sessionId}$`));
	await a.stop();
}, 30_000);

test("Codex: an idle conversation's process exits, and the next message loads its session in a new one", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-idle-project-")));
	writeFileSync(join(folder, "package.json"), "{}");
	await a.client.call("projects.add", { path: folder });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, model: { provider: "codex-cli", id: "gpt-6.2-sol" } });
	const pid = Number((await ask(a.client, ref, "process?")).replace("Process: ", ""));
	expect(alive(pid)).toBe(true);
	await new Promise((r) => setTimeout(r, 1200));
	expect(alive(pid)).toBe(false);
	const sessionId = JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8")).sessionId as string;
	const next = Number((await ask(a.client, ref, "process?")).replace("Process: ", ""));
	expect(next).not.toBe(pid);
	// The same session, loaded again: its id didn't change.
	expect(JSON.parse(readFileSync(join(a.home, "chats", "agents", `${ref.id}.json`), "utf8")).sessionId).toBe(sessionId);
	await a.stop();
}, 30_000);
