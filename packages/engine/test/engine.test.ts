import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { SessionEvent, Snapshot } from "@piopio/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { titleFrom } from "../src/sessions.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-test-")), faux = true): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), allowPrivateFetch: true, log: () => {} });
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

const settled = (subscriptionId: string, after = 0) => (n: { subscriptionId: string; seq: number; events: SessionEvent[] }) =>
	n.subscriptionId === subscriptionId && n.seq > after && n.events.some((e) => e.type === "state" && e.state.status === "idle");

const texts = (s: Snapshot) => s.items.map((i) => [i.kind, i.kind === "user" ? i.text : i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : ""]);

describe.each(["thread", "build"] as const)("%s session", (kind) => {
	test("streams an answer and keeps ids stable across an engine restart", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: a.home } : {}) });
		const sub = await a.client.call("sessions.subscribe", { ref });
		expect(sub.snapshot.items).toEqual([]);

		const res = await a.client.call("sessions.submit", { ref, input: { text: "hello piopio" } });
		expect(res).toEqual({ accepted: true, disposition: "started" });
		await a.client.waitFor(settled(sub.subscriptionId, 1));

		const events = a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).flatMap((n) => n.events);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "user")).toBe(true);
		expect(events.some((e) => e.type === "item.added" && e.item.kind === "assistant")).toBe(true);

		const live: Snapshot = await a.client.call("sessions.open", { ref });
		expect(texts(live)).toEqual([
			["user", "hello piopio"],
			["assistant", "Echo: hello piopio"],
		]);
		expect(live.state.status).toBe("idle");
		const [list] = (await a.client.call("sessions.list")).sessions;
		expect(list.title).toBe("hello piopio");

		await stop(a);
		const b = await start(a.home);
		const reopened: Snapshot = await b.client.call("sessions.open", { ref });
		expect(reopened.items.map((i) => i.id)).toEqual(live.items.map((i) => i.id));
		expect(texts(reopened)).toEqual(texts(live));
	});

	test("queues a follow-up sent while busy", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: a.home } : {}) });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "first message that takes a little while to echo back" } });
		await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.status === "running"));
		const second = await a.client.call("sessions.submit", { ref, input: { text: "second" } });
		expect(second.disposition).toBe("queued");
		await a.client.waitFor((n) => {
			if (n.subscriptionId !== sub.subscriptionId) return false;
			return n.events.some((e) => (e.type === "item.updated" || e.type === "item.replaced" || e.type === "item.added") && e.item.kind === "assistant" && e.item.status === "done" && e.item.parts.some((p) => p.text === "Echo: second"));
		});
	});
});

test("asks the client for the OpenRouter key and reports AUTH when it has none", async () => {
	const a = await start(undefined, false);
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
});

test("rejects bad params and unauthenticated calls", async () => {
	const a = await start();
	await expect(a.client.call("sessions.create", { kind: "nope" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	const other = await TestClient.connect(enginePaths(a.home).socket);
	await expect(other.call("sessions.list")).rejects.toMatchObject({ data: { code: "AUTH" } });
	await expect(other.call("engine.hello", { token: "wrong", client: "x", protocolVersion: "1.0" })).rejects.toMatchObject({ data: { code: "AUTH" } });
	other.close();
});

test("configure, rename and delete a thread, with catalog notifications", async () => {
	const a = await start();
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	const sub = await a.client.call("sessions.subscribe", { ref });
	expect(sub.snapshot.state.model).toEqual({ provider: "faux", id: "faux-1" });

	const { models, defaultModel } = await a.client.call("models.list", {});
	expect(defaultModel).toEqual({ provider: "faux", id: "faux-1" });
	expect(models.some((m: { provider: string }) => m.provider === "openrouter")).toBe(true);
	const other = models.find((m: { provider: string; id: string }) => m.provider === "openrouter" && m.id === "anthropic/claude-haiku-5.5");
	expect(other).toMatchObject({ supports: { reasoning: true }, pricing: { input: expect.any(Number) } });

	await a.client.call("sessions.configure", { ref, model: { provider: "openrouter", id: other.id }, thinking: "low" });
	const opened: Snapshot = await a.client.call("sessions.open", { ref });
	expect(opened.state.model).toEqual({ provider: "openrouter", id: other.id });
	expect(opened.state.thinking).toBe("low");
	await expect(a.client.call("sessions.configure", { ref, model: { provider: "openrouter", id: "nope/nope" } })).rejects.toMatchObject({ data: { code: "INVALID" } });

	await a.client.call("sessions.rename", { ref, title: "Renamed" });
	expect(a.client.notifications.some((n) => n.method === "catalog.changed" && n.params.upserted.some((s: { title: string }) => s.title === "Renamed"))).toBe(true);

	await a.client.call("sessions.delete", { ref });
	expect((await a.client.call("sessions.list")).sessions).toEqual([]);
	expect(existsSync(join(a.home, "threads", `${ref.id}.sqlite`))).toBe(false);
	expect(a.client.notifications.some((n) => n.method === "catalog.changed" && n.params.removed.some((r: { id: string }) => r.id === ref.id))).toBe(true);
});

test("secrets.changed makes the engine ask for the key again", async () => {
	const a = await start(undefined, false);
	let asked = 0;
	a.client.secrets = new Proxy({}, { get: () => (asked++, "") }) as Record<string, string>;
	const { ref } = await a.client.call("sessions.create", { kind: "thread" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
	await a.client.call("secrets.changed", { name: "provider.openrouter.apiKey" });
	await expect(a.client.call("sessions.submit", { ref, input: { text: "hi" } })).rejects.toMatchObject({ data: { code: "AUTH" } });
	expect(asked).toBeGreaterThanOrEqual(2);
});

test("titles are plain text", () => {
	expect(titleFrom("Here is **bold**, `code` and a [link](https://example.com).\n\n- one")).toBe("Here is bold, code and a link. - one");
	expect(titleFrom("```ts\nconst a = 1\n```\nWhy?")).toBe("Why?");
	expect(titleFrom("Explain this:\n\n| Col | Val |\n|---|---|\n| x | 1 |")).toBe("Explain this:");
	expect(titleFrom("a ".repeat(50)).length).toBeLessThanOrEqual(61);
});

describe("thread branches", () => {
	const texts2 = (s: Snapshot) => s.items.filter((i) => i.kind !== "system").map((i) => (i.kind === "user" ? `> ${i.text}` : i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : i.kind));

	async function ask(a: Ctx, ref: unknown, sub: { subscriptionId: string }, text: string) {
		const before = a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).length;
		await a.client.call("sessions.submit", { ref, input: { text } });
		await waitIdle(a, sub, before);
	}

	async function waitIdle(a: Ctx, sub: { subscriptionId: string }, afterBatches: number) {
		await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && a.client.events.filter((m) => m.subscriptionId === sub.subscriptionId).indexOf(n) >= afterBatches && n.events.some((e) => e.type === "item.replaced" || (e.type === "state" && e.state.status === "idle")) && n.events.some((e) => e.type === "state" && e.state.status === "idle"));
	}

	async function settle(a: Ctx, ref: unknown): Promise<Snapshot> {
		for (let i = 0; i < 100; i++) {
			const s: Snapshot = await a.client.call("sessions.open", { ref });
			if (s.state.status === "idle" && s.items.at(-1)?.kind === "assistant") return s;
			await new Promise((r) => setTimeout(r, 30));
		}
		throw new Error("did not settle");
	}

	test("edit, switch, regenerate the first message, and survive a restart", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await ask(a, ref, sub, "first");
		await ask(a, ref, sub, "second");
		let s = await settle(a, ref);
		const second = s.items.filter((i) => i.kind === "user")[1]!;

		await a.client.call("sessions.edit", { ref, itemId: second.id, text: "second, edited" });
		s = await settle(a, ref);
		expect(texts2(s)).toEqual(["> first", "Echo: first", "> second, edited", "Echo: second, edited"]);
		const edited = s.items.filter((i) => i.kind === "user")[1]!;
		expect(edited.kind === "user" && edited.branch).toMatchObject({ index: 1, count: 2, previous: expect.any(String) });
		expect(a.client.events.some((n) => n.events.some((e) => e.type === "resnapshot"))).toBe(true);

		await a.client.call("sessions.switchBranch", { ref, branch: edited.kind === "user" ? edited.branch!.previous : "" });
		s = await settle(a, ref);
		expect(texts2(s)).toEqual(["> first", "Echo: first", "> second", "Echo: second"]);
		const original = s.items.filter((i) => i.kind === "user")[1]!;
		expect(original.kind === "user" && original.branch).toMatchObject({ index: 0, count: 2, next: expect.any(String) });

		const firstAnswer = s.items.find((i) => i.kind === "assistant")!;
		await a.client.call("sessions.regenerate", { ref, itemId: firstAnswer.id });
		s = await settle(a, ref);
		expect(texts2(s)).toEqual(["> first", "Echo: first"]);
		const first = s.items.find((i) => i.kind === "user")!;
		expect(first.kind === "user" && first.branch).toMatchObject({ index: 1, count: 2 });

		await stop(a);
		const b = await start(a.home);
		s = await settle(b, ref);
		expect(texts2(s)).toEqual(["> first", "Echo: first"]);
	});

	test("queued messages show their text and can be withdrawn", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "a long first message that keeps the model busy for a little while" } });
		await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.status === "running"));
		await a.client.call("sessions.submit", { ref, input: { text: "queued one" } });
		await a.client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.events.some((e) => e.type === "state" && e.state.queue.some((q) => q.text === "queued one")));
		const queued = ((await a.client.call("sessions.open", { ref })) as Snapshot).state.queue[0]!;
		await a.client.call("sessions.queue.remove", { ref, queueId: queued.id });
		const s = await settle(a, ref);
		expect(s.state.queue).toEqual([]);
		expect(s.items.some((i) => i.kind === "user" && i.text === "queued one")).toBe(false);
	});

	test("fork copies a thread up to a message into a new thread", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await ask(a, ref, sub, "one");
		await ask(a, ref, sub, "two");
		const s = await settle(a, ref);
		const firstAnswer = s.items.find((i) => i.kind === "assistant")!;
		const { ref: copy } = await a.client.call("sessions.fork", { ref, itemId: firstAnswer.id });
		expect(copy.id).not.toBe(ref.id);
		const forked: Snapshot = await a.client.call("sessions.open", { ref: copy });
		expect(texts2(forked)).toEqual(["> one", "Echo: one"]);
		expect(texts2(await settle(a, ref))).toEqual(["> one", "Echo: one", "> two", "Echo: two"]);
		expect((await a.client.call("sessions.list")).sessions.map((x: { title: string }) => x.title)).toContain("one (branch)");
	});
});

