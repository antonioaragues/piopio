/**
 * The prompt cache's precondition (docs/spec/38 TC9): each request a conversation sends starts with the exact bytes of
 * the one before. Recorded as a provider without mid-conversation system messages gets it (pi-ai's own
 * `resolveTranscript(…, false)`, what OpenRouter's Claude models get): a change anywhere in the system prompt then
 * shows as block 0 changing, and costs the whole conversation again.
 */
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, resolveTranscript, toToolDeclaration, type FauxResponseStep, type Tool, type TranscriptContext } from "@earendil-works/pi-ai";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient; requests: Map<string, string[][]> };
const open: Ctx[] = [];

afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

/** A request as blocks: the (collapsed) system message with its tools, then one block per message. */
function blocks(context: TranscriptContext): string[] {
	return resolveTranscript(context, false).messages.map((m) => {
		if (m.role === "system") return JSON.stringify({ content: m.content, sections: m.sections, tools: (m.toolsAdded ?? []).map((t) => toToolDeclaration(t as Tool)) });
		if (m.role === "toolResult") return JSON.stringify({ role: m.role, toolCallId: m.toolCallId, content: m.content, isError: m.isError });
		return JSON.stringify({ role: m.role, content: m.content });
	});
}

const textOf = (content: unknown) => (typeof content === "string" ? content : Array.isArray(content) ? content.map((c: { text?: string }) => c.text ?? "").join("") : "");

/**
 * One reply for every request the engine makes. A conversation's requests (the ones with a `TEST:<name>` marker in a
 * user message and its tools) are recorded under that name; the rest (titles, follow-ups) just get an answer.
 * A user message containing `READ <file>` gets a read call first.
 */
function reply(requests: Map<string, string[][]>): FauxResponseStep {
	return (context) => {
		const messages = context.messages as { role: string; content?: unknown }[];
		const marker = messages.map((m) => (m.role === "user" ? /TEST:(\w+)/.exec(textOf(m.content))?.[1] : undefined)).find(Boolean);
		const system = messages[0] as { role: string; toolsAdded?: unknown[] } | undefined;
		if (marker && (system?.toolsAdded?.length ?? 0) > 3) {
			const list = requests.get(marker) ?? [];
			list.push(blocks(context));
			requests.set(marker, list);
		}
		const last = messages.at(-1);
		const read = last?.role === "user" ? /READ (\S+)/.exec(textOf(last.content))?.[1] : undefined;
		if (read) return fauxAssistantMessage([fauxToolCall("read", { path: read })], { stopReason: "toolUse" });
		const remember = last?.role === "user" ? /REMEMBER (.+)$/m.exec(textOf(last.content))?.[1] : undefined;
		if (remember) return fauxAssistantMessage([fauxToolCall("remember", { fact: remember })], { stopReason: "toolUse" });
		return fauxAssistantMessage("Done.");
	};
}

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-prefix-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const requests = new Map<string, string[][]>();
	engine.hub.faux!.setResponses(Array.from({ length: 400 }, () => reply(requests)));
	const ctx = { home, engine, client, requests };
	open.push(ctx);
	return ctx;
}

/** An agent past its first-run interview, so it's offered for @mentions and talks plainly. */
async function agent(a: Ctx, name: string): Promise<unknown> {
	const { ref } = await a.client.call("agents.create", { name, owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const got = await a.client.call("agents.get", { ref });
	await a.client.call("agents.save", { ref, definition: { ...(got.definition as object), interview: undefined }, instructions: got.instructions });
	return ref;
}

async function settle(a: Ctx, ref: unknown): Promise<Snapshot> {
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && s.items.some((x) => x.kind === "assistant")) return s;
		await new Promise((r) => setTimeout(r, 30));
	}
	throw new Error("the conversation didn't settle");
}

async function turn(a: Ctx, ref: unknown, text: string): Promise<void> {
	const before = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.filter((i) => i.kind === "user").length;
	await a.client.call("sessions.submit", { ref, input: { text } });
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && s.items.filter((x) => x.kind === "user").length > before && s.items.at(-1)?.kind === "assistant") return;
		await new Promise((r) => setTimeout(r, 30));
	}
	throw new Error(`no answer to ${text}`);
}

/** Where each request stopped starting with the previous one: "request 3: block 0 (of 5) changed". */
function breaks(requests: string[][] | undefined): string[] {
	const out: string[] = [];
	if (!requests || requests.length < 2) return [`only ${requests?.length ?? 0} request(s) recorded`];
	for (let n = 1; n < requests.length; n++) {
		const prev = requests[n - 1]!;
		const next = requests[n]!;
		const at = prev.findIndex((b, i) => next[i] !== b);
		if (at >= 0) out.push(`request ${n + 1}: block ${at} of ${prev.length} changed${at === 0 ? ` (the system prompt)\n${diff(prev[0]!, next[0]!)}` : ""}`);
	}
	return out;
}

/**
 * How much of the conversation an ideal prefix cache could reuse: over requests 2…n, the bytes before the first
 * block that changed, out of all the bytes sent.
 */
function reuse(requests: string[][] | undefined): string {
	if (!requests || requests.length < 2) return "n/a";
	let kept = 0;
	let total = 0;
	for (let n = 1; n < requests.length; n++) {
		const prev = requests[n - 1]!;
		const next = requests[n]!;
		const at = prev.findIndex((b, i) => next[i] !== b);
		const same = at < 0 ? prev.length : at;
		kept += next.slice(0, same).reduce((sum, b) => sum + b.length, 0);
		total += next.reduce((sum, b) => sum + b.length, 0);
	}
	return `${Math.round((100 * kept) / total)}% of ${Math.round(total / 1000)}k chars over ${requests.length - 1} requests`;
}

