/**
 * Two races at pi's edges in a conversation in a folder (found reading T3 Code's pi adapter, 2026-11-15):
 * a message sent while a compaction runs, and Stop with messages still queued.
 */
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-races-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

async function idle(a: Ctx, ref: unknown, until: (s: Snapshot) => boolean = () => true): Promise<Snapshot> {
	for (let i = 0; i < 200; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && until(s)) return s;
		await new Promise((r) => setTimeout(r, 50));
	}
	throw new Error("the session didn't settle");
}

const lines = (s: Snapshot) =>
	s.items.map((i) => (i.kind === "user" ? `> ${i.text}` : i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : i.kind === "system" ? `[${i.level}] ${i.text}` : i.kind));

test("the context panel counts the prepared request and waits for new usage after compaction", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-context-")));
	writeFileSync(join(folder, "AGENTS.md"), "Keep answers concise.");
	writeFileSync(join(folder, "notes.md"), "Notes read with a tool.");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const faux = a.engine.hub.faux!;
	faux.setResponses([
		fauxAssistantMessage([fauxToolCall("read", { path: "notes.md" })], { stopReason: "toolUse" }),
		fauxAssistantMessage("Initial answer."),
	]);
	const submit = (text: string, attachments?: { kind: "text"; name: string; text: string }[]) =>
		a.client.call("sessions.submit", { ref, input: { text, ...(attachments ? { attachments } : {}) } });
	const answered = (answer: string) => idle(a, ref, (s) => s.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === answer)));

	await submit("Read the notes", [{ kind: "text", name: "attached.txt", text: "Attached text from the user." }]);
	const first = (await answered("Initial answer.")).state.context?.breakdown;
	expect(first?.source).toBe("request");
	expect(first?.groups).toEqual(expect.arrayContaining([
		expect.objectContaining({ kind: "instructions", parts: expect.arrayContaining([expect.objectContaining({ label: "Project instructions (AGENTS.md)" })]) }),
		expect.objectContaining({ kind: "tools", tokens: expect.any(Number) }),
		expect.objectContaining({ kind: "toolUse", parts: [expect.objectContaining({ label: "Files" })] }),
		expect.objectContaining({ kind: "attachments", parts: [expect.objectContaining({ label: "Text and documents" })] }),
	]));

	for (const answer of ["Next answer.", "Latest answer."]) {
		faux.setResponses([fauxAssistantMessage(answer)]);
		await submit("A longer conversation. ".repeat(2_500));
		await answered(answer);
	}
	faux.setResponses([fauxAssistantMessage("Summary of earlier messages.")]);
	await a.client.call("sessions.compact", { ref });
	const pending = (await idle(a, ref)).state.context;
	expect(pending?.tokens).toBeNull();
	expect(pending?.breakdown).toBeUndefined();

	faux.setResponses([fauxAssistantMessage("After compacting.")]);
	await submit("Continue");
	const updated = (await answered("After compacting.")).state.context;
	expect(updated?.tokens).toBeGreaterThan(0);
	expect(updated?.breakdown?.groups.some((g) => g.kind === "summaries")).toBe(true);
	expect(updated?.breakdown?.groups.some((g) => g.kind === "attachments")).toBe(false);
}, 20_000);

test("a message sent while the conversation compacts waits for it, instead of failing", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-compact-")));
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	// Enough history to compact: pi keeps the newest ~20k tokens, so three long messages with short answers.
	const faux = a.engine.hub.faux!;
	faux.setResponses(["ok 1", "ok 2", "ok 3"].map((t) => fauxAssistantMessage(t)));
	for (const [i, text] of ["one", "two", "three"].entries()) {
		await a.client.call("sessions.submit", { ref, input: { text: `${text} ${"words and more words ".repeat(2_000)}` } });
		await idle(a, ref, (s) => s.items.filter((x) => x.kind === "assistant").length > i);
	}

	// The summary request waits until released, so the compaction is still running when the message arrives.
	let release!: () => void;
	const gate = new Promise<void>((r) => (release = r));
	const calls = faux.state.callCount;
	faux.setResponses([async () => (await gate, fauxAssistantMessage("Summary of the conversation.")), fauxAssistantMessage("After the compaction.")]);
	const compacting = a.client.call("sessions.compact", { ref });
	for (let i = 0; i < 200 && faux.state.callCount === calls; i++) await new Promise((r) => setTimeout(r, 10));
	expect(faux.state.callCount).toBeGreaterThan(calls);

	const sent = await a.client.call("sessions.submit", { ref, input: { text: "next" } });
	expect(sent).toEqual({ accepted: true, disposition: "queued" });
	release();
	await compacting;
	const s = await idle(a, ref, (x) => x.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === "After the compaction.")));
	expect(lines(s).filter((l) => l.startsWith("[error]"))).toEqual([]);
	expect(lines(s).slice(-2)).toEqual(["> next", "After the compaction."]);
}, 20_000);

test("Stop drops the queued messages and says which, so none reappears with the next one", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-stop-")));
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const sub = await a.client.call("sessions.subscribe", { ref });
	await a.client.call("sessions.submit", { ref, input: { text: `a long first message ${"that keeps the model busy ".repeat(30)}` } });
	await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.status === "running"));
	expect(await a.client.call("sessions.submit", { ref, input: { text: "queued one" } })).toMatchObject({ disposition: "queued" });
	await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.queue.some((q) => q.text === "queued one")));

	await a.client.call("sessions.abort", { ref });
	let s = await idle(a, ref);
	expect(s.state.queue).toEqual([]);
	expect(lines(s).at(-1)).toBe("[info] Stopped. Not sent: “queued one”");

	await a.client.call("sessions.submit", { ref, input: { text: "next" } });
	s = await idle(a, ref, (x) => x.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === "Echo: next")));
	expect(lines(s).some((l) => l === "> queued one")).toBe(false);
});