describe("milestone 1.3", () => {
	async function settled(a: Ctx, ref: unknown, kinds = 2): Promise<Snapshot> {
		for (let i = 0; i < 200; i++) {
			const s: Snapshot = await a.client.call("sessions.open", { ref });
			if (s.state.status === "idle" && s.items.filter((x) => x.kind === "assistant").length >= kinds - 1 && s.items.at(-1)?.kind === "assistant") return s;
			await new Promise((r) => setTimeout(r, 30));
		}
		throw new Error("did not settle");
	}

	test("text attachments show as chips, reach the model, and survive an edit", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "Summarize", attachments: [{ kind: "text", name: "notes.md", text: "Durable objects are neat." }] } });
		let s = await settled(a, ref);
		const user = s.items.find((i) => i.kind === "user")!;
		expect(user).toMatchObject({ kind: "user", text: "Summarize", attachments: [{ name: "notes.md", kind: "text" }] });
		const answer = s.items.find((i) => i.kind === "assistant")!;
		expect(answer.kind === "assistant" && answer.parts.map((p) => p.text).join("")).toContain("Durable objects are neat.");

		await a.client.call("sessions.edit", { ref, itemId: user.id, text: "Summarize in one word" });
		s = await settled(a, ref);
		expect(s.items.find((i) => i.kind === "user")).toMatchObject({ text: "Summarize in one word", attachments: [{ name: "notes.md" }] });
		const reopened = await (async () => { await stop(a); const b = await start(a.home); return settled(b, ref); })();
		expect(reopened.items.find((i) => i.kind === "user")).toMatchObject({ attachments: [{ name: "notes.md" }] });
	});

	test("images need a vision model", async () => {
		const a = await start();
		const { models } = await a.client.call("models.list", {});
		const blind = models.find((m: { provider: string; supports: { vision: boolean } }) => m.provider === "openrouter" && !m.supports.vision);
		const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "openrouter", id: blind.id } });
		await expect(a.client.call("sessions.submit", { ref, input: { text: "what is this", attachments: [{ kind: "image", name: "x.png", mimeType: "image/png", data: "iVBORw0KGgo=" }] } })).rejects.toMatchObject({ data: { code: "INVALID" } });
	});

	test("web_fetch reads a page through a tool call; the web toggle is per thread", async () => {
		const { createServer } = await import("node:http");
		const server = createServer((_, res) => {
			res.writeHead(200, { "content-type": "text/html" });
			res.end("<html><head><title>Lab page</title></head><body><main><h1>Piopio facts</h1><p>Piopio is a <b>native</b> app.</p></main></body></html>");
		});
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
		const port = (server.address() as { port: number }).port;
		const a = await start();
		const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai");
		a.engine.hub.faux!.setResponses([
			fauxAssistantMessage([fauxToolCall("web_fetch", { url: `http://127.0.0.1:${port}/page` })], { stopReason: "toolUse" }),
			fauxAssistantMessage([fauxText("It says Piopio is native.")]),
		]);
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const sub = await a.client.call("sessions.subscribe", { ref });
		expect(sub.snapshot.state.tools).toEqual({ web: true });
		await a.client.call("sessions.submit", { ref, input: { text: "read the page" } });
		const s = await settled(a, ref);
		const tool = s.items.find((i) => i.kind === "tool");
		expect(tool).toMatchObject({ kind: "tool", tool: "web_fetch", status: "done" });
		expect(tool && tool.kind === "tool" && tool.output).toContain("# Piopio facts");
		expect(s.items.at(-1)).toMatchObject({ kind: "assistant", parts: [{ text: "It says Piopio is native." }] });
		server.close();

		await a.client.call("sessions.configure", { ref, web: false });
		expect(((await a.client.call("sessions.open", { ref })) as Snapshot).state.tools).toEqual({ web: false });
	});

	test("export as markdown, html and jsonl", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "Hello **world**" } });
		await settled(a, ref);
		const md = await a.client.call("sessions.export", { ref, format: "markdown" });
		expect(md).toMatchObject({ filename: "Hello world.md", mimeType: "text/markdown" });
		expect(md.content).toContain("## You\n\nHello **world**");
		expect(md.content).toContain("## Assistant (faux/faux-1)\n\nEcho: Hello **world**");
		const html = await a.client.call("sessions.export", { ref, format: "html" });
		expect(html.content).toContain("<strong>world</strong>");
		const jsonl = await a.client.call("sessions.export", { ref, format: "jsonl" });
		expect(jsonl.content.trim().split("\n").map((l: string) => JSON.parse(l).kind)).toEqual(["user", "assistant"]);
	});
});

test("search finds messages across threads, follows renames and deletes, and backfills", async () => {
	const a = await start();
	const ask = async (text: string) => {
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text } });
		for (let i = 0; i < 100; i++) {
			const s: Snapshot = await a.client.call("sessions.open", { ref });
			if (s.state.status === "idle" && s.items.at(-1)?.kind === "assistant") break;
			await new Promise((r) => setTimeout(r, 30));
		}
		return ref;
	};
	const kitchen = await ask("Where should the dishwasher go?");
	const rust = await ask("Explain lifetimes in Rust");

	let { results } = await a.client.call("catalog.search", { query: "dishwash" });
	expect(results.map((r: { kind: string }) => r.kind).sort()).toEqual(["assistant", "title", "user"]);
	expect(results.find((r: { kind: string }) => r.kind === "user")).toMatchObject({ ref: kitchen, title: "Where should the dishwasher go?", snippet: expect.stringContaining("\u0002dishwasher\u0003") });

	await a.client.call("sessions.rename", { ref: rust, title: "Borrow checker" });
	expect((await a.client.call("catalog.search", { query: "borrow" })).results[0]).toMatchObject({ ref: rust, kind: "title" });
	await a.client.call("sessions.delete", { ref: kitchen });
	expect((await a.client.call("catalog.search", { query: "dishwasher" })).results).toEqual([]);

	await stop(a);
	for (const f of ["search.db", "search.db-wal", "search.db-shm"]) rmSync(join(a.home, f), { force: true });
	const b = await start(a.home);
	expect(await b.engine.backfill).toBe(1);
	expect((await b.client.call("catalog.search", { query: "lifetimes" })).results.map((r: { kind: string }) => r.kind).sort()).toEqual(["assistant", "user"]);
});