/** The first place two blocks differ, with some text around it. */
function diff(a: string, b: string): string {
	let i = 0;
	while (i < a.length && a[i] === b[i]) i++;
	return `  was: …${a.slice(Math.max(0, i - 60), i + 80)}…\n  now: …${b.slice(Math.max(0, i - 60), i + 80)}…`;
}

test("Build: a plain conversation, a tool step included, keeps its prefix", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-prefix-build-")));
	writeFileSync(join(folder, "notes.md"), "Some notes.");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await turn(a, ref, "TEST:build Hello");
	await turn(a, ref, "READ notes.md");
	await turn(a, ref, "Thanks");
	await settle(a, ref);
	expect(breaks(a.requests.get("build"))).toEqual([]);
});

test.fails("Build: an edit to NOTES.md between turns changes the system prompt (spec 38 T3)", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-prefix-notes-")));
	writeFileSync(join(folder, "NOTES.md"), "- The sink moves 40 cm left.\n");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await turn(a, ref, "TEST:notes Hello");
	writeFileSync(join(folder, "NOTES.md"), "- The sink moves 40 cm left.\n- Tiles arrive on Friday.\n");
	await turn(a, ref, "And now?");
	expect(breaks(a.requests.get("notes"))).toEqual([]);
});

test("Chat: a plain conversation keeps its prefix", async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } });
	await turn(a, ref, "TEST:chat Hello");
	await turn(a, ref, "Tell me more");
	await turn(a, ref, "Thanks");
	expect(breaks(a.requests.get("chat"))).toEqual([]);
});

test.fails("Chat: About me changing between turns changes the system prompt (spec 38 T3)", async () => {
	const a = await start();
	await a.client.call("settings.set", { aboutMe: { enabled: true, inThreads: true } });
	await a.client.call("aboutMe.set", { text: "- Lives in Valencia" });
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } });
	await turn(a, ref, "TEST:aboutme Hello");
	await a.client.call("aboutMe.set", { text: "- Lives in Valencia\n- Has a dog called Kiwi" });
	await turn(a, ref, "And now?");
	expect(breaks(a.requests.get("aboutme"))).toEqual([]);
});

test.fails("Agent: what memory recalls for each message changes the system prompt (spec 38 T2)", async () => {
	const a = await start();
	const ref = await agent(a, "Pinpin");
	await turn(a, ref, "TEST:agent REMEMBER The dog is called Kiwi");
	await turn(a, ref, "What does Kiwi eat?");
	await turn(a, ref, "Thanks");
	expect(breaks(a.requests.get("agent"))).toEqual([]);
});

test.fails("Build: an @mention changes the system prompt for its turn and again after (spec 38 T2)", async () => {
	const a = await start();
	await agent(a, "Pinpin");
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-prefix-mention-")));
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await turn(a, ref, "TEST:mention Hello");
	await turn(a, ref, "@Pinpin what do you think?");
	await turn(a, ref, "Thanks");
	expect(breaks(a.requests.get("mention"))).toEqual([]);
});

test("diagnostics: what breaks today", async () => {
	if (!process.env.PIOPIO_PREFIX_REPORT) return;
	const report: string[] = [];
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-prefix-report-")));
	writeFileSync(join(folder, "NOTES.md"), "- One.\n");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await turn(a, ref, "TEST:report Hello");
	writeFileSync(join(folder, "NOTES.md"), "- One.\n- Two.\n");
	await turn(a, ref, "READ NOTES.md");
	report.push("Build with a NOTES.md edit:", ...breaks(a.requests.get("report")));
	await a.client.call("settings.set", { aboutMe: { enabled: true, inThreads: true } });
	await a.client.call("aboutMe.set", { text: "- Lives in Valencia" });
	const chat = (await a.client.call("sessions.create", { kind: "thread", model: { provider: "faux", id: "faux-1" } })).ref;
	await turn(a, chat, "TEST:reportchat Hello");
	await a.client.call("aboutMe.set", { text: "- Lives in Valencia\n- Has a dog called Kiwi" });
	await turn(a, chat, "And now?");
	report.push("Chat with an About me change:", ...breaks(a.requests.get("reportchat")));
	const pinpin = await agent(a, "Pinpin");
	await turn(a, pinpin, "TEST:reportagent REMEMBER The dog is called Kiwi");
	await turn(a, pinpin, "What does Kiwi eat?");
	report.push("Agent with memory:", ...breaks(a.requests.get("reportagent")));
	const plain = (await a.client.call("sessions.create", { kind: "build", cwd: folder })).ref;
	for (const text of ["TEST:reportplain Hello", "READ NOTES.md", "Thanks", "One more", "Last one"]) await turn(a, plain, text);
	const mention = (await a.client.call("sessions.create", { kind: "build", cwd: folder })).ref;
	for (const text of ["TEST:reportmention Hello", "@Pinpin what do you think?", "Thanks", "One more", "Last one"]) await turn(a, mention, text);
	await turn(a, pinpin, "TEST:reportagent5 REMEMBER Kiwi eats salmon");
	for (const text of ["What does Kiwi eat?", "And the dog's name?", "Thanks", "Who is Kiwi?"]) await turn(a, pinpin, text);
	report.push(
		"",
		"Reuse an ideal prefix cache gets (higher is better):",
		`- Build, 5 plain turns: ${reuse(a.requests.get("reportplain"))}`,
		`- Build, 5 turns with one @mention: ${reuse(a.requests.get("reportmention"))}`,
		`- Build, NOTES.md edited: ${reuse(a.requests.get("report"))}`,
		`- Chat, About me changed: ${reuse(a.requests.get("reportchat"))}`,
		`- Agent, 7 messages with memory: ${reuse(a.requests.get("reportagent"))}`,
	);
	process.stdout.write(`\n${report.join("\n")}\n`);
});
