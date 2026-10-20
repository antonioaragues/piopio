import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
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