describe("projects", () => {
	/** A session file as the pi CLI would leave it: one exchange, persisted by pi's SessionManager. */
	function cliSession(cwd: string, dir: string, text: string): string {
		const sm = SessionManager.create(cwd, dir);
		const now = Date.now();
		sm.appendMessage({ role: "user", content: text, timestamp: now } as never);
		sm.appendMessage({
			role: "assistant",
			content: [{ type: "text", text: `CLI says: ${text}` }],
			api: "openai-completions",
			provider: "faux",
			model: "faux-1",
			usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			stopReason: "stop",
			timestamp: now + 1,
		} as never);
		return sm.getSessionFile()!;
	}

	test("add a folder, import and open pi CLI sessions, follow new and deleted files, forget the folder", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-project-")));
		mkdirSync(join(folder, ".git"));
		writeFileSync(join(folder, ".git", "HEAD"), "ref: refs/heads/main\n");
		writeFileSync(join(folder, "AGENTS.md"), "# Agents\n");
		const piDir = join(a.home, "pi-sessions");
		const first = cliSession(folder, piDir, "Hello from the CLI");

		const { project } = await a.client.call("projects.add", { path: folder });
		expect(project).toMatchObject({ path: folder, name: basename(folder), branch: "main", contextFile: "AGENTS.md", piConfig: false });
		expect((await a.client.call("projects.add", { path: folder })).project.id).toBe(project.id);
		expect(a.client.notifications.some((n) => n.method === "projects.changed")).toBe(true);

		const [imported] = (await a.client.call("sessions.list", { kind: "build" })).sessions;
		expect(imported).toMatchObject({ title: "Hello from the CLI", cwd: folder });
		const snapshot: Snapshot = await a.client.call("sessions.open", { ref: imported.ref });
		expect(texts(snapshot)).toEqual([
			["user", "Hello from the CLI"],
			["assistant", "CLI says: Hello from the CLI"],
		]);

		// A session written while the engine runs shows up; a deleted one goes away.
		const changed = (predicate: (c: { upserted: { title: string }[]; removed: unknown[] }) => boolean) =>
			new Promise<void>((resolve, reject) => {
				const t = setTimeout(() => reject(new Error("no catalog.changed")), 5000);
				const check = setInterval(() => {
					if (a.client.notifications.some((n) => n.method === "catalog.changed" && predicate(n.params))) {
						clearTimeout(t);
						clearInterval(check);
						resolve();
					}
				}, 50);
			});
		const second = cliSession(folder, piDir, "Second CLI session");
		await changed((c) => c.upserted.some((s) => s.title === "Second CLI session"));
		rmSync(second);
		await changed((c) => c.removed.length > 0);
		expect((await a.client.call("sessions.list", { kind: "build" })).sessions.map((s: { title: string }) => s.title)).toEqual(["Hello from the CLI"]);

		// Deleting a build session trashes its file, so it isn't found again.
		const third = cliSession(folder, piDir, "Third CLI session");
		await changed((c) => c.upserted.some((s) => s.title === "Third CLI session"));
		const thirdRef = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { title: string }) => s.title === "Third CLI session").ref;
		await a.client.call("sessions.delete", { ref: thirdRef });
		expect(existsSync(third)).toBe(false);
		expect(existsSync(join(a.home, "trash", basename(third)))).toBe(true);
		await a.client.call("projects.add", { path: folder }); // re-syncs the folder
		expect((await a.client.call("sessions.list", { kind: "build" })).sessions.map((s: { title: string }) => s.title)).toEqual(["Hello from the CLI"]);

		await a.client.call("projects.remove", { id: project.id });
		expect((await a.client.call("projects.list")).projects).toEqual([]);
		expect((await a.client.call("sessions.list", { kind: "build" })).sessions).toEqual([]);
		expect(existsSync(first)).toBe(true);
	});
});

test("build tool cards: the scripted model edits, writes and runs commands; details survive a reopen", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-tools-")));
	writeFileSync(join(folder, "notes.txt"), "hello world\n");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const sub = await a.client.call("sessions.subscribe", { ref });
	await a.client.call("sessions.configure", { ref, approvalMode: "full_auto" }); // cards, not approvals
	const script = ["read: notes.txt", "edit: notes.txt | hello world | hello piopio", "write: new.md | # New\\nline two", "$ exit 3"].join("\n");
	await a.client.call("sessions.submit", { ref, input: { text: script } });
	await a.client.waitFor(settled(sub.subscriptionId, 1), 20_000);
	const details = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "tool" ? [[i.tool, i.status, i.details]] : []));
	const live: Snapshot = await a.client.call("sessions.open", { ref });
	expect(readFileSync(join(folder, "notes.txt"), "utf8")).toBe("hello piopio\n");
	expect(details(live)).toEqual([
		["read", "done", { type: "file", path: "notes.txt", language: "txt" }],
		["edit", "done", { type: "diff", path: "notes.txt", diff: expect.stringContaining("+hello piopio") }],
		["write", "done", { type: "diff", path: "new.md", diff: "@@ -0,0 +1,2 @@\n+# New\n+line two" }],
		["bash", "error", { type: "terminal", command: "exit 3", exitCode: 3 }],
	]);
	expect(live.state.context?.window).toBeGreaterThan(0);

	await stop(a);
	const b = await start(a.home);
	expect(details(await b.client.call("sessions.open", { ref }))).toEqual(details(live));
});

describe("approvals and questions (docs/spec/05-build §6)", () => {
	type State = Snapshot["state"];
	async function buildSession(a: Ctx, folder: string) {
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		const sub = await a.client.call("sessions.subscribe", { ref });
		return { ref, sub: sub.subscriptionId as string };
	}
	/** The latest state of a subscription once it satisfies `predicate`. */
	async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
		const latest = () => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e) => e.type === "state").at(-1) as { state: State } | undefined;
		await a.client.waitFor(() => Boolean(latest() && predicate(latest()!.state)), 15_000);
		return latest()!.state;
	}
	const tools = async (a: Ctx, ref: unknown) => ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "tool" ? [i] : []));

	async function newProject(a: Ctx) {
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-approvals-")));
		const { project } = await a.client.call("projects.add", { path: folder });
		return { folder, project };
	}

	test("auto-edit asks before commands; Always allow adds a project rule that later sessions use", async () => {
		const a = await start();
		const { folder, project } = await newProject(a);
		expect(project.approvalMode).toBe("auto_edit");
		const s = await buildSession(a, folder);
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "$ echo first" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.approvalMode).toBe("auto_edit");
		const [prompt] = waiting.prompts!;
		expect(prompt).toMatchObject({ kind: "approval", title: "Run a command", detail: "echo first", tool: "bash", rule: { kind: "command", pattern: "echo" } });
		expect((await tools(a, s.ref))[0]?.status).toBe("pending_approval");

		// A second client (the app after a restart) sees the same pending request.
		const other = await TestClient.connect(a.engine["options"].paths.socket);
		await other.call("engine.hello", { token: readFileSync(join(a.home, "engine.token"), "utf8").trim(), client: "test2", protocolVersion: "1.0" });
		expect(((await other.call("sessions.subscribe", { ref: s.ref })).snapshot as Snapshot).state.prompts?.map((p) => p.id)).toEqual([prompt!.id]);
		other.close();

		await a.client.call("sessions.respond", { ref: s.ref, promptId: prompt!.id, response: { decision: "always" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		expect((await tools(a, s.ref))[0]).toMatchObject({ status: "done", output: expect.stringContaining("first") });
		expect((await a.client.call("projects.list")).projects[0].rules).toMatchObject([{ kind: "command", pattern: "echo" }]);

		const t = await buildSession(a, folder);
		await a.client.call("sessions.submit", { ref: t.ref, input: { text: "$ echo second" } });
		const done = await stateWhere(a, t.sub, (st) => st.status === "idle" || st.status === "waiting_approval");
		expect(done.status).toBe("idle");
		expect((await tools(a, t.ref))[0]?.status).toBe("done");
	});

	test("the deny-list asks even in full auto; Deny sends the note to the agent", async () => {
		const a = await start();
		const { folder, project } = await newProject(a);
		await a.client.call("projects.configure", { id: project.id, approvalMode: "full_auto" });
		const s = await buildSession(a, folder);
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "$ git push --force origin main" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.approvalMode).toBe("full_auto");
		expect(waiting.prompts![0]).toMatchObject({ reason: "Force-pushes" });
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "deny", text: "never force-push main" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		const [tool] = await tools(a, s.ref);
		expect(tool).toMatchObject({ status: "denied", output: "The user denied this tool call: never force-push main" });
		// "denied" survives a reopen from the session file.
		await stop(a);
		const b = await start(a.home);
		expect((await tools(b, s.ref))[0]?.status).toBe("denied");
	});

	test("ask mode asks before edits; switching the session to full auto stops asking", async () => {
		const a = await start();
		const { folder } = await newProject(a);
		writeFileSync(join(folder, "a.txt"), "one\n");
		const s = await buildSession(a, folder);
		await a.client.call("sessions.configure", { ref: s.ref, approvalMode: "ask" });
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "edit: a.txt | one | two" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ title: "Edit a file", detail: "a.txt" });
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		expect(readFileSync(join(folder, "a.txt"), "utf8")).toBe("two\n");

		await a.client.call("sessions.configure", { ref: s.ref, approvalMode: "full_auto" });
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "edit: a.txt | two | three" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle" && st.approvalMode === "full_auto");
		expect(readFileSync(join(folder, "a.txt"), "utf8")).toBe("three\n");
	});

	test("ask_user waits for an answer; stopping while waiting cancels the request", async () => {
		const a = await start();
		const { folder } = await newProject(a);
		const s = await buildSession(a, folder);
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "ask: Which database? | Postgres | SQLite" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ kind: "question", title: "Which database?", options: ["Postgres", "SQLite"] });
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { choice: "SQLite" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		expect((await tools(a, s.ref))[0]).toMatchObject({ tool: "ask_user", status: "done", output: "The user answered: SQLite" });

		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "$ rm -rf /" } });
		await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		await a.client.call("sessions.abort", { ref: s.ref });
		const after = await stateWhere(a, s.sub, (st) => st.status === "idle");
		expect(after.prompts).toEqual([]);
		expect((await tools(a, s.ref)).at(-1)?.status).toBe("interrupted");
	});
});

test("checkpoints: before each turn's first change, with changes, diff, restore and a note for the agent", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-checkpoints-")));
	writeFileSync(join(folder, "a.txt"), "one\n");
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await a.client.call("sessions.configure", { ref, approvalMode: "full_auto" });
	const sub = await a.client.call("sessions.subscribe", { ref });
	const kinds = (s: Snapshot) => s.items.map((i) => (i.kind === "checkpoint" ? `checkpoint:${i.label}` : i.kind === "tool" ? `tool:${i.tool}` : i.kind));

	await a.client.call("sessions.submit", { ref, input: { text: "edit: a.txt | one | two\nwrite: b.txt | new file" } });
	await a.client.waitFor(settled(sub.subscriptionId, 1), 20_000);
	let seq = Math.max(...a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).map((n) => n.seq));
	// Live, the checkpoint was inserted before the edit it precedes.
	const added = a.client.events.flatMap((n) => n.events).find((e) => e.type === "item.added" && e.item.kind === "checkpoint") as { before?: string } | undefined;
	expect(added?.before).toMatch(/^tool:/);

	expect(await a.client.call("sessions.changes", { ref, since: "session" })).toMatchObject({
		files: [
			{ path: "a.txt", status: "modified", added: 1, removed: 1 },
			{ path: "b.txt", status: "added", added: 1, removed: 0 },
		],
	});
	expect((await a.client.call("sessions.diff", { ref, path: "a.txt", since: "session" })).patch).toContain("-one\n+two");

	await a.client.call("sessions.submit", { ref, input: { text: "edit: a.txt | two | three" } });
	await a.client.waitFor(settled(sub.subscriptionId, seq), 20_000);
	seq = Math.max(...a.client.events.filter((n) => n.subscriptionId === sub.subscriptionId).map((n) => n.seq));
	const live: Snapshot = await a.client.call("sessions.open", { ref });
	expect(kinds(live)).toEqual(["user", "assistant", "checkpoint:Session start", "tool:edit", "assistant", "tool:write", "assistant", "user", "assistant", "checkpoint:Before turn 2", "tool:edit", "assistant"]);
	const [first, second] = live.items.filter((i) => i.kind === "checkpoint");
	expect(second).toMatchObject({ files: 2 });
	expect((await a.client.call("sessions.changes", { ref, since: "turn" })).files).toEqual([{ path: "a.txt", status: "modified", added: 1, removed: 1 }]);

	const preview = await a.client.call("sessions.restore", { ref, checkpointId: first!.kind === "checkpoint" ? first.checkpointId : "", dryRun: true });
	expect(preview.files.map((f: { path: string }) => f.path)).toEqual(["a.txt", "b.txt"]);
	expect(readFileSync(join(folder, "a.txt"), "utf8")).toBe("three\n");
	const restored = await a.client.call("sessions.restore", { ref, checkpointId: first!.kind === "checkpoint" ? first.checkpointId : "" });
	expect(restored.files.map((f: { path: string; status: string }) => `${f.status} ${f.path}`)).toEqual(["modified a.txt", "added b.txt"]);
	expect(readFileSync(join(folder, "a.txt"), "utf8")).toBe("one\n");
	expect(existsSync(join(folder, "b.txt"))).toBe(false);
	const after: Snapshot = await a.client.call("sessions.open", { ref });
	expect(kinds(after).slice(-2)).toEqual(["checkpoint:Before restore", "system"]);
	expect(after.items.at(-1)).toMatchObject({ kind: "system", text: "Restored 2 files to “Session start”. The agent was told." });

	// Everything is rebuilt from the pi session file in the same order.
	await stop(a);
	const b = await start(a.home);
	expect(kinds(await b.client.call("sessions.open", { ref }))).toEqual(kinds(after));
	// Since the latest checkpoint ("Before restore"), the restore itself is what changed.
	expect((await b.client.call("sessions.changes", { ref, since: "turn" })).files.map((f: { path: string; status: string }) => `${f.status} ${f.path}`)).toEqual(["modified a.txt", "deleted b.txt"]);
});

describe("git and worktrees (docs/spec/05-build §8, BP5)", () => {
	const sh = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	function repo() {
		const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-git-")));
		sh(dir, "init", "-q", "-b", "main");
		sh(dir, "config", "user.email", "t@example.com");
		sh(dir, "config", "user.name", "Test");
		writeFileSync(join(dir, "a.txt"), "one\n");
		sh(dir, "add", ".");
		sh(dir, "commit", "-qm", "Initial commit");
		return dir;
	}

	test("a worktree session works on its own branch, commits, and merges back", async () => {
		const a = await start();
		const dir = repo();
		await a.client.call("projects.add", { path: dir });
		const { branch } = await a.client.call("git.suggestBranch", { prompt: "Add the WebSocket transport, please!" });
		expect(branch).toBe("piopio/add-websocket-transport");
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: dir, workOn: { kind: "worktree", branch }, approvalMode: "full_auto" });
		const summary = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id);
		expect(summary).toMatchObject({ projectPath: dir, worktree: { branch, base: "main" } });
		const worktree = summary.cwd as string;
		expect(worktree.startsWith(join(a.home, "worktrees"))).toBe(true);
		expect(sh(worktree, "branch", "--show-current")).toBe(branch);

		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "edit: a.txt | one | two" } });
		await a.client.waitFor(settled(sub.subscriptionId, 1), 20_000);
		expect(readFileSync(join(worktree, "a.txt"), "utf8")).toBe("two\n");
		expect(readFileSync(join(dir, "a.txt"), "utf8")).toBe("one\n");

		expect((await a.client.call("git.status", { cwd: worktree })).files).toEqual([{ path: "a.txt", status: "modified", staged: false }]);
		await expect(a.client.call("sessions.finish", { ref, action: "merge" })).rejects.toMatchObject({ data: { code: "CONFLICT" } });
		const { message } = await a.client.call("git.message", { cwd: worktree });
		expect(message).toBe("Update a.txt"); // the scripted model has no utility model: a plain summary
		await a.client.call("git.commit", { cwd: worktree, message: "Say two" });

		await a.client.call("sessions.finish", { ref, action: "merge" });
		expect(readFileSync(join(dir, "a.txt"), "utf8")).toBe("two\n");
		expect(sh(dir, "log", "-1", "--format=%s")).toBe("Say two");
		expect(existsSync(worktree)).toBe(false);
		expect(sh(dir, "branch", "--list", branch)).toBe("");
		const after = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id);
		expect(after).toMatchObject({ cwd: dir, worktree: { finished: "merged" } });
	});

	test("discarding a worktree leaves the project untouched; a new branch switches the project", async () => {
		const a = await start();
		const dir = repo();
		await a.client.call("projects.add", { path: dir });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: dir, workOn: { kind: "worktree", branch: "piopio/throwaway" } });
		const worktree = (await a.client.call("sessions.list", { kind: "build" })).sessions[0].cwd as string;
		writeFileSync(join(worktree, "scratch.txt"), "draft\n");
		await a.client.call("sessions.finish", { ref, action: "discard" });
		expect(existsSync(worktree)).toBe(false);
		expect(sh(dir, "branch", "--list", "piopio/throwaway")).toBe("");
		expect(existsSync(join(dir, "scratch.txt"))).toBe(false);

		await a.client.call("sessions.create", { kind: "build", cwd: dir, workOn: { kind: "branch", branch: "feature/x" } });
		expect(sh(dir, "branch", "--show-current")).toBe("feature/x");
		expect((await a.client.call("projects.list")).projects[0].branch).toBe("feature/x");
	});

	test("status, branches, partial commits, and the first push creates the upstream", async () => {
		const a = await start();
		const dir = repo();
		const remote = realpathSync(mkdtempSync(join(tmpdir(), "piopio-remote-")));
		sh(remote, "init", "-q", "--bare");
		sh(dir, "remote", "add", "origin", remote);
		await a.client.call("projects.add", { path: dir });
		await expect(a.client.call("git.status", { cwd: tmpdir() })).rejects.toMatchObject({ data: { code: "INVALID" } });

		writeFileSync(join(dir, "a.txt"), "changed\n");
		writeFileSync(join(dir, "b.txt"), "new\n");
		const s = await a.client.call("git.status", { cwd: dir });
		expect(s).toMatchObject({ repo: true, branch: "main", ahead: 0, behind: 0, files: [{ path: "a.txt", status: "modified" }, { path: "b.txt", status: "untracked" }] });
		expect(s.upstream).toBeUndefined();

		await a.client.call("git.commit", { cwd: dir, message: "Add b", paths: ["b.txt"] });
		expect(sh(dir, "show", "--name-only", "--format=", "HEAD")).toBe("b.txt");
		expect((await a.client.call("git.status", { cwd: dir })).files.map((f: { path: string }) => f.path)).toEqual(["a.txt"]);

		const pushed = await a.client.call("git.sync", { cwd: dir, action: "push" });
		expect(pushed.output).toBeDefined();
		expect((await a.client.call("git.status", { cwd: dir })).upstream).toBe("origin/main");
		await a.client.call("git.checkout", { cwd: dir, branch: "topic", create: true });
		expect((await a.client.call("git.branches", { cwd: dir })).branches.map((b: { name: string; current: boolean }) => `${b.current ? "*" : ""}${b.name}`).sort()).toEqual(["*topic", "main"]);
		await expect(a.client.call("git.checkout", { cwd: dir, branch: "bad name" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	});
});

describe("composer and extensions (milestone 2.5)", () => {
	type State = Snapshot["state"];
	async function session(a: Ctx, mode: "full_auto" | "auto_edit" = "full_auto") {
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-25-")));
		writeFileSync(join(folder, "a.txt"), "one\n");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: mode });
		const sub = await a.client.call("sessions.subscribe", { ref });
		return { folder, ref, sub: sub.subscriptionId as string };
	}
	const latest = (a: Ctx, sub: string) => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e) => e.type === "state").at(-1) as { state: State } | undefined;
	async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
		await a.client.waitFor(() => Boolean(latest(a, sub) && predicate(latest(a, sub)!.state)), 20_000);
		return latest(a, sub)!.state;
	}
	async function run(a: Ctx, s: { ref: unknown; sub: string }, text: string) {
		const seq = Math.max(0, ...a.client.events.filter((n) => n.subscriptionId === s.sub).map((n) => n.seq));
		await a.client.call("sessions.submit", { ref: s.ref, input: { text } });
		await a.client.waitFor(settled(s.sub, seq), 20_000);
	}
	const tools = async (a: Ctx, ref: unknown) => ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "tool" ? [i] : []));

	test("todo keeps the latest checklist in the session state, also after a reopen", async () => {
		const a = await start();
		const s = await session(a);
		await run(a, s, "todo: Read the code (done) | Write the test (in_progress) | Ship it");
		const items = [
			{ text: "Read the code", status: "done" },
			{ text: "Write the test", status: "in_progress" },
			{ text: "Ship it", status: "pending" },
		];
		expect(latest(a, s.sub)!.state.todos).toEqual(items);
		expect((await tools(a, s.ref))[0]).toMatchObject({ tool: "todo", details: { type: "todos", items }, output: "1 of 3 done. In progress: Write the test." });
		await stop(a);
		const b = await start(a.home);
		expect(((await b.client.call("sessions.open", { ref: s.ref })) as Snapshot).state.todos).toEqual(items);
	});

	test("plan mode refuses changes, lets read-only commands run, and approving the plan turns it off", async () => {
		const a = await start();
		const s = await session(a);
		await a.client.call("sessions.configure", { ref: s.ref, planMode: true });
		expect((await stateWhere(a, s.sub, (st) => st.planMode === true)).planMode).toBe(true);
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "$ cat a.txt\nedit: a.txt | one | two\n$ touch b.txt\nplan: Change one to two | Edit a.txt | Run the tests" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		expect(waiting.prompts![0]).toMatchObject({ kind: "plan", title: "Change one to two", steps: ["Edit a.txt", "Run the tests"] });
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow" } });
		const done = await stateWhere(a, s.sub, (st) => st.status === "idle" && st.planMode === false);
		expect(done.planMode).toBe(false);
		const [cat, edit, touch, plan] = await tools(a, s.ref);
		expect(cat).toMatchObject({ status: "done", output: expect.stringContaining("one") });
		expect(edit).toMatchObject({ status: "error", output: expect.stringContaining("Plan mode is on") });
		expect(touch).toMatchObject({ status: "error", output: expect.stringContaining("only read-only commands") });
		expect(plan).toMatchObject({ tool: "propose_plan", status: "done", output: expect.stringContaining("approved the plan") });
		expect(readFileSync(join(s.folder, "a.txt"), "utf8")).toBe("one\n");
		expect(existsSync(join(s.folder, "b.txt"))).toBe(false);
	});

	test("a task runs a subagent as a child session that can be opened", async () => {
		const a = await start();
		const s = await session(a);
		await run(a, s, "task: Say hello | $ echo from-the-child");
		const [task] = await tools(a, s.ref);
		expect(task).toMatchObject({ tool: "task", status: "done", details: { type: "task", status: "done" }, output: "Echo: $ echo from-the-child" });
		const childId = task!.details?.type === "task" ? task!.details.sessionId : undefined;
		const child = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((x: { ref: { id: string } }) => x.ref.id === childId);
		expect(child).toMatchObject({ title: "Say hello", parent: { id: (s.ref as { id: string }).id, callId: task!.callId } });
		const childTools = await tools(a, child.ref);
		expect(childTools[0]).toMatchObject({ tool: "bash", status: "done", output: expect.stringContaining("from-the-child") });
	});

	test("the session tree: navigate back to a message, branch, and see both branches", async () => {
		const a = await start();
		const s = await session(a);
		await run(a, s, "first");
		await run(a, s, "second");
		let tree = (await a.client.call("sessions.tree", { ref: s.ref })).nodes;
		expect(tree.map((n: { text: string; current: boolean }) => `${n.text}:${n.current}`)).toEqual(["first:true", "second:true"]);
		const second = tree[1].entryId;
		expect(await a.client.call("sessions.navigate", { ref: s.ref, entryId: second })).toEqual({ editorText: "second" });
		const after = (await a.client.call("sessions.open", { ref: s.ref })) as Snapshot;
		expect(texts(after)).toEqual([
			["user", "first"],
			["assistant", "Echo: first"],
		]);
		await run(a, s, "second, again");
		tree = (await a.client.call("sessions.tree", { ref: s.ref })).nodes;
		expect(tree.map((n: { text: string; current: boolean; depth: number }) => `${n.text}:${n.current}:${n.depth}`)).toEqual(["first:true:0", "second:false:1", "second, again:true:1"]);
	});

	test("commands list templates and extension commands; @-mentions find files fuzzily", async () => {
		const a = await start();
		const s = await session(a);
		mkdirSync(join(s.folder, ".pi", "prompts"), { recursive: true });
		writeFileSync(join(s.folder, ".pi", "prompts", "review.md"), "---\ndescription: Review the current diff\n---\nReview the diff carefully.\n");
		mkdirSync(join(s.folder, "src", "transport"), { recursive: true });
		writeFileSync(join(s.folder, "src", "transport", "stdio.ts"), "");
		writeFileSync(join(s.folder, "src", "transport", "ws.ts"), "");
		writeFileSync(join(s.folder, "README.md"), "");
		await stop(a); // a fresh runtime discovers the new template
		const b = await start(a.home);
		const { commands } = await b.client.call("sessions.commands", { ref: s.ref });
		expect(commands).toEqual(expect.arrayContaining([expect.objectContaining({ name: "plan", kind: "extension" })]));
		const names = commands.map((c: { name: string }) => c.name);
		if (names.includes("review")) expect(commands.find((c: { name: string }) => c.name === "review")).toMatchObject({ kind: "template", description: "Review the current diff" });
		const { files } = await b.client.call("projects.files", { cwd: s.folder, query: "stdio" });
		expect(files[0]).toEqual({ path: "src/transport/stdio.ts", kind: "file" });
		expect((await b.client.call("projects.files", { cwd: s.folder, query: "srctr" })).files[0]).toMatchObject({ path: "src/transport" });
		expect((await b.client.call("projects.files", { cwd: s.folder, query: "" })).files.map((f: { path: string }) => f.path)).toEqual(expect.arrayContaining(["README.md", "src", "a.txt"]));
	});
});

describe("MCP, project trust and files (milestone 2.6)", () => {
	test("Build sessions reach MCP servers from pi's mcp.json; Settings edits the file", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-mcp-")));
		await a.client.call("projects.add", { path: folder });
		const server = fileURLToPath(new URL("./fixtures/echo-mcp-server.mjs", import.meta.url));
		await a.client.call("mcp.add", { scope: "global", name: "test", command: process.execPath, args: [server], description: "Echoes text" });
		// Direct exposure declares the tools to the model (default codemode keeps them behind a script tool).
		const file = join(a.home, "pi-agent", "mcp.json");
		const config = JSON.parse(readFileSync(file, "utf8"));
		config.mcpServers.test.exposure = "direct";
		writeFileSync(file, JSON.stringify(config));
		expect((await a.client.call("mcp.list", {})).servers).toEqual([
			{ name: "test", scope: "global", transport: "stdio", command: process.execPath, args: [server], enabled: true, description: "Echoes text" },
		]);

		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: "full_auto" });
		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: mcp__test__echo | {"text":"hello mcp"}' } });
		await a.client.waitFor(settled(sub.subscriptionId, 1), 30_000);
		const tool = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.find((i) => i.kind === "tool");
		expect(tool).toMatchObject({ tool: "mcp__test__echo", status: "done", output: expect.stringContaining("echo: hello mcp") });

		await a.client.call("mcp.setEnabled", { scope: "global", name: "test", enabled: false });
		expect((await a.client.call("mcp.list", {})).servers[0].enabled).toBe(false);
		await a.client.call("mcp.remove", { scope: "global", name: "test" });
		expect((await a.client.call("mcp.list", {})).servers).toEqual([]);
		await expect(a.client.call("mcp.add", { scope: "global", name: "bad name", command: "x" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	}, 60_000);

	test("project trust gates the project's .pi resources and is saved where the pi CLI reads it", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-trust-")));
		mkdirSync(join(folder, ".pi", "prompts"), { recursive: true });
		writeFileSync(join(folder, ".pi", "prompts", "review.md"), "---\ndescription: Review the diff\n---\nReview it.\n");
		const { project } = await a.client.call("projects.add", { path: folder });
		expect(project).toMatchObject({ trust: "undecided", needsTrust: true });
		const names = async () => {
			const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
			return (await a.client.call("sessions.commands", { ref })).commands.map((c: { name: string }) => c.name);
		};
		expect(await names()).not.toContain("review");
		const trusted = (await a.client.call("projects.configure", { id: project.id, trust: true })).project;
		expect(trusted.trust).toBe("trusted");
		expect(JSON.stringify(JSON.parse(readFileSync(join(a.home, "pi-agent", "trust.json"), "utf8")))).toContain(folder);
		expect(await names()).toContain("review");
	});

	test("the file viewer reads and writes inside the project only", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-files-")));
		mkdirSync(join(folder, "src"));
		writeFileSync(join(folder, "src", "a.ts"), "export const a = 1\n");
		writeFileSync(join(folder, "blob.bin"), Buffer.from([1, 0, 2, 3]));
		await a.client.call("projects.add", { path: folder });
		expect(await a.client.call("projects.readFile", { cwd: folder, path: "src/a.ts" })).toEqual({ content: "export const a = 1\n", size: 19, truncated: false, binary: false });
		expect(await a.client.call("projects.readFile", { cwd: folder, path: "blob.bin" })).toMatchObject({ binary: true, content: "" });
		await a.client.call("projects.writeFile", { cwd: folder, path: "src/a.ts", content: "export const a = 2\n" });
		expect(readFileSync(join(folder, "src", "a.ts"), "utf8")).toBe("export const a = 2\n");
		await expect(a.client.call("projects.readFile", { cwd: folder, path: "../../etc/passwd" })).rejects.toMatchObject({ data: { code: "INVALID" } });
		await expect(a.client.call("projects.writeFile", { cwd: folder, path: "/tmp/x", content: "" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	});
});

describe("projects in the Chat lens (milestone 3.1)", () => {
	test("lenses are detected, and adding from the other mode shows the project in both", async () => {
		const a = await start();
		const code = realpathSync(mkdtempSync(join(tmpdir(), "piopio-code-")));
		writeFileSync(join(code, "package.json"), "{}");
		const notes = realpathSync(mkdtempSync(join(tmpdir(), "piopio-notes-")));
		writeFileSync(join(notes, "ideas.md"), "# Ideas\n");
		expect((await a.client.call("projects.add", { path: code })).project.lenses).toEqual(["build"]);
		expect((await a.client.call("projects.add", { path: notes })).project.lenses).toEqual(["chat"]);
		const both = (await a.client.call("projects.add", { path: code, lens: "chat" })).project;
		expect(both.lenses).toEqual(["build", "chat"]);
		expect((await a.client.call("projects.configure", { id: both.id, lenses: ["chat"] })).project.lenses).toEqual(["chat"]);
		await expect(a.client.call("projects.configure", { id: both.id, lenses: [] })).rejects.toMatchObject({ data: { code: "INVALID" } });
	});

	test("chat-profile sessions read, grep and fetch pages, but have no bash", async () => {
		const a = await start();
		const http = await import("node:http");
		const server = http.createServer((_req, res) => res.end("<html><head><title>Kitchen</title></head><body><p>Dishwashers need 60 cm.</p></body></html>"));
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
		const port = (server.address() as { port: number }).port;
		const notes = realpathSync(mkdtempSync(join(tmpdir(), "piopio-notes-")));
		writeFileSync(join(notes, "kitchen.md"), "# Kitchen\nSink moves 40 cm left.\n");
		mkdirSync(join(notes, "plans"));
		writeFileSync(join(notes, "plans", "budget.md"), "Budget: 12k\n");
		await a.client.call("projects.add", { path: notes });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: notes, profile: "chat", approvalMode: "full_auto" });
		expect((await a.client.call("sessions.list", { kind: "build" })).sessions[0].profile).toBe("chat");
		const sub = await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: `call: grep | {"pattern":"Sink","path":"."}\ncall: web_fetch | {"url":"http://127.0.0.1:${port}/"}\n$ ls` } });
		await a.client.waitFor(settled(sub.subscriptionId, 1), 20_000);
		server.close();
		const tools = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.flatMap((i) => (i.kind === "tool" ? [i] : []));
		expect(tools.map((t) => `${t.tool}:${t.status}`)).toEqual(["grep:done", "web_fetch:done", "bash:error"]);
		expect(tools[0]!.output).toContain("kitchen.md");
		expect(tools[1]!.output).toContain("Dishwashers need 60 cm.");
		expect(tools[2]!.output).toContain("not found");

		expect((await a.client.call("projects.listDir", { cwd: notes, dir: "" })).entries).toEqual([
			{ name: "plans", path: "plans", kind: "folder" },
			{ name: "kitchen.md", path: "kitchen.md", kind: "file" },
		]);
		expect((await a.client.call("projects.listDir", { cwd: notes, dir: "plans" })).entries).toEqual([{ name: "budget.md", path: "plans/budget.md", kind: "file" }]);
	});
});

describe("Spaces (milestone 3.2)", () => {
	type Routing = Extract<Snapshot["items"][number], { kind: "routing" }>;
	const routings = (s: Snapshot) => s.items.filter((i): i is Routing => i.kind === "routing");
	/** Polls `sessions.open` until `ready` holds (routing statuses settle in the background). */
	async function until(ctx: Ctx, ref: unknown, ready: (s: Snapshot) => boolean, timeout = 8_000): Promise<Snapshot> {
		const end = Date.now() + timeout;
		for (;;) {
			const snap: Snapshot = await ctx.client.call("sessions.open", { ref });
			if (ready(snap)) return snap;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(snap.items)}`);
			await new Promise((r) => setTimeout(r, 100));
		}
	}

	test("the organizer creates and routes to topics; Main shows routing cards and the replies live in the topics", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "space", title: "Home renovation", instructions: "We're redoing the flat." });
		expect(ref.kind).toBe("space");
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: create_topic | {"title":"Kitchen layout","brief":"Where things go in the kitchen","reason":"A new subject that will come back","message":"Can we fit a dishwasher?"}' } });
		let main = await until(a, ref, (s) => routings(s)[0]?.status === "replied");
		const [created] = routings(main);
		expect(created).toMatchObject({ decision: "create", topicTitle: "Kitchen layout", reason: "A new subject that will come back", message: "Can we fit a dishwasher?", preview: "Echo: Can we fit a dishwasher?" });
		expect(main.items.filter((i) => i.kind === "tool")).toEqual([]);
		expect(main.state.model).toEqual({ provider: "faux", id: "faux-1" });

		const topicRef = { ...ref, conversationId: created!.topicId };
		const topic: Snapshot = await a.client.call("sessions.open", { ref: topicRef });
		expect(texts(topic)).toEqual([
			["user", "Can we fit a dishwasher?"],
			["assistant", "Echo: Can we fit a dishwasher?"],
		]);
		expect(topic.items.find((i) => i.kind === "assistant")!.id).toBe(created!.replyItemId);
		let [space] = (await a.client.call("sessions.list", { kind: "space" })).sessions;
		expect(space).toMatchObject({ title: "Home renovation", instructions: "We're redoing the flat.", topics: [{ id: created!.topicId, title: "Kitchen layout", unread: true }] });
		await a.client.call("spaces.markRead", { ref: topicRef });
		[space] = (await a.client.call("sessions.list", { kind: "space" })).sessions;
		expect(space!.topics![0]!.unread).toBeUndefined();

		// Routing by title to the existing topic; a plain message is answered in Main.
		await a.client.call("sessions.submit", { ref, input: { text: 'call: route_to_topic | {"topic":"kitchen layout","reason":"Continues the sink discussion","message":"And the sink?"}' } });
		main = await until(a, ref, (s) => routings(s)[1]?.status === "replied");
		expect(routings(main)[1]).toMatchObject({ decision: "route", topicId: created!.topicId, reason: "Continues the sink discussion", preview: "Echo: And the sink?" });
		await a.client.call("sessions.submit", { ref, input: { text: "what's in this space?" } });
		main = await until(a, ref, (s) => s.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === "Echo: what's in this space?")));
		expect(texts(await a.client.call("sessions.open", { ref: topicRef })).length).toBe(4);
	}, 40_000);

	test("@topic, /new and /main decide for the organizer; Wrong topic moves a message; all of it survives a restart", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "space", title: "Home" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "/new Garden\nShould we plant tomatoes?" } });
		await a.client.call("sessions.submit", { ref, input: { text: "@garden: how often do we water them?" } });
		let main = await until(a, ref, (s) => routings(s).length === 2 && routings(s).every((r) => r.status === "replied"));
		expect(routings(main).map((r) => [r.decision, r.topicTitle, r.message, r.forced])).toEqual([
			["create", "Garden", "Should we plant tomatoes?", true],
			["route", "Garden", "how often do we water them?", true],
		]);
		expect(main.items.filter((i) => i.kind === "user").map((i) => (i.kind === "user" ? i.text : ""))).toEqual(["/new Garden\nShould we plant tomatoes?", "@garden: how often do we water them?"]);

		await a.client.call("sessions.submit", { ref, input: { text: "/main what topics do we have?" } });
		main = await until(a, ref, (s) => s.items.some((i) => i.kind === "assistant" && i.status === "done"));
		expect(main.items.filter((i) => i.kind === "user").at(-1)).toMatchObject({ text: "what topics do we have?" });

		// Typing in the topic itself: a direct message.
		const garden = { ...ref, conversationId: routings(main)[0]!.topicId };
		await a.client.call("sessions.submit", { ref: garden, input: { text: "direct question" } });
		const topic = await until(a, garden, (s) => s.items.filter((i) => i.kind === "assistant").length === 3);
		expect(topic.items.filter((i) => i.kind === "user").map((i) => (i.kind === "user" ? [i.text, i.direct ?? false] : []))).toEqual([
			["Should we plant tomatoes?", false],
			["how often do we water them?", false],
			["direct question", true],
		]);

		// Wrong topic: the watering question goes to a new topic.
		const watering = routings(main)[1]!;
		await a.client.call("spaces.reroute", { ref, itemId: watering.id, newTopic: "Watering" });
		main = await until(a, ref, (s) => routings(s)[1]?.topicTitle === "Watering" && routings(s)[1]?.status === "replied");
		expect(routings(main)[1]).toMatchObject({ movedFrom: "Garden", reason: "You moved this from Garden", preview: "Echo: how often do we water them?" });
		const [space] = (await a.client.call("sessions.list", { kind: "space" })).sessions;
		expect(space!.topics!.map((t) => t.title).sort()).toEqual(["Garden", "Watering"]);

		await stop(a);
		const b = await start(a.home);
		const reopened = await until(b, ref, (s) => routings(s).length === 2 && routings(s).every((r) => r.status === "replied"));
		expect(routings(reopened).map((r) => r.topicTitle)).toEqual(["Garden", "Watering"]);
		expect(reopened.items.map((i) => i.id)).toEqual(main.items.map((i) => i.id));
	}, 60_000);

	test("memory: the organizer saves facts, Undo takes them back, topics propose, and the editor keeps a history (3.3)", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "space", title: "Home" });
		await a.client.call("sessions.subscribe", { ref });
		const memoryCards = (s: Snapshot) => s.items.filter((i): i is Extract<Snapshot["items"][number], { kind: "memory" }> => i.kind === "memory");
		await a.client.call("sessions.submit", { ref, input: { text: 'call: update_memory | {"add":["Budget is 30k"],"section":"Decisions"}' } });
		let main = await until(a, ref, (s) => memoryCards(s)[0]?.status === "saved" && s.state.status === "idle");
		const saved = memoryCards(main)[0]!;
		expect(saved).toMatchObject({ action: "saved", added: ["Budget is 30k"], removed: [] });
		let memory = await a.client.call("spaces.memory.get", { ref });
		expect(memory.text).toBe("## Decisions\n- Budget is 30k");
		expect(memory.revisions[0]).toMatchObject({ by: { kind: "organizer" }, summary: "Added “Budget is 30k”" });
		expect((await a.client.call("sessions.list", { kind: "space" })).sessions[0]!.space).toMatchObject({ memoryLines: 1, memory: true, autoTidy: false });

		await a.client.call("spaces.memory.undo", { ref, revisionId: saved.revisionId! });
		main = await until(a, ref, (s) => memoryCards(s)[0]?.status === "undone");
		expect((await a.client.call("spaces.memory.get", { ref })).text).not.toContain("Budget");

		// A topic proposes; you save it.
		await a.client.call("sessions.submit", { ref, input: { text: "/new Finishes\nWhat look do we want?" } });
		await until(a, ref, (s) => routings(s)[0]?.status === "replied");
		const topicRef = { ...ref, conversationId: (await a.client.call("sessions.list", { kind: "space" })).sessions[0]!.topics![0]!.id };
		await a.client.call("sessions.subscribe", { ref: topicRef });
		await a.client.call("sessions.submit", { ref: topicRef, input: { text: 'call: propose_memory | {"add":["Prefers matte finishes"],"reason":"A preference for every room"}' } });
		let topic = await until(a, topicRef, (s) => memoryCards(s)[0]?.status === "pending" && s.state.status === "idle");
		const proposal = memoryCards(topic)[0]!;
		expect(proposal).toMatchObject({ action: "proposed", added: ["Prefers matte finishes"], reason: "A preference for every room" });
		await a.client.call("spaces.memory.decide", { ref, proposalId: proposal.proposalId!, accept: true });
		topic = await until(a, topicRef, (s) => memoryCards(s)[0]?.status === "saved");
		memory = await a.client.call("spaces.memory.get", { ref });
		expect(memory.text).toContain("- Prefers matte finishes");
		expect(memory.revisions[0]).toMatchObject({ by: { kind: "topic", title: "Finishes" } });

		// Your edits, and restoring an older version.
		await a.client.call("spaces.memory.set", { ref, text: "## Notes\n- Edited by hand" });
		memory = await a.client.call("spaces.memory.get", { ref });
		expect(memory.revisions[0]).toMatchObject({ by: { kind: "user" }, added: ["Edited by hand"], removed: ["Prefers matte finishes"] });
		await a.client.call("spaces.memory.restore", { ref, revisionId: memory.revisions[1]!.id });
		expect((await a.client.call("spaces.memory.get", { ref })).text).toContain("Prefers matte finishes");
	}, 60_000);

	test("ask_topic, search_space, files, housekeeping, summaries and settings (3.3)", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "space", title: "Home" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: "/new Kitchen\nThe sink is white" } });
		await a.client.call("sessions.submit", { ref, input: { text: "/new Garden\nTomatoes or peppers?" } });
		await until(a, ref, (s) => routings(s).length === 2 && routings(s).every((r) => r.status === "replied"));
		const list = async () => (await a.client.call("sessions.list", { kind: "space" })).sessions[0]!;
		const id = async (title: string) => (await list()).topics!.find((t) => t.title === title)!.id;
		const kitchen = await id("Kitchen"), garden = await id("Garden");
		// Summaries come after each reply (the scripted model has no utility model: the reply's first line).
		for (let i = 0; i < 50 && !(await list()).topics!.every((t) => t.summary); i++) await new Promise((r) => setTimeout(r, 100));
		expect((await list()).topics!.find((t) => t.id === kitchen)!.summary).toBe("Echo: The sink is white");

		const tool = async (call: string) => {
			const before = ((await a.client.call("sessions.open", { ref })) as Snapshot).items.length;
			await a.client.call("sessions.submit", { ref, input: { text: `call: ${call}` } });
			const s = await until(a, ref, (s) => s.items.length > before + 2 && s.state.status === "idle");
			return [...s.items].reverse().find((i) => i.kind === "tool") as Extract<Snapshot["items"][number], { kind: "tool" }>;
		};
		expect((await tool('ask_topic | {"topic":"Kitchen","question":"What color is the sink?"}')).output).toContain("“Kitchen” says:\nEcho: What color is the sink?");
		expect(texts(await a.client.call("sessions.open", { ref: { ...ref, conversationId: kitchen } })).length).toBe(2);
		expect((await tool('search_space | {"query":"tomatoes"}')).output).toContain("“Garden”");

		await a.client.call("spaces.files.add", { ref, name: "notes.md", text: "Sink: 60 cm wide\nOven: 90 cm" });
		const pdf = join(a.home, "quote.pdf");
		writeFileSync(pdf, Buffer.from([0x25, 0x50, 0x44, 0x46, 0, 1, 2]));
		await a.client.call("spaces.files.add", { ref, name: "quote.pdf", path: pdf, extracted: "Quote B: 14.2k" });
		expect((await a.client.call("spaces.files.list", { ref })).files.map((f) => f.name)).toEqual(["notes.md", "quote.pdf"]);
		expect((await tool('space_files_read | {"name":"quote.pdf"}')).output).toBe("Quote B: 14.2k");
		expect((await tool('space_files_search | {"query":"oven"}')).output).toBe("notes.md:2: Oven: 90 cm");
		for (let i = 0; i < 20 && (await list()).space!.files !== 2; i++) await new Promise((r) => setTimeout(r, 100));
		expect((await list()).space!.files).toBe(2);

		// The organizer only suggests tidying until auto-tidy is on.
		expect((await tool('rename_topic | {"topic":"Garden","title":"Vegetable garden"}')).status).toBe("error");
		await a.client.call("spaces.configure", { ref, autoTidy: true });
		expect((await tool('rename_topic | {"topic":"Garden","title":"Vegetable garden"}')).output).toContain("Renamed “Garden” to “Vegetable garden”");
		// Your own housekeeping.
		await a.client.call("spaces.topics.rename", { ref: { ...ref, conversationId: garden }, title: "Veg garden" });
		const { summary } = await a.client.call("spaces.topics.merge", { ref: { ...ref, conversationId: garden }, into: kitchen });
		expect(summary).toContain("Tomatoes or peppers?");
		let topics = (await list()).topics!;
		expect(topics.find((t) => t.id === garden)).toMatchObject({ title: "Veg garden", archived: true });
		expect(topics.find((t) => t.id === kitchen)!.brief).toContain("Merged from “Veg garden”");
		await a.client.call("spaces.topics.archive", { ref: { ...ref, conversationId: garden }, archived: false });
		topics = (await list()).topics!;
		expect(topics.find((t) => t.id === garden)!.archived).toBeUndefined();

		await a.client.call("spaces.configure", { ref, memory: false, organizerModel: { provider: "faux", id: "faux-1" } });
		expect((await list()).space).toMatchObject({ memory: false, autoTidy: true, organizerModel: { provider: "faux", id: "faux-1" } });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: update_memory | {"add":["x"]}' } });
		const off = await until(a, ref, (s) => s.items.some((i) => i.kind === "memory") && s.state.status === "idle");
		expect(off.items.find((i) => i.kind === "memory")).toMatchObject({ status: "failed", reason: "Memory is off for this Space." });
	}, 90_000);
});

describe("Chat: conversions, suggestions, About me and MCP (milestone 3.4)", () => {
	async function idle(ctx: Ctx, ref: unknown, ready: (s: Snapshot) => boolean = (s) => s.state.status === "idle" && s.items.some((i) => i.kind === "assistant"), timeout = 10_000): Promise<Snapshot> {
		const end = Date.now() + timeout;
		for (;;) {
			const snap: Snapshot = await ctx.client.call("sessions.open", { ref });
			if (ready(snap)) return snap;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(snap.items)}`);
			await new Promise((r) => setTimeout(r, 100));
		}
	}
	const thread = async (ctx: Ctx, text: string) => {
		const { ref } = await ctx.client.call("sessions.create", { kind: "thread" });
		await ctx.client.call("sessions.subscribe", { ref });
		await ctx.client.call("sessions.submit", { ref, input: { text } });
		await idle(ctx, ref);
		return ref;
	};
	const summaryOf = async (ctx: Ctx, id: string) => [...(await ctx.client.call("sessions.list", {})).sessions].find((s) => s.ref.id === id);

	test("a thread is suggested for a Space topic, moves into it, and topics promote back out to threads", async () => {
		const a = await start();
		const { ref: space } = await a.client.call("sessions.create", { kind: "space", title: "Home" });
		await a.client.call("sessions.subscribe", { ref: space });
		await a.client.call("sessions.submit", { ref: space, input: { text: "/new Kitchen cabinets\nOak or walnut?" } });
		await idle(a, space, (s) => s.items.some((i) => i.kind === "routing" && i.status === "replied"));
		const topicId = (await summaryOf(a, space.id))!.topics![0]!.id;

		const t1 = await thread(a, "Which finish for the kitchen cabinets?");
		for (let i = 0; i < 30 && !(await summaryOf(a, t1.id))?.suggestion; i++) await new Promise((r) => setTimeout(r, 100));
		expect((await summaryOf(a, t1.id))!.suggestion).toMatchObject({ spaceId: space.id, spaceTitle: "Home", topicId, topicTitle: "Kitchen cabinets" });

		// Move to topic: the thread's messages join the topic; the thread goes.
		expect(await a.client.call("spaces.importThreads", { ref: space, threads: [t1], topicId })).toEqual({ topicIds: [topicId] });
		const topicRef = { ...space, conversationId: topicId };
		expect(texts(await a.client.call("sessions.open", { ref: topicRef }))).toEqual([
			["user", "Oak or walnut?"],
			["assistant", "Echo: Oak or walnut?"],
			["user", "Which finish for the kitchen cabinets?"],
			["assistant", "Echo: Which finish for the kitchen cabinets?"],
		]);
		expect(await summaryOf(a, t1.id)).toBeUndefined();

		// Move as new topic, keeping the thread; Dismiss on another.
		const t2 = await thread(a, "Paint colours for the hall");
		const [newTopic] = (await a.client.call("spaces.importThreads", { ref: space, threads: [t2], keepThreads: true })).topicIds;
		expect((await summaryOf(a, space.id))!.topics!.find((t) => t.id === newTopic)!.title).toBe("Paint colours for the hall");
		expect(await summaryOf(a, t2.id)).toBeDefined();
		const t3 = await thread(a, "More about kitchen cabinets hinges");
		for (let i = 0; i < 30 && !(await summaryOf(a, t3.id))?.suggestion; i++) await new Promise((r) => setTimeout(r, 100));
		await a.client.call("threads.dismissSuggestion", { ref: t3 });
		expect((await summaryOf(a, t3.id))!.suggestion).toBeUndefined();

		// Promote to Thread: a copy; the topic stays. The new thread goes on from there.
		const { ref: promoted } = await a.client.call("spaces.topics.promote", { ref: topicRef });
		expect((await summaryOf(a, promoted.id))!.title).toBe("Kitchen cabinets");
		expect(texts(await a.client.call("sessions.open", { ref: promoted }))).toEqual(texts(await a.client.call("sessions.open", { ref: topicRef })));
		await a.client.call("sessions.subscribe", { ref: promoted });
		await a.client.call("sessions.submit", { ref: promoted, input: { text: "and the handles?" } });
		await idle(a, promoted, (s) => s.items.filter((i) => i.kind === "assistant").length === 3 && s.state.status === "idle");

		await stop(a);
		const b = await start(a.home);
		expect(texts(await b.client.call("sessions.open", { ref: topicRef })).length).toBe(4);
	}, 60_000);

	test("About me: off by default, then shown and captured; MCP servers reach Threads and Spaces when allowed", async () => {
		const a = await start();
		expect(await a.client.call("settings.get", {})).toEqual({ chat: { mcp: false, suggestSpaces: true }, aboutMe: { enabled: false, capture: false, inThreads: true, inSpaces: true } });
		const tools = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "tool" ? [i] : []));

		let t = await thread(a, 'call: remember_about_me | {"add":["Lives in Valencia"],"section":"Home"}');
		expect(tools(await a.client.call("sessions.open", { ref: t }))[0]).toMatchObject({ status: "error", output: expect.stringContaining("off") });
		await a.client.call("settings.set", { aboutMe: { enabled: true, capture: true } });
		t = await thread(a, 'call: remember_about_me | {"add":["Lives in Valencia"],"section":"Home"}');
		expect(tools(await a.client.call("sessions.open", { ref: t }))[0]).toMatchObject({ status: "done", output: "Saved to About me: Added “Lives in Valencia”." });
		let me = await a.client.call("aboutMe.get", {});
		expect(me.text).toBe("## Home\n- Lives in Valencia");
		await a.client.call("aboutMe.set", { text: "## Home\n- Lives in Madrid" });
		me = await a.client.call("aboutMe.get", {});
		expect(me.revisions[0]).toMatchObject({ by: { kind: "user" }, added: ["Lives in Madrid"], removed: ["Lives in Valencia"] });
		await a.client.call("aboutMe.restore", { revisionId: me.revisions[1]!.id });
		expect((await a.client.call("aboutMe.get", {})).text).toContain("Valencia");

		const server = fileURLToPath(new URL("./fixtures/echo-mcp-server.mjs", import.meta.url));
		await a.client.call("mcp.add", { scope: "global", name: "test", command: process.execPath, args: [server] });
		const file = join(a.home, "pi-agent", "mcp.json");
		const config = JSON.parse(readFileSync(file, "utf8"));
		config.mcpServers.test.exposure = "direct";
		writeFileSync(file, JSON.stringify(config));
		t = await thread(a, 'call: mcp__test__echo | {"text":"hi"}');
		// Off: the tool doesn't exist for the model, so nothing runs.
		expect(tools(await a.client.call("sessions.open", { ref: t })).some((i) => i.status === "done")).toBe(false);
		await a.client.call("settings.set", { chat: { mcp: true } });
		t = await thread(a, 'call: mcp__test__echo | {"text":"hi"}');
		expect(tools(await a.client.call("sessions.open", { ref: t }))[0]).toMatchObject({ tool: "mcp__test__echo", status: "done", output: "echo: hi" });
		const { ref: space } = await a.client.call("sessions.create", { kind: "space", title: "Home" });
		await a.client.call("sessions.subscribe", { ref: space });
		await a.client.call("sessions.submit", { ref: space, input: { text: 'call: mcp__test__echo | {"text":"from main"}' } });
		const main = await idle(a, space);
		expect(tools(main)[0]).toMatchObject({ status: "done", output: "echo: from main" });
	}, 60_000);
});
