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

async function start(home = mkdtempSync(join(tmpdir(), "piopio-test-")), faux = true, extra: Partial<ConstructorParameters<typeof Engine>[0]> = {}): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ ...extra, paths, faux, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
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

	// Models come from connected providers only (docs/spec/10 FR2): connect OpenRouter.
	a.client.secrets["provider.openrouter.apiKey"] = "sk-or-test";
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
		a.client.secrets["provider.openrouter.apiKey"] = "sk-or-test";
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

	test("an answered question stays its own item, so the transcript shows what you answered", async () => {
		const a = await start();
		const { folder } = await newProject(a);
		const s = await buildSession(a, folder);
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "ask: Which database? | Postgres | SQLite" } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { choice: "SQLite" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		const grouped: Snapshot = await a.client.call("sessions.open", { ref: s.ref, fold: true });
		const asked = grouped.items.find((i) => i.kind === "tool");
		expect(asked).toMatchObject({ tool: "ask_user", status: "done", args: { question: "Which database?" }, output: "The user answered: SQLite" });
	}, 30_000);
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

	test("a plan can be edited before approving: the agent gets your version, and the plan stays its own item", async () => {
		const a = await start();
		const s = await session(a);
		await a.client.call("sessions.configure", { ref: s.ref, planMode: true });
		const plan = { summary: "Add a **dark mode** toggle", steps: ["Add `theme` to settings", "Draw the toggle", "Test it"], files: ["src/settings.ts"], risks: ["Old themes may clash"] };
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: `call: propose_plan | ${JSON.stringify(plan)}` } });
		const waiting = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		await a.client.call("sessions.respond", { ref: s.ref, promptId: waiting.prompts![0]!.id, response: { decision: "allow", summary: "Add a dark mode toggle", steps: ["Draw the toggle", "Add `theme` to settings"] } });
		await stateWhere(a, s.sub, (st) => st.status === "idle" && st.planMode === false);
		const folded: Snapshot = await a.client.call("sessions.open", { ref: s.ref, fold: true });
		const item = folded.items.find((i) => i.kind === "tool");
		expect(item).toMatchObject({
			tool: "propose_plan",
			output: expect.stringContaining("edited the plan"),
			details: { type: "plan", summary: "Add a dark mode toggle", steps: ["Draw the toggle", "Add `theme` to settings"], files: ["src/settings.ts"], risks: ["Old themes may clash"], outcome: "approved", edited: true },
		});
		expect((item as { output: string }).output).toContain("1. Draw the toggle");

		// Sent back with a note.
		await a.client.call("sessions.configure", { ref: s.ref, planMode: true });
		await a.client.call("sessions.submit", { ref: s.ref, input: { text: "plan: Ship it | Merge" } });
		const again = await stateWhere(a, s.sub, (st) => st.status === "waiting_approval");
		await a.client.call("sessions.respond", { ref: s.ref, promptId: again.prompts![0]!.id, response: { decision: "deny", text: "Add tests first" } });
		await stateWhere(a, s.sub, (st) => st.status === "idle");
		const plans = (await tools(a, s.ref)).filter((t) => t.tool === "propose_plan");
		expect(plans.at(-1)).toMatchObject({ details: { type: "plan", outcome: "changes", note: "Add tests first" } });
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
		expect(off.items.find((i) => i.kind === "memory")).toMatchObject({ status: "failed", reason: "Memory is off for this Notebook." });
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
		expect(await a.client.call("settings.get", {})).toEqual({ chat: { mcp: false, suggestSpaces: true, followUps: true }, aboutMe: { enabled: false, capture: false, inThreads: true, inSpaces: true, provider: "builtin" }, memory: { providers: [] } });
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
		await a.client.call("aboutMe.undo", { revisionId: me.revisions[0]!.id });
		expect((await a.client.call("aboutMe.get", {})).text).toBe("## Home\n- Lives in Valencia");

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

describe("Extensions and memory providers (milestone 4.1)", () => {
	async function idleWith(ctx: Ctx, ref: unknown, ready: (s: Snapshot) => boolean, timeout = 10_000): Promise<Snapshot> {
		const end = Date.now() + timeout;
		for (;;) {
			const snap: Snapshot = await ctx.client.call("sessions.open", { ref });
			if (ready(snap)) return snap;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(snap.items)}`);
			await new Promise((r) => setTimeout(r, 100));
		}
	}

	test("pi packages: install a local package, its skills and templates reach threads, off and remove", async () => {
		const a = await start();
		const pkg = realpathSync(mkdtempSync(join(tmpdir(), "piopio-pkg-")));
		writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "demo-pi-package", version: "1.0.0", keywords: ["pi-package"], pi: { skills: ["./skills"], prompts: ["./prompts/*.md"] } }));
		mkdirSync(join(pkg, "skills", "greet"), { recursive: true });
		writeFileSync(join(pkg, "skills", "greet", "SKILL.md"), "---\nname: greet\ndescription: Greets people warmly in Valencian.\n---\nSay “Bon dia!” first, then answer.\n");
		mkdirSync(join(pkg, "prompts"));
		writeFileSync(join(pkg, "prompts", "summarize.md"), "---\ndescription: Summarize something briefly\nargument-hint: <what> <words>\n---\nSummarize $1 in $2 words.\n");

		await a.client.call("packages.install", { source: pkg });
		const [installed] = (await a.client.call("packages.list", {})).packages;
		// pi keeps local paths relative to its settings file; the listed source is the one to pass back.
		expect(installed).toMatchObject({ source: expect.stringContaining(basename(pkg)), enabled: true, off: [] });
		const source = installed!.source;
		expect(installed!.resources.skills.length).toBe(1);
		expect(installed!.resources.prompts.length).toBe(1);

		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		expect((await a.client.call("sessions.commands", { ref })).commands).toEqual(
			expect.arrayContaining([
				{ name: "summarize", description: "Summarize something briefly", kind: "template", hint: "<what> <words>" },
				{ name: "skill:greet", description: "Greets people warmly in Valencian.", kind: "skill" },
			]),
		);
		await a.client.call("sessions.submit", { ref, input: { text: "/summarize report 50" } });
		let snap = await idleWith(a, ref, (s) => s.state.status === "idle" && s.items.some((i) => i.kind === "assistant"));
		expect(texts(snap)).toEqual([
			["user", "/summarize report 50"],
			["assistant", "Echo: Summarize report in 50 words."],
		]);
		await a.client.call("sessions.submit", { ref, input: { text: 'call: read_skill | {"name":"greet"}' } });
		snap = await idleWith(a, ref, (s) => s.state.status === "idle" && s.items.some((i) => i.kind === "tool" && i.status === "done"));
		expect(snap.items.find((i) => i.kind === "tool")).toMatchObject({ tool: "read_skill", output: expect.stringContaining("Bon dia!") });

		await a.client.call("packages.setEnabled", { source, enabled: false });
		expect((await a.client.call("packages.list", {})).packages[0]).toMatchObject({ enabled: false, off: ["extensions", "skills", "prompts", "themes"] });
		// Only this package's commands go (the user's own skills, which pi also finds, stay).
		const ours = async () => (await a.client.call("sessions.commands", { ref })).commands.filter((c) => c.name === "summarize" || c.name === "skill:greet");
		for (let i = 0; i < 20 && (await ours()).length; i++) await new Promise((r) => setTimeout(r, 100));
		expect(await ours()).toEqual([]);
		await a.client.call("packages.setEnabled", { source, enabled: true, kinds: ["prompts"] });
		expect((await a.client.call("packages.list", {})).packages[0]!.off).toEqual(["extensions", "skills", "themes"]);
		await a.client.call("packages.remove", { source });
		expect((await a.client.call("packages.list", {})).packages).toEqual([]);
	}, 60_000);

	test("About me lives in the built-in provider: the old doc comes in, edits and Undo are grouped changes", async () => {
		const home = mkdtempSync(join(tmpdir(), "piopio-test-"));
		writeFileSync(join(home, "about-me.json"), JSON.stringify({ text: "## Home\n- Lives in Valencia\n\n## Work\n- Nurse", revisions: [], proposals: {} }));
		const a = await start(home);
		let me = await a.client.call("aboutMe.get", {});
		expect(me).toMatchObject({ text: "## Home\n- Lives in Valencia\n\n## Work\n- Nurse", provider: "builtin", limited: false });
		expect(existsSync(join(home, "about-me.json.migrated"))).toBe(true);
		await a.client.call("aboutMe.set", { text: "## Home\n- Lives in Madrid\n\n## Work\n- Nurse\n- Night shifts in April" });
		me = await a.client.call("aboutMe.get", {});
		expect(me.text).toBe("## Work\n- Nurse\n- Night shifts in April\n\n## Home\n- Lives in Madrid");
		expect(me.revisions[0]).toMatchObject({ by: { kind: "user" }, added: ["Lives in Madrid", "Night shifts in April"], removed: ["Lives in Valencia"] });
		await a.client.call("aboutMe.undo", { revisionId: me.revisions[0]!.id });
		expect((await a.client.call("aboutMe.get", {})).text).toBe("## Work\n- Nurse\n\n## Home\n- Lives in Valencia");
		const hits = (await a.client.call("memory.recall", { provider: "builtin", bank: "about-me", query: "where does the user live" })).hits;
		expect(hits[0]!.text).toBe("Lives in Valencia");
	});

	test("an MCP memory provider: tools listed, About me stored and recalled through it, limited without a list tool", async () => {
		const a = await start();
		const server = fileURLToPath(new URL("./fixtures/memory-mcp-server.mjs", import.meta.url));
		const store = join(a.home, "memories.json");
		await a.client.call("mcp.add", { scope: "global", name: "mem", command: process.execPath, args: [server, store] });
		expect((await a.client.call("memory.tools", { server: "mem" })).tools.map((t) => t.name)).toEqual(["remember", "search", "all_memories", "forget"]);
		const provider = {
			id: "mem",
			name: "Test memory",
			server: "mem",
			tools: {
				recall: { tool: "search", args: { query: "{query}", user: "{bank}" } },
				retain: { tool: "remember", args: { text: "{content}", user: "{bank}" } },
				list: { tool: "all_memories", args: { user: "{bank}" } },
				forget: { tool: "forget", args: { id: "{id}" } },
			},
		};
		await a.client.call("settings.set", { memory: { providers: [provider] }, aboutMe: { provider: "mem", enabled: true, capture: true } });
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: remember_about_me | {"add":["Has a dog called Kiwi"]}' } });
		await a.client.waitFor(settled((await a.client.call("sessions.subscribe", { ref })).subscriptionId), 10_000).catch(() => undefined);
		for (let i = 0; i < 50 && !existsSync(store); i++) await new Promise((r) => setTimeout(r, 100));
		expect(JSON.parse(readFileSync(store, "utf8"))).toEqual([{ id: "mem1", user: "about-me", memory: "Has a dog called Kiwi", created_at: "2026-10-21T10:00:00Z" }]);
		expect(await a.client.call("aboutMe.get", {})).toMatchObject({ text: "## Notes\n- Has a dog called Kiwi", provider: "mem", limited: false, revisions: [] });
		expect((await a.client.call("memory.recall", { provider: "mem", bank: "about-me", query: "dog name" })).hits.map((h) => h.text)).toEqual(["Has a dog called Kiwi"]);
		await a.client.call("aboutMe.set", { text: "" });
		expect(JSON.parse(readFileSync(store, "utf8"))).toEqual([]);

		// Without a list tool: About me can't show what's stored ("limited"); the agents recall instead.
		const { list: _list, ...tools } = provider.tools;
		await a.client.call("settings.set", { memory: { providers: [{ ...provider, tools }] } });
		expect(await a.client.call("aboutMe.get", {})).toMatchObject({ text: "", limited: true });
	}, 30_000);
});

describe("Agents: definition and runtime (milestone 4.2)", () => {
	async function until(ctx: Ctx, ref: unknown, ready: (s: Snapshot) => boolean, timeout = 10_000): Promise<Snapshot> {
		const end = Date.now() + timeout;
		for (;;) {
			const snap: Snapshot = await ctx.client.call("sessions.open", { ref });
			if (ready(snap)) return snap;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(snap.items)}`);
			await new Promise((r) => setTimeout(r, 100));
		}
	}
	const idleAfter = (n: number) => (s: Snapshot) => s.state.status === "idle" && s.items.filter((i) => i.kind === "assistant" && i.parts.some((p) => p.text)).length >= n;

	test("an agent from a template: owner chat with compact steps and memory, edits with validation, contacts kept apart, restart, delete", async () => {
		const a = await start();
		expect((await a.client.call("agents.templates", {})).templates.map((t) => t.id)).toEqual(["personal-assistant", "daily-briefing", "habit-coach", "family-helper", "research-watcher"]);
		const { ref } = await a.client.call("agents.create", { name: "Coach", template: "habit-coach", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
		expect(ref.kind).toBe("agent");
		const [listed] = (await a.client.call("sessions.list", { kind: "agent" })).sessions;
		expect(listed).toMatchObject({ title: "Coach", agent: { slug: "coach", avatar: "🏃", location: "local", model: "faux:faux-1", contacts: [{ id: "owner", name: "Antonio", role: "owner" }] } });
		const folder = join(a.home, "Agents", "coach");
		expect(readFileSync(join(folder, "instructions.md"), "utf8")).toContain("You coach Antonio");
		let got = await a.client.call("agents.get", { ref });
		expect(got).toMatchObject({ folder, errors: [], history: [{ message: "Create Coach" }] });

		// The owner's chat: a remembered fact, and the turn's tool call as one steps line.
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: remember | {"fact":"Antonio runs in the morning"}' } });
		let chat = await until(a, ref, idleAfter(1));
		expect(chat.items.map((i) => i.kind)).toEqual(["user", "assistant", "steps", "result", "assistant"]);
		const steps = chat.items.find((i) => i.kind === "steps")!;
		expect(steps.kind === "steps" && steps.tools.map((t) => [t.tool, t.status])).toEqual([["remember", "done"]]);
		const { provider, partitions } = await a.client.call("agents.memory", { ref });
		expect(provider).toBe("builtin");
		expect(partitions.map((p) => p.id)).toEqual(["owner", "shared"]);
		let owner = (await a.client.call("memory.list", { provider, bank: partitions[0]!.bank })).records;
		for (let i = 0; i < 30 && owner.length < 3; i++) {
			await new Promise((r) => setTimeout(r, 100));
			owner = (await a.client.call("memory.list", { provider, bank: partitions[0]!.bank })).records;
		}
		expect(owner.map((r) => [r.kind, r.text]).sort()).toEqual([
			["fact", "Antonio runs in the morning"],
			["message", "Antonio: call: remember | {\"fact\":\"Antonio runs in the morning\"}"],
			["message", "Coach: Echo: call: remember | {\"fact\":\"Antonio runs in the morning\"}"],
		]);

		// Edits: an invalid one is refused; a valid one adds María.
		const def = got.definition as Record<string, unknown> & { contacts: object[]; schedules: { cron: string }[] };
		const bad = await a.client.call("agents.save", { ref, definition: { ...def, schedules: [{ ...def.schedules[0], cron: "0 25 * * *" }] }, instructions: got.instructions });
		expect(bad).toEqual({ saved: false, errors: [{ path: "/schedules/0/cron", message: "The hour must be between 0 and 23." }] });
		const good = await a.client.call("agents.save", { ref, definition: { ...def, contacts: [...def.contacts, { id: "maria", name: "María", role: "contact" }] }, instructions: got.instructions, message: "Add María" });
		expect(good).toEqual({ saved: true, errors: [] });
		got = await a.client.call("agents.get", { ref });
		expect(got.history.map((h) => h.message)).toEqual(["Add María", "Create Coach"]);

		// The channel simulator: talking as María. Her facts stay in her partition; she can't write the owner's.
		const maria = { ...ref, conversationId: "person:maria" };
		await a.client.call("sessions.subscribe", { ref: maria });
		await a.client.call("sessions.submit", { ref: maria, input: { text: 'call: remember | {"fact":"María is vegetarian"}\ncall: remember | {"fact":"x","partition":"owner"}' } });
		const asMaria = await until(a, maria, idleAfter(1));
		const mariaSteps = asMaria.items.find((i) => i.kind === "steps")!;
		expect(mariaSteps.kind === "steps" && mariaSteps.tools.map((t) => t.status)).toEqual(["done", "error"]);
		expect((await a.client.call("memory.list", { provider, bank: `${ref.id}/contacts/maria` })).records.some((r) => r.text === "María is vegetarian")).toBe(true);
		await a.client.call("sessions.submit", { ref, input: { text: 'call: recall | {"query":"vegetarian"}' } });
		chat = await until(a, ref, idleAfter(2));
		const recall = chat.items.filter((i) => i.kind === "steps").at(-1)!;
		expect(recall.kind === "steps" && recall.tools[0]!.output).toBe("Nothing found.");
		const people = (await a.client.call("agents.conversations", { ref })).people;
		expect(people.map((p) => [p.contactId, p.role, p.started])).toEqual([
			["owner", "owner", true],
			["maria", "contact", true],
		]);
		expect(people[1]!.preview).toContain("Echo:");

		await stop(a);
		const b = await start(a.home);
		const reopened: Snapshot = await b.client.call("sessions.open", { ref });
		expect(reopened.items.map((i) => i.id)).toEqual(chat.items.map((i) => i.id));
		await b.client.call("sessions.delete", { ref });
		expect(existsSync(folder)).toBe(false);
		expect(existsSync(join(b.home, "trash", "coach"))).toBe(true);
		expect((await b.client.call("memory.list", { provider: "builtin", bank: `${ref.id}/owner` })).records).toEqual([]);
	}, 60_000);
});

describe("Agents: proactivity (milestone 4.3)", () => {
	type Runs = { runs: { id: string; kind: string; source: string; status: string; sent: number; summary?: string }[]; outbox: { to: string; text: string; reason: string }[]; upcoming: { id: string; kind: string; next?: string }[] };
	async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 15_000): Promise<T> {
		const end = Date.now() + timeout;
		for (;;) {
			const value = await read();
			if (ready(value)) return value;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
			await new Promise((r) => setTimeout(r, 150));
		}
	}
	const send = (to: string, text: string) => `call: send_message | ${JSON.stringify({ to, text })}`;
	const hhmm = (t: number) => new Date(t).toISOString().slice(11, 16);

	test("reminders and triggers start runs that message the owner; quiet hours and the daily limit hold messages; restart resumes", async () => {
		const a = await start();
		const { ref } = await a.client.call("agents.create", { name: "Helper", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
		const got = await a.client.call("agents.get", { ref });
		const base = { ...(got.definition as object), timezone: "UTC", tools: { builtin: ["memory", "schedule", "send_message"] }, triggers: [{ id: "strava", type: "webhook", prompt: "New activity: {{body}}" }] };
		const save = async (policies: object) => expect(await a.client.call("agents.save", { ref, definition: { ...base, policies }, instructions: got.instructions })).toEqual({ saved: true, errors: [] });
		await save({ maxOutboundPerDay: 2 });
		const runs = () => a.client.call("agents.runs", { ref }) as Promise<Runs>;
		const ownerItems = async () => ((await a.client.call("sessions.open", { ref })) as Snapshot).items;
		const outbound = (items: Snapshot["items"]) => items.filter((i) => i.kind === "assistant" && i.outbound).map((i) => (i.kind === "assistant" ? i.parts[0]!.text : ""));

		// The owner asks for a reminder; it fires as a run, which messages the owner.
		const at = new Date(Date.now() + 2_000).toISOString();
		await a.client.call("sessions.submit", { ref, input: { text: `call: schedule | ${JSON.stringify({ when: at, prompt: send("owner", "Time to stretch") })}` } });
		const pending = await until(runs, (r) => r.upcoming.length === 1);
		expect(pending.upcoming[0]).toMatchObject({ kind: "reminder", next: at });
		let r = await until(runs, (x) => x.runs[0]?.status === "done");
		expect(r.runs[0]).toMatchObject({ kind: "reminder", sent: 1, summary: expect.stringContaining("Echo:") });
		expect(r.upcoming).toEqual([]);
		expect(outbound(await until(ownerItems, (items) => outbound(items).length === 1))).toEqual(["Time to stretch"]);
		const owner = await until(() => a.client.call("memory.list", { provider: "builtin", bank: `${ref.id}/owner` }), (m) => m.records.some((x) => x.text.includes("on its own")));
		expect(owner.records.some((x) => x.text === "Helper (on its own): Time to stretch")).toBe(true);

		// The run's conversation: the prompt, the step, the answer; read-only.
		const runRef = { ...ref, conversationId: `run:${r.runs[0]!.id}` };
		const runSnap: Snapshot = await a.client.call("sessions.open", { ref: runRef });
		expect(runSnap.items.map((i) => i.kind)).toEqual(["user", "assistant", "steps", "result", "assistant"]);
		await expect(a.client.call("sessions.submit", { ref: runRef, input: { text: "hi" } })).rejects.toThrow(/read-only/);

		// A webhook trigger: signed URL, the body in the prompt, a retried delivery is the same run.
		const [trigger] = (await a.client.call("agents.triggers", { ref })).triggers;
		expect(trigger!.url).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:\\d+/hooks/${ref.id}/strava/[A-Za-z0-9_-]{32}$`));
		const post = (url: string) => fetch(url, { method: "POST", body: "Ran 10 km", headers: { "idempotency-key": "d1" } });
		expect((await post(trigger!.url.replace(/[A-Za-z0-9_-]{32}$/, "x".repeat(32)))).status).toBe(403);
		const first = (await (await post(trigger!.url)).json()) as { runId: string };
		const again = (await (await post(trigger!.url)).json()) as { runId: string };
		expect(again.runId).toBe(first.runId);
		r = await until(runs, (x) => x.runs[0]?.id === first.runId && x.runs[0].status === "done");
		expect(r.runs[0]).toMatchObject({ kind: "trigger", source: "strava", sent: 0, summary: "Echo: New activity: Ran 10 km" });

		// Restart: a reminder due while the engine is off fires when it comes back.
		const soon = new Date(Date.now() + 1_500).toISOString();
		await a.client.call("sessions.submit", { ref, input: { text: `call: schedule | ${JSON.stringify({ when: soon, prompt: send("owner", "While you were away") })}` } });
		await until(runs, (x) => x.upcoming.length === 1);
		await stop(a);
		await new Promise((resolve) => setTimeout(resolve, 2_500));
		const b = await start(a.home);
		Object.assign(a, { engine: b.engine, client: b.client });
		r = await until(runs, (x) => x.runs[0]?.kind === "reminder" && x.runs[0].status === "done" && x.runs.length === 3);
		expect(outbound(await until(ownerItems, (items) => outbound(items).length === 2))).toEqual(["Time to stretch", "While you were away"]);

		// Quiet hours (now, for the next hour): the message waits in the outbox.
		await save({ maxOutboundPerDay: 2, quietHours: `${hhmm(Date.now() - 60_000)}-${hhmm(Date.now() + 3_600_000)}` });
		await a.client.call("agents.runNow", { ref, prompt: send("owner", "Late note") });
		r = await until(runs, (x) => x.outbox.length === 1 && x.runs[0]?.status === "done");
		expect(r.outbox[0]).toMatchObject({ to: "owner", text: "Late note", reason: "quiet" });
		expect(r.runs[0]).toMatchObject({ kind: "manual", sent: 0 });

		// The daily limit (2, both used): held too, and the owner gets one notice.
		await save({ maxOutboundPerDay: 2 });
		await a.client.call("agents.runNow", { ref, prompt: `${send("owner", "One more")}\n${send("owner", "And another")}` });
		r = await until(runs, (x) => x.outbox.length === 3 && x.runs[0]?.status === "done");
		expect(r.outbox.slice(1).map((o) => [o.text, o.reason])).toEqual([
			["One more", "limit"],
			["And another", "limit"],
		]);
		const items = await until(ownerItems, (xs) => xs.some((i) => i.kind === "system"));
		expect(items.filter((i) => i.kind === "system").map((i) => (i.kind === "system" ? i.text : ""))).toEqual(["Helper reached its limit of 2 messages today; the rest wait until tomorrow."]);
		expect(outbound(items)).toHaveLength(2);
	}, 60_000);
});

describe("Agents: approvals, budgets and the Inbox (milestone 4.4)", () => {
	async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 15_000): Promise<T> {
		const end = Date.now() + timeout;
		for (;;) {
			const value = await read();
			if (ready(value)) return value;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
			await new Promise((r) => setTimeout(r, 150));
		}
	}
	const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;
	type Item = Snapshot["items"][number];
	const approvals = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "approval" }> => i.kind === "approval");
	const results = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "result" }> => i.kind === "result");

	test("approval waits, edits and denials; contacts can't relay; result cards with Undo; pause; budget; the Inbox; restart while waiting", async () => {
		let a = await start();
		const { ref } = await a.client.call("agents.create", { name: "Helper", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
		const got = await a.client.call("agents.get", { ref });
		const def = got.definition as Record<string, unknown> & { contacts: object[] };
		const base = { ...def, tools: { builtin: ["memory", "schedule", "send_message"] }, contacts: [...def.contacts, { id: "maria", name: "María", role: "contact" }, { id: "luis", name: "Luis", role: "contact" }] };
		const save = async (policies: object) => expect(await a.client.call("agents.save", { ref, definition: { ...base, policies }, instructions: got.instructions })).toEqual({ saved: true, errors: [] });
		await save({ requireApproval: ["send_message:to_non_owner"] });
		const owner = () => a.client.call("sessions.open", { ref }).then((s: Snapshot) => s.items);
		const maria = { ...ref, conversationId: "person:maria" };
		const ofMaria = () => a.client.call("sessions.open", { ref: maria }).then((s: Snapshot) => s.items);
		const inbox = () => a.client.call("inbox.list", {});
		const outbound = (items: Item[]) => items.filter((i) => i.kind === "assistant" && i.outbound).map((i) => (i.kind === "assistant" ? i.parts[0]!.text : ""));
		expect((await a.client.call("sessions.list", { kind: "agent" })).sessions[0]!.agent).toMatchObject({ asksFirst: true });

		// A message to María waits for the owner; approved with an edit, it goes as edited.
		await a.client.call("sessions.submit", { ref, input: { text: call("send_message", { to: "maria", text: "Dinner at 8?" }) } });
		let items = await until(owner, (xs) => approvals(xs)[0]?.status === "pending");
		const asked = approvals(items)[0]!;
		expect(asked).toMatchObject({ tool: "send_message", title: "Send to María: “Dinner at 8?”", always: "Always allow messages to María" });
		let box = await until(inbox, (b) => b.count === 1);
		expect(box.items[0]).toMatchObject({ kind: "approval", agentName: "Helper", needsYou: true, conversationId: "person:owner", approval: { approvalId: asked.approvalId } });
		await a.client.call("agents.decide", { ref, approvalId: asked.approvalId, approve: true, args: { to: "maria", text: "Dinner at 8:30?" } });
		items = await until(owner, (xs) => xs.some((i) => i.kind === "result"));
		expect(approvals(items)[0]).toMatchObject({ status: "approved", editedArgs: { text: "Dinner at 8:30?" } });
		expect(results(items)[0]).toMatchObject({ card: { kind: "message", title: "Sent to María", detail: "Dinner at 8:30?" } });
		expect(outbound(await until(ofMaria, (xs) => outbound(xs).length === 1))).toEqual(["Dinner at 8:30?"]);
		await expect(a.client.call("agents.decide", { ref, approvalId: asked.approvalId, approve: false })).rejects.toThrow(/already approved/);

		// Denied: the step fails with the reason and nothing goes.
		await a.client.call("sessions.submit", { ref, input: { text: call("send_message", { to: "maria", text: "Second" }) } });
		items = await until(owner, (xs) => approvals(xs).some((x) => x.status === "pending"));
		await a.client.call("agents.decide", { ref, approvalId: approvals(items).find((x) => x.status === "pending")!.approvalId, approve: false, reason: "not now" });
		items = await until(owner, (xs) => xs.filter((i) => i.kind === "steps").length === 2 && xs.at(-1)?.kind === "assistant");
		expect(approvals(items).at(-1)).toMatchObject({ status: "denied", reason: "not now" });
		const denied = items.filter((i) => i.kind === "steps").at(-1)!;
		expect(denied.kind === "steps" && [denied.tools[0]!.status, denied.tools[0]!.output]).toEqual(["error", expect.stringContaining("not now")]);
		box = await inbox();
		expect(box.count).toBe(0);

		// AS2: María can't make the agent write to Luis; writing to the owner is fine (and lands in the Inbox).
		await a.client.call("sessions.submit", { ref: maria, input: { text: `${call("send_message", { to: "luis", text: "psst" })}\n${call("send_message", { to: "owner", text: "María says hi" })}` } });
		const fromMaria = await until(ofMaria, (xs) => xs.some((i) => i.kind === "steps" && i.tools.length === 2 && i.tools.every((t) => t.status === "done" || t.status === "error")));
		const relay = fromMaria.find((i) => i.kind === "steps" && i.tools.length === 2)!;
		expect(relay.kind === "steps" && relay.tools.map((t) => t.status)).toEqual(["error", "done"]);
		box = await until(inbox, (b) => b.items.some((i) => i.kind === "message"));
		expect(box.items.find((i) => i.kind === "message")).toMatchObject({ body: "María says hi", needsYou: true });
		await a.client.call("inbox.read", { items: box.items.filter((i) => i.kind === "message").map((i) => ({ agentId: ref.id, id: i.id })) });
		expect((await inbox()).count).toBe(0);

		// Result cards with Undo: a saved fact goes away, and the conversation says so.
		await a.client.call("sessions.submit", { ref, input: { text: call("remember", { fact: "Antonio likes tea" }) } });
		items = await until(owner, (xs) => results(xs).some((r) => r.card.kind === "memory"));
		const saved = results(items).find((r) => r.card.kind === "memory")!;
		expect(saved).toMatchObject({ card: { title: "Saved to memory", detail: "Antonio likes tea" }, undo: { status: "available" } });
		await a.client.call("agents.undo", { ref, undoId: saved.undo!.id });
		await until(owner, (xs) => results(xs).find((r) => r.id === saved.id)?.undo?.status === "undone" && xs.some((i) => i.kind === "system" && i.text === "Undone: saving “Antonio likes tea”"));
		expect((await a.client.call("memory.list", { provider: "builtin", bank: `${ref.id}/owner` })).records.some((r) => r.text === "Antonio likes tea")).toBe(false);
		await expect(a.client.call("agents.undo", { ref, undoId: saved.undo!.id })).rejects.toThrow(/Already undone/);

		// Restart while an approval waits: answered after, the call goes on.
		await a.client.call("sessions.submit", { ref, input: { text: call("send_message", { to: "maria", text: "After the restart" }) } });
		items = await until(owner, (xs) => approvals(xs).some((x) => x.status === "pending"));
		const waiting = approvals(items).find((x) => x.status === "pending")!;
		await stop(a);
		a = await start(a.home);
		expect((await until(inbox, (b) => b.count === 1)).items[0]!.approval).toMatchObject({ approvalId: waiting.approvalId, status: "pending" });
		await a.client.call("agents.decide", { ref, approvalId: waiting.approvalId, approve: true });
		expect(outbound(await until(ofMaria, (xs) => outbound(xs).length === 2))).toEqual(["Dinner at 8:30?", "After the restart"]);

		// Pause (AS4): messages don't start turns, runs are skipped; /resume from the owner's chat.
		await a.client.call("agents.pause", { ref, paused: true });
		expect((await until(() => a.client.call("sessions.list", { kind: "agent" }), (l) => l.sessions[0]!.agent?.status?.paused === true)).sessions[0]!.agent!.status).toMatchObject({ paused: true });
		await a.client.call("sessions.submit", { ref, input: { text: "Are you there?" } });
		items = await until(owner, (xs) => xs.some((i) => i.kind === "system" && i.text.includes("is paused")));
		expect(items.at(-2)).toMatchObject({ kind: "user", text: "Are you there?" });
		const { runId } = await a.client.call("agents.runNow", { ref, prompt: "Anything new?" });
		expect((await a.client.call("agents.runs", { ref })).runs.find((r) => r.id === runId)).toMatchObject({ status: "skipped", summary: "Helper is paused." });
		await a.client.call("sessions.submit", { ref, input: { text: "/resume" } });
		await until(() => a.client.call("sessions.list", { kind: "agent" }), (l) => l.sessions[0]!.agent?.status?.paused === false);

		// Budget (AS3): at $0 the agent is out of budget; the owner gets a note and an Inbox item, María a short answer.
		await save({ requireApproval: ["send_message:to_non_owner"], budgetUsdPerMonth: 0 });
		await a.client.call("sessions.submit", { ref: maria, input: { text: "Hello?" } });
		expect(outbound(await until(ofMaria, (xs) => outbound(xs).length === 3)).at(-1)).toBe("Sorry, I can't answer right now. I'll be back soon.");
		box = await until(inbox, (b) => b.items.some((i) => i.kind === "budget"));
		expect(box.items.find((i) => i.kind === "budget")).toMatchObject({ title: "Budget used up", needsYou: true });
		expect((await owner()).some((i) => i.kind === "system" && i.text.startsWith("Helper used its budget"))).toBe(true);
	}, 90_000);
});

describe("Agents: Apple apps as tools (milestone 4.5)", () => {
	async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 15_000): Promise<T> {
		const end = Date.now() + timeout;
		for (;;) {
			const value = await read();
			if (ready(value)) return value;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
			await new Promise((r) => setTimeout(r, 150));
		}
	}
	const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;
	type Item = Snapshot["items"][number];
	const steps = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "steps" }> => i.kind === "steps").flatMap((s) => s.tools);
	const results = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "result" }> => i.kind === "result");

	test("tools by group through the Mac app: unavailable without it, cards and Undo with it, Shortcuts by name", async () => {
		const a = await start();
		const { ref } = await a.client.call("agents.create", { name: "Helper", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
		const got = await a.client.call("agents.get", { ref });
		const def = got.definition as Record<string, unknown>;
		expect(await a.client.call("agents.save", { ref, definition: { ...def, tools: { builtin: ["memory"], apple: ["reminders"], shortcuts: ["Log water"] } }, instructions: got.instructions })).toEqual({ saved: true, errors: [] });
		const owner = () => a.client.call("sessions.open", { ref }).then((s: Snapshot) => s.items);
		const turn = async (text: string) => {
			const before = (await owner()).filter((i) => i.kind === "assistant" && i.parts.some((p) => p.text)).length;
			await a.client.call("sessions.submit", { ref, input: { text } });
			return until(owner, (xs) => xs.filter((i) => i.kind === "assistant" && i.parts.some((p) => p.text)).length > before && !xs.some((i) => i.kind === "steps" && i.tools.some((t) => t.status === "running")));
		};

		// No app connected (background mode): the tool says so.
		let items = await turn(call("apple_reminders_create", { title: "Buy milk" }));
		expect(steps(items).at(-1)).toMatchObject({ tool: "apple_reminders_create", status: "error", output: expect.stringContaining("Piopio isn't open") });

		// The Mac app connects and serves the tools.
		const paths = enginePaths(a.home);
		const app = await TestClient.connect(paths.socket);
		await app.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "fake app", protocolVersion: "1.0", services: ["app.tool"] });
		const reminders = new Map<string, string>();
		const calls: any[] = [];
		app.appTool = (p) => {
			calls.push(p);
			if (p.name === "apple_reminders_create") {
				const id = `r${reminders.size + 1}`;
				reminders.set(id, p.args.title);
				return { ok: true, output: `Created ${id}.`, card: { kind: "reminder", title: "Reminder created", detail: p.args.title }, undo: { name: "apple_reminders_delete", args: { id }, title: `creating “${p.args.title}”` } };
			}
			if (p.name === "apple_reminders_delete") return reminders.delete(p.args.id) ? { ok: true, output: "Deleted." } : { ok: false, output: "Gone already." };
			if (p.name === "shortcuts_run") return { ok: true, output: "Logged 250 ml.", card: { kind: "shortcut", title: `Ran “${p.args.name}”`, detail: "Logged 250 ml." } };
			throw new Error(`unexpected ${p.name}`);
		};
		items = await turn(call("apple_reminders_create", { title: "Buy milk" }));
		expect(calls[0]).toMatchObject({ name: "apple_reminders_create", args: { title: "Buy milk" }, agent: { id: ref.id, name: "Helper" }, groups: ["reminders", "shortcuts"], shortcuts: ["Log water"] });
		expect([...reminders.values()]).toEqual(["Buy milk"]);
		const card = results(items).at(-1)!;
		expect(card).toMatchObject({ card: { kind: "reminder", title: "Reminder created", detail: "Buy milk" }, undo: { status: "available" } });

		// Undo is another call to the app.
		await a.client.call("agents.undo", { ref, undoId: card.undo!.id });
		await until(owner, (xs) => results(xs).find((r) => r.id === card.id)?.undo?.status === "undone");
		expect(reminders.size).toBe(0);
		expect(calls.at(-1)).toMatchObject({ name: "apple_reminders_delete", args: { id: "r1" } });

		// Shortcuts by name; groups that aren't on aren't offered.
		items = await turn(call("shortcuts_run", { name: "Log water", input: "250" }));
		expect(results(items).at(-1)).toMatchObject({ card: { kind: "shortcut", title: "Ran “Log water”" } });
		items = await turn(call("apple_calendar_events", { from: "2026-10-21", to: "2026-10-22" }));
		expect(steps(items).at(-1)).toMatchObject({ tool: "apple_calendar_events", status: "error" });
		expect(calls.some((c) => c.name === "apple_calendar_events")).toBe(false);
		app.close();
	}, 60_000);
});

describe("Agents: agent-to-agent (milestone 4.6)", () => {
	async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 20_000): Promise<T> {
		const end = Date.now() + timeout;
		for (;;) {
			const value = await read();
			if (ready(value)) return value;
			if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
			await new Promise((r) => setTimeout(r, 150));
		}
	}
	const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;
	type Item = Snapshot["items"][number];
	const msgs = (items: Item[]) => items.filter((i): i is Extract<Item, { kind: "agent_msg" }> => i.kind === "agent_msg");

	test("ask and tell between agents: permissions, answers, the hop limit, rate and trace limits, shared memory, the trace", async () => {
		const a = await start(undefined, true, { agentAskTimeoutMs: 30_000 });
		const faux = { provider: "faux", id: "faux-1" };
		const make = async (name: string) => (await a.client.call("agents.create", { name, owner: "Antonio", model: faux })).ref as { kind: "agent"; id: string };
		const scout = await make("Scout"), ledger = await make("Ledger"), muse = await make("Muse");
		const save = async (ref: { id: string }, change: (d: Record<string, any>) => object) => {
			const got = await a.client.call("agents.get", { ref });
			expect(await a.client.call("agents.save", { ref, definition: change(got.definition), instructions: got.instructions })).toEqual({ saved: true, errors: [] });
		};
		await save(scout, (d) => ({ ...d, tools: { builtin: ["memory"], agents: [ledger.id, muse.id] } }));
		await save(ledger, (d) => ({ ...d, tools: { builtin: ["memory"], agents: [scout.id] }, shareMemory: { [scout.id]: ["shared"] } }));
		await save(muse, (d) => ({ ...d, acceptFrom: [ledger.id] }));
		const items = (ref: object) => () => a.client.call("sessions.open", { ref }).then((s: Snapshot) => s.items);
		const settled = (xs: Item[]) => xs.at(-1)?.kind === "assistant" && !msgs(xs).some((m) => m.status === "waiting");

		// Scout asks Ledger; Ledger answers in its conversation with Scout; the answer comes back.
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("ask_agent", { agent: "Ledger", message: "What is the budget?" }) } });
		let mine = await until(items(scout), (xs) => settled(xs) && msgs(xs).length === 1);
		const asked = msgs(mine)[0]!;
		expect(asked).toMatchObject({ direction: "out", mode: "ask", toAgent: { id: ledger.id, name: "Ledger" }, text: "What is the budget?", status: "replied", reply: "Echo: What is the budget?" });
		const theirs = await items({ ...ledger, conversationId: `agent:${scout.id}` })();
		expect(msgs(theirs)[0]).toMatchObject({ direction: "in", fromAgent: { name: "Scout" }, text: "What is the budget?" });
		expect(theirs.at(-1)).toMatchObject({ kind: "assistant", parts: [{ text: "Echo: What is the budget?" }] });
		await expect(a.client.call("sessions.submit", { ref: { ...ledger, conversationId: `agent:${scout.id}` }, input: { text: "hi" } })).rejects.toThrow(/read-only/);
		expect((await a.client.call("agents.conversations", { ref: ledger })).people.find((p: any) => p.role === "agent")).toMatchObject({ name: "Scout", conversationId: `agent:${scout.id}` });
		const trace = await a.client.call("agents.trace", { traceId: asked.traceId });
		expect(trace.hops).toEqual([expect.objectContaining({ hop: 1, mode: "ask", from: { id: scout.id, name: "Scout" }, to: { id: ledger.id, name: "Ledger" }, status: "replied", reply: "Echo: What is the budget?" })]);

		// Muse only accepts Ledger; Ledger can't write to Muse (not in its list).
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("tell_agent", { agent: "Muse", message: "hi" }) } });
		mine = await until(items(scout), (xs) => settled(xs) && msgs(xs).length === 2);
		expect(msgs(mine)[1]).toMatchObject({ mode: "tell", status: "failed", reply: "Muse doesn't accept messages from you." });
		await a.client.call("sessions.submit", { ref: ledger, input: { text: call("tell_agent", { agent: "Muse", message: "hi" }) } });
		const own = await until(items(ledger), (xs) => settled(xs) && msgs(xs).length === 1);
		expect(msgs(own)[0]).toMatchObject({ status: "failed", reply: "You can write to: Scout." });

		// The hop limit: Scout → Ledger → Scout → Ledger → Scout, whose fifth hop is refused; the answers unwind.
		const chain = [ledger, scout, ledger, scout, ledger].map((r) => (r === ledger ? "Ledger" : "Scout"));
		let message = "the end";
		for (const to of chain.slice(1).reverse()) message = call("ask_agent", { agent: to, message });
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("ask_agent", { agent: chain[0], message }) } });
		mine = await until(items(scout), (xs) => settled(xs) && msgs(xs).length === 3, 40_000);
		const deep = await a.client.call("agents.trace", { traceId: msgs(mine)[2]!.traceId });
		expect(deep.hops.map((h: any) => [h.hop, h.from.name, h.to.name])).toEqual([
			[1, "Scout", "Ledger"],
			[2, "Ledger", "Scout"],
			[3, "Scout", "Ledger"],
			[4, "Ledger", "Scout"],
		]);
		expect(deep.hops.slice(1).map((h: any, i: number) => h.parent === deep.hops[i].id)).toEqual([true, true, true]);

		// Rate and trace limits.
		await save(scout, (d) => ({ ...d, policies: { agentMessagesPerHour: 3 } }));
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("tell_agent", { agent: "Ledger", message: "one more" }) } });
		mine = await until(items(scout), (xs) => settled(xs) && msgs(xs).length === 4);
		expect(msgs(mine)[3]).toMatchObject({ status: "failed", reply: expect.stringContaining("limit 3") });
		await save(scout, (d) => ({ ...d, policies: { traceBudgetUsd: 0 } }));
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("tell_agent", { agent: "Ledger", message: "cheap?" }) } });
		mine = await until(items(scout), (xs) => settled(xs) && msgs(xs).length === 5);
		expect(msgs(mine)[4]).toMatchObject({ status: "failed", reply: expect.stringContaining("its limit is $0.00") });

		// Shared memory (AA6): Ledger shares its shared partition with Scout, read-only.
		await a.client.call("sessions.submit", { ref: ledger, input: { text: call("remember", { fact: "The travel budget is 500 euros", partition: "shared" }) } });
		await until(items(ledger), (xs) => xs.some((i) => i.kind === "result"));
		await a.client.call("sessions.submit", { ref: scout, input: { text: call("recall", { query: "travel budget" }) } });
		mine = await until(items(scout), (xs) => xs.filter((i) => i.kind === "steps").some((s) => s.kind === "steps" && s.tools.some((t) => t.tool === "recall" && t.status === "done")));
		const recall = mine.filter((i) => i.kind === "steps").flatMap((s) => (s.kind === "steps" ? s.tools : [])).find((t) => t.tool === "recall")!;
		expect(recall.output).toContain("The travel budget is 500 euros");
	}, 120_000);
});

describe("Folded transcripts (docs/design v2)", () => {
	test("a subscription with fold gets a turn's tool calls as one steps item; without it, tool items", async () => {
		const a = await start();
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		const folded = await a.client.call("sessions.subscribe", { ref, fold: true });
		await a.client.call("sessions.submit", { ref, input: { text: 'call: web_search | {"query":"pío pío"}' } });
		await a.client.waitFor(settled(folded.subscriptionId), 15_000);
		const kinds = (s: Snapshot) => s.items.map((i) => i.kind);
		const plain: Snapshot = await a.client.call("sessions.open", { ref });
		const grouped: Snapshot = await a.client.call("sessions.open", { ref, fold: true });
		expect(kinds(plain)).toContain("tool");
		expect(kinds(grouped)).not.toContain("tool");
		expect(kinds(grouped)).toContain("steps");
		const live = a.client.events.filter((n) => n.subscriptionId === folded.subscriptionId).flatMap((n) => n.events);
		expect(live.some((e) => (e.type === "item.added" || e.type === "item.updated") && e.item.kind === "tool")).toBe(false);
		expect(live.some((e) => (e.type === "item.added" || e.type === "item.updated") && e.item.kind === "steps")).toBe(true);
	}, 30_000);

});

describe("model providers (docs/spec/10-model-providers)", () => {
	type Info = { id: string; status: string; billing?: string; connectedWith?: string; featured: boolean; methods: { type: string }[] };
	const providers = async (a: Ctx) => ((await a.client.call("providers.list", {})) as { providers: Info[] }).providers;
	const authEvents = (a: Ctx, loginId: string) => a.client.notifications.filter((n) => n.method === "providers.auth" && n.params.loginId === loginId).map((n) => n.params.event);
	const until = async (check: () => boolean, timeoutMs = 10_000) => {
		for (const started = Date.now(); !check(); ) {
			if (Date.now() - started > timeoutMs) throw new Error("timed out");
			await new Promise((r) => setTimeout(r, 20));
		}
	};

	test("OpenRouter's original key counts as connected; the featured three come first", async () => {
		const a = await start();
		a.client.secrets["provider.openrouter.apiKey"] = "sk-or-test";
		const list = await providers(a);
		expect(list.slice(0, 3).map((p) => p.id)).toEqual(["openrouter", "openai", "openai-api"]);
		expect(list[0]).toMatchObject({ status: "connected", connectedWith: "api_key", billing: "OpenRouter credits" });
		// ChatGPT is sign-in only on `openai`; its API key goes to the alias.
		expect(list[1]).toMatchObject({ status: "not_connected", methods: [{ type: "oauth", subscription: true }] });
		expect(list[2]).toMatchObject({ status: "not_connected", methods: [{ type: "api_key" }] });
	});

	test("connecting the OpenAI API with a key keeps OpenRouter, lists both, and survives a restart; logout removes only it", async () => {
		const a = await start();
		a.client.secrets["provider.openrouter.apiKey"] = "sk-or-test";
		const { loginId } = await a.client.call("providers.login", { provider: "openai-api", method: "api_key" });
		await until(() => authEvents(a, loginId).some((e) => e.type === "prompt"));
		const prompt = authEvents(a, loginId).find((e) => e.type === "prompt");
		expect(prompt).toMatchObject({ kind: "secret" });
		await a.client.call("providers.answer", { loginId, promptId: prompt.promptId, value: "sk-openai-test" });
		await until(() => authEvents(a, loginId).some((e) => e.type === "done" || e.type === "failed"));
		expect(authEvents(a, loginId).at(-1)).toEqual({ type: "done" });
		// Stored in the app's Keychain, never in the engine's files.
		expect(JSON.parse(a.client.secrets["provider.openai-api.credential"]!)).toMatchObject({ type: "api_key", key: "sk-openai-test" });
		expect(readFileSync(join(a.home, "credentials.json"), "utf8")).not.toContain("sk-openai-test");

		const list = await providers(a);
		expect(list.find((p) => p.id === "openai-api")).toMatchObject({ status: "connected", billing: "OpenAI API billing" });
		expect(list.find((p) => p.id === "openrouter")).toMatchObject({ status: "connected" });
		const { models } = await a.client.call("models.list", {});
		expect(models.find((m: { provider: string; id: string }) => m.provider === "openai-api" && m.id === "gpt-6-sol")).toMatchObject({ providerName: "OpenAI API", billing: "OpenAI API billing" });
		expect(models.some((m: { provider: string }) => m.provider === "openrouter")).toBe(true);

		// A conversation can switch to it and keep its history.
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.submit", { ref, input: { text: "hello" } });
		await a.client.call("sessions.configure", { ref, model: { provider: "openai-api", id: "gpt-6-sol" } });
		const opened: Snapshot = await a.client.call("sessions.open", { ref });
		expect(opened.state.model).toEqual({ provider: "openai-api", id: "gpt-6-sol" });
		expect(opened.items.some((i) => i.kind === "user")).toBe(true);

		await stop(a);
		const b = await start(a.home);
		b.client.secrets = { ...a.client.secrets };
		expect((await providers(b)).find((p) => p.id === "openai-api")).toMatchObject({ status: "connected" });
		expect(((await b.client.call("sessions.open", { ref })) as Snapshot).state.model).toEqual({ provider: "openai-api", id: "gpt-6-sol" });

		await b.client.call("providers.logout", { provider: "openai-api" });
		expect(b.client.secrets["provider.openai-api.credential"]).toBeUndefined();
		const after = await providers(b);
		expect(after.find((p) => p.id === "openai-api")).toMatchObject({ status: "not_connected" });
		expect(after.find((p) => p.id === "openrouter")).toMatchObject({ status: "connected" });
	}, 30_000);

	test("a sign-in flow passes its steps through and can be cancelled", async () => {
		const { LoginFlows } = await import("../src/providers.js");
		const events: { type: string; promptId?: string }[] = [];
		let finished: boolean | undefined;
		const runtime = {
			login: async (_provider: string, _type: string, interaction: { prompt: (p: unknown) => Promise<string>; notify: (e: unknown) => void }) => {
				interaction.notify({ type: "auth_url", url: "https://auth.example/authorize" });
				const code = await interaction.prompt({ type: "manual_code", message: "Paste the callback URL" });
				if (code !== "http://localhost:1455/auth/callback?code=x") throw new Error("bad code");
				return { type: "oauth", access: "a", refresh: "r", expires: 0 };
			},
		};
		const flows = new LoginFlows(() => runtime as never, (_id, _p, e) => events.push(e), { agentName: "Piopio", deviceId: () => "d", finished: (_p, ok) => (finished = ok) });
		const id = flows.start("openai", "oauth");
		expect(flows.connecting("openai")).toBe(true);
		await new Promise((r) => setTimeout(r, 10));
		expect(events[0]).toEqual({ type: "auth_url", url: "https://auth.example/authorize" });
		const prompt = events.find((e) => e.type === "prompt")!;
		flows.answer(id, prompt.promptId!, "http://localhost:1455/auth/callback?code=x");
		await new Promise((r) => setTimeout(r, 10));
		expect(events.at(-1)).toEqual({ type: "done" });
		expect(finished).toBe(true);

		const second = flows.start("openai", "oauth");
		await new Promise((r) => setTimeout(r, 10));
		flows.cancel(second);
		await new Promise((r) => setTimeout(r, 10));
		expect(events.at(-1)).toEqual({ type: "failed", message: "Cancelled." });
		expect(flows.connecting("openai")).toBe(false);
	});

	test("refreshed sign-in tokens are written back to the Keychain", async () => {
		const { KeychainCredentialStore } = await import("../src/credentials.js");
		const { SecretBroker } = await import("../src/secrets.js");
		const keychain: Record<string, string> = {};
		const broker = new SecretBroker({});
		broker.addRequester(async (name) => keychain[name] ?? null, { set: async (n, v) => void (keychain[n] = v), delete: async (n) => void delete keychain[n] });
		const store = new KeychainCredentialStore(broker);
		await store.modify("openai", async () => ({ type: "oauth", access: "a1", refresh: "r1", expires: 1 }));
		await store.modify("openai", async (current) => ({ ...(current as { type: "oauth"; access: string; refresh: string; expires: number }), access: "a2", expires: 2 }));
		expect(JSON.parse(keychain["provider.openai.credential"]!)).toMatchObject({ type: "oauth", access: "a2", refresh: "r1", expires: 2 });
		expect(await store.list()).toEqual([{ providerId: "openai", type: "oauth" }]);
	});
});

describe("custom endpoints (docs/spec/10-model-providers, P1)", () => {
	/** A tiny OpenAI-compatible server: /v1/models, optionally behind a key. */
	async function fakeServer(key?: string) {
		const { createServer } = await import("node:http");
		const server = createServer((req, res) => {
			if (key && req.headers.authorization !== `Bearer ${key}`) return void res.writeHead(401).end();
			if (req.url === "/v1/models") {
				res.writeHead(200, { "content-type": "application/json" });
				return void res.end(JSON.stringify({ object: "list", data: [{ id: "llama-3.3-70b", context_length: 131072 }, { id: "qwen3" }] }));
			}
			res.writeHead(404).end();
		});
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
		const port = (server.address() as { port: number }).port;
		return { url: `http://127.0.0.1:${port}`, close: () => server.close() };
	}

	test("an endpoint is checked, added with /v1 found, listed as a provider and in models, and removed", async () => {
		const srv = await fakeServer();
		const a = await start();
		const check = await a.client.call("endpoints.check", { baseUrl: srv.url });
		expect(check).toMatchObject({ ok: true, baseUrl: `${srv.url}/v1`, models: [{ id: "llama-3.3-70b", contextWindow: 131072 }, { id: "qwen3" }] });
		const { id } = await a.client.call("endpoints.save", { name: "LiteLLM (home)", baseUrl: srv.url });
		expect(id).toBe("custom-litellm-home");
		const providers = (await a.client.call("providers.list", {})).providers as { id: string; status: string; billing?: string; endpoint?: unknown }[];
		expect(providers.find((p) => p.id === id)).toMatchObject({ status: "connected", billing: "On this Mac", endpoint: { baseUrl: `${srv.url}/v1`, local: true, keyless: true } });
		const { models } = await a.client.call("models.list", {});
		expect(models.filter((m: { provider: string }) => m.provider === id).map((m: { id: string; contextWindow: number }) => [m.id, m.contextWindow])).toEqual([["llama-3.3-70b", 131072], ["qwen3", 0]]);
		// Survives a restart, then goes away entirely.
		await stop(a);
		const b = await start(a.home);
		expect(((await b.client.call("providers.list", {})).providers as { id: string }[]).some((p) => p.id === id)).toBe(true);
		await b.client.call("endpoints.remove", { id });
		expect(((await b.client.call("providers.list", {})).providers as { id: string }[]).some((p) => p.id === id)).toBe(false);
		srv.close();
	}, 30_000);

	test("a server that wants a key says so; the key goes to the Keychain; an update without a key keeps it", async () => {
		const srv = await fakeServer("sk-lite");
		const a = await start();
		expect(await a.client.call("endpoints.check", { baseUrl: `${srv.url}/v1` })).toMatchObject({ ok: false, error: "auth", message: "The server wants an API key." });
		await expect(a.client.call("endpoints.save", { name: "Work", baseUrl: `${srv.url}/v1`, key: "wrong" })).rejects.toMatchObject({ data: { code: "INVALID" } });
		const { id } = await a.client.call("endpoints.save", { name: "Work", baseUrl: `${srv.url}/v1`, key: "sk-lite" });
		expect(JSON.parse(a.client.secrets[`provider.${id}.credential`]!)).toMatchObject({ type: "api_key", key: "sk-lite" });
		expect(readFileSync(join(a.home, "endpoints.json"), "utf8")).not.toContain("sk-lite");
		await a.client.call("endpoints.save", { id, name: "Work server", baseUrl: `${srv.url}/v1` });
		const p = ((await a.client.call("providers.list", {})).providers as { id: string; name: string; endpoint?: { keyless: boolean } }[]).find((x) => x.id === id);
		expect(p).toMatchObject({ name: "Work server", endpoint: { keyless: false } });
		await a.client.call("endpoints.remove", { id });
		expect(a.client.secrets[`provider.${id}.credential`]).toBeUndefined();
		srv.close();
	}, 30_000);

	test("an address that isn't a model server is explained", async () => {
		const { checkEndpoint } = await import("../src/endpoints.js");
		const html = (async () => new Response("<html></html>", { status: 200 })) as typeof fetch;
		expect(await checkEndpoint("http://example.test/v1", undefined, html)).toEqual({ ok: false, error: "not_found", message: "That address doesn't look like an OpenAI- or Anthropic-compatible server." });
		const down = (async () => {
			throw new Error("ECONNREFUSED");
		}) as typeof fetch;
		expect(await checkEndpoint("localhost:4000", undefined, down)).toEqual({ ok: false, error: "refused", message: "Nothing is answering at localhost:4000. Is the server running?" });
	});
});

describe("connected apps (docs/spec/12-connectors C1)", () => {
	type Call = { method: string; path: string; body: string };
	/** One fake for Google and Microsoft: OAuth (authorize redirects straight back), userinfo, Calendar API v3 and Graph. */
	async function fakeApps() {
		const { createServer } = await import("node:http");
		const calls: Call[] = [];
		let tokens = 0;
		const day = new Date();
		day.setHours(0, 0, 0, 0);
		const at = (h: number) => new Date(day.getTime() + 86_400_000 + h * 3_600_000).toISOString();
		const server = createServer((req, res) => {
			let body = "";
			req.on("data", (c) => (body += c));
			req.on("end", () => {
				const url = new URL(req.url ?? "/", "http://x");
				calls.push({ method: req.method ?? "GET", path: url.pathname, body });
				const send = (status: number, value: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(value));
				if (url.pathname.endsWith("/authorize")) {
					const back = new URL(url.searchParams.get("redirect_uri")!);
					back.searchParams.set("code", "the-code");
					back.searchParams.set("state", url.searchParams.get("state")!);
					return void res.writeHead(302, { location: back.toString() }).end();
				}
				if (url.pathname.endsWith("/token")) return send(200, { access_token: `tok${++tokens}`, refresh_token: "refresh-1", expires_in: 3600 });
				if (req.headers.authorization?.startsWith("Bearer tok") !== true) return send(401, { error: "no token" });
				// Google
				if (url.pathname === "/g/oauth2/v3/userinfo") return send(200, { sub: "g123", email: "me@gmail.com" });
				if (url.pathname === "/g/calendar/v3/users/me/calendarList") return send(200, { items: [{ id: "primary", summary: "me@gmail.com", primary: true }] });
				if (url.pathname === "/g/calendar/v3/calendars/primary/events" && req.method === "GET") return send(200, { items: [{ id: "e1", summary: "Dentist", start: { dateTime: at(9) }, end: { dateTime: at(10) } }] });
				if (url.pathname === "/g/calendar/v3/calendars/primary/events" && req.method === "POST") {
					const b = JSON.parse(body) as { summary: string; start: unknown; end: unknown };
					return send(200, { id: "e2", summary: b.summary, start: b.start, end: b.end });
				}
				// Microsoft Graph
				if (url.pathname === "/m/v1.0/me") return send(200, { id: "m456", mail: "me@outlook.com" });
				if (url.pathname === "/m/v1.0/me/calendarView") return send(200, { value: [{ id: "o1", subject: "Team sync", start: { dateTime: at(11).slice(0, 19), timeZone: "UTC" }, end: { dateTime: at(12).slice(0, 19), timeZone: "UTC" } }] });
				send(404, { error: url.pathname });
			});
		});
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
		const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
		return {
			calls,
			at,
			endpoints: {
				"google-calendar": { authorizeUrl: `${base}/g/authorize`, tokenUrl: `${base}/g/token`, apiBase: `${base}/g` },
				outlook: { authorizeUrl: `${base}/m/authorize`, tokenUrl: `${base}/m/token`, apiBase: `${base}/m` },
			},
			close: () => server.close(),
		};
	}

	const until = async (check: () => boolean, timeoutMs = 10_000) => {
		for (const started = Date.now(); !check(); ) {
			if (Date.now() - started > timeoutMs) throw new Error("timed out");
			await new Promise((r) => setTimeout(r, 20));
		}
	};

	/** Signs in like the browser would: open the authorize page, follow it back to Piopio's loopback. */
	async function connect(a: Ctx, connector: string) {
		const { loginId } = await a.client.call("connectors.connect", { connector });
		const events = () => a.client.notifications.filter((n) => n.method === "connectors.auth" && n.params.loginId === loginId).map((n) => n.params.event);
		await until(() => events().some((e) => e.type === "auth_url"));
		const page = await fetch(events().find((e) => e.type === "auth_url").url, { redirect: "manual" });
		await fetch(page.headers.get("location")!);
		await until(() => events().some((e) => e.type === "done" || e.type === "failed"));
		return events().at(-1);
	}

	async function withApps() {
		const apps = await fakeApps();
		const a = await start(undefined, true, { connectorEndpoints: apps.endpoints });
		await a.client.call("connectors.configure", { connector: "google-calendar", clientId: "g-client", clientSecret: "g-secret" });
		await a.client.call("connectors.configure", { connector: "outlook", clientId: "m-client" });
		return { a, apps };
	}

	test("signing in stores the account and its tokens in the Keychain; both calendars are read in one call", async () => {
		const { a, apps } = await withApps();
		expect(await connect(a, "google-calendar")).toEqual({ type: "done" });
		expect(await connect(a, "outlook")).toEqual({ type: "done" });
		expect(JSON.parse(a.client.secrets["connector.google-calendar.g123"]!)).toMatchObject({ access: expect.stringMatching(/^tok/), refresh: "refresh-1" });
		expect(a.client.secrets["connector.google-calendar.clientSecret"]).toBe("g-secret");
		expect(readFileSync(join(a.home, "connectors.json"), "utf8")).not.toContain("tok");
		const { connectors } = await a.client.call("connectors.list", {});
		expect(connectors.find((c: { id: string }) => c.id === "google-calendar")).toMatchObject({ ready: true, accounts: [{ id: "google-calendar:g123", label: "me@gmail.com" }] });
		expect(connectors.find((c: { id: string }) => c.id === "outlook")).toMatchObject({ accounts: [{ label: "me@outlook.com" }], tools: expect.arrayContaining([{ name: "mail_send", label: "Send an email", access: "send", dontAsk: false }]) });

		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		await a.client.call("sessions.submit", { ref, input: { text: `call: calendar_events | {"from":"${apps.at(0)}","to":"${apps.at(24)}"}` } });
		let snap: Snapshot = await a.client.call("sessions.open", { ref });
		for (let i = 0; i < 100 && !(snap.items.some((x) => x.kind === "tool" && x.status === "done")); i++) {
			await new Promise((r) => setTimeout(r, 100));
			snap = await a.client.call("sessions.open", { ref });
		}
		const tool = snap.items.find((i) => i.kind === "tool") as { output: string };
		expect(tool.output).toContain("Dentist");
		expect(tool.output).toContain("Google Calendar (me@gmail.com)");
		expect(tool.output).toContain("Team sync");
		expect(tool.output).toContain("Outlook (me@outlook.com)");
		apps.close();
	}, 30_000);

	test("a change asks first in the chat: allowed, it's made; declined, nothing changes", async () => {
		const { a, apps } = await withApps();
		await connect(a, "google-calendar");
		const { ref } = await a.client.call("sessions.create", { kind: "thread" });
		await a.client.call("sessions.subscribe", { ref });
		const approvals = () => a.client.events.flatMap((n) => n.events).filter((e) => (e.type === "item.added" || e.type === "item.updated") && e.item.kind === "approval").map((e) => (e as { item: { approvalId: string; status: string; title: string; source?: string } }).item);
		const create = (title: string) => `call: calendar_create_event | {"title":"${title}","start":"${apps.at(16)}","end":"${apps.at(17)}"}`;

		await a.client.call("sessions.submit", { ref, input: { text: create("Call Ana") } });
		await until(() => approvals().some((x) => x.status === "pending"));
		const pending = approvals().find((x) => x.status === "pending")!;
		expect(pending).toMatchObject({ source: "connector", title: expect.stringContaining("Create “Call Ana”") });
		expect(apps.calls.some((c) => c.method === "POST" && c.path.endsWith("/events"))).toBe(false);
		await a.client.call("sessions.decide", { ref, approvalId: pending.approvalId, approve: true });
		await until(() => apps.calls.some((c) => c.method === "POST" && c.path.endsWith("/events")));
		expect(JSON.parse(apps.calls.find((c) => c.method === "POST" && c.path.endsWith("/events"))!.body)).toMatchObject({ summary: "Call Ana" });

		for (let i = 0; i < 100 && ((await a.client.call("sessions.open", { ref })) as Snapshot).state.status !== "idle"; i++) await new Promise((r) => setTimeout(r, 100));
		await a.client.call("sessions.submit", { ref, input: { text: create("Skip this") } });
		await until(() => approvals().filter((x) => x.status === "pending" && !x.title.includes("Call Ana")).length > 0 || approvals().some((x) => x.title.includes("Skip this")));
		const second = approvals().find((x) => x.title.includes("Skip this"))!;
		await a.client.call("sessions.decide", { ref, approvalId: second.approvalId, approve: false });
		let snap: Snapshot = await a.client.call("sessions.open", { ref });
		for (let i = 0; i < 100 && !snap.items.some((x) => x.kind === "tool" && (x as { output?: string }).output?.includes("declined")); i++) {
			await new Promise((r) => setTimeout(r, 100));
			snap = await a.client.call("sessions.open", { ref });
		}
		expect(snap.items.some((x) => x.kind === "tool" && (x as { output?: string }).output?.includes("The user declined"))).toBe(true);
		expect(apps.calls.filter((c) => c.method === "POST" && c.path.endsWith("/events")).length).toBe(1);
		apps.close();
	}, 30_000);

	test("an expired token is refreshed and written back; disconnecting removes the account and its tokens", async () => {
		const { a, apps } = await withApps();
		await connect(a, "google-calendar");
		const name = "connector.google-calendar.g123";
		a.client.secrets[name] = JSON.stringify({ access: "tok-old", refresh: "refresh-1", expires: Date.now() - 1000 });
		await a.client.call("secrets.changed", { name });
		const hub = a.engine.connectors;
		const [cal] = hub.calendars("chat");
		await cal!.calendar.events({ from: apps.at(0), to: apps.at(24) });
		expect(apps.calls.filter((c) => c.path.endsWith("/token")).length).toBe(2);
		expect(JSON.parse(a.client.secrets[name]!).access).not.toBe("tok-old");
		await a.client.call("connectors.disconnect", { accountId: "google-calendar:g123" });
		expect(a.client.secrets[name]).toBeUndefined();
		expect(hub.accounts()).toEqual([]);
		apps.close();
	}, 30_000);

	test("free time skips busy events within working hours", async () => {
		const { freeSlots } = await import("../src/connectors/tools.js");
		const t = (h: number, m = 0) => new Date(2026, 9, 26, h, m).getTime();
		const slots = freeSlots(new Date(t(0)), new Date(t(23, 59)), [[t(10), t(11)], [t(10, 30), t(12)], [t(15), t(15, 15)]], 30, "09:00", "18:00");
		expect(slots).toEqual([[t(9), t(10)], [t(12), t(15)], [t(15, 15), t(18)]]);
	});
});

describe("Settings › Models redesign (provider keys, visibility, custom endpoints)", () => {
	test("a key is checked against the provider's model list, saved directly, and its models can be hidden", async () => {
		const { verifyKey } = await import("../src/providers.js");
		const anthropic = { id: "anthropic", name: "Anthropic", baseUrl: "https://api.anthropic.com" } as never;
		const seen: { url: string; headers: Record<string, string> }[] = [];
		const ok = (async (url: string, init: { headers: Record<string, string> }) => {
			seen.push({ url, headers: init.headers });
			return new Response(JSON.stringify({ data: [{ id: "a" }, { id: "b" }] }), { status: 200 });
		}) as unknown as typeof fetch;
		expect(await verifyKey(anthropic, "sk-ant-x", ok)).toEqual({ ok: true, models: 2 });
		expect(seen[0]).toMatchObject({ url: "https://api.anthropic.com/v1/models", headers: { "x-api-key": "sk-ant-x" } });
		const rejected = (async () => new Response("", { status: 401 })) as unknown as typeof fetch;
		expect(await verifyKey(anthropic, "bad", rejected)).toEqual({ ok: false, message: "This key was rejected (401)." });
		expect(await verifyKey({ id: "amazon-bedrock", name: "Bedrock" } as never, "x", ok)).toMatchObject({ ok: null });

		const a = await start();
		await a.client.call("providers.saveKey", { provider: "openai-api", key: "sk-proj-1234567890abcdef" });
		expect(JSON.parse(a.client.secrets["provider.openai-api.credential"]!)).toMatchObject({ key: "sk-proj-1234567890abcdef" });
		const info = ((await a.client.call("providers.list", {})).providers as { id: string; keyHint?: string; kind?: string; families?: string[] }[]).find((p) => p.id === "openai-api");
		expect(info).toMatchObject({ kind: "cloud", keyHint: "sk-proj-12…def", families: expect.arrayContaining(["gpt"]) });
		const before = (await a.client.call("models.list", {})).models.filter((m: { provider: string }) => m.provider === "openai-api").length;
		await a.client.call("providers.setHidden", { provider: "openai-api", hidden: ["gpt-4", "gpt-4-turbo"] });
		const after = (await a.client.call("models.list", {})).models.filter((m: { provider: string }) => m.provider === "openai-api");
		expect(after.length).toBe(before - 2);
		expect(after.some((m: { id: string }) => m.id === "gpt-4")).toBe(false);
		const listed = (await a.client.call("providers.models", { provider: "openai-api" })).models as { id: string; hidden: boolean }[];
		expect(listed.find((m) => m.id === "gpt-4")).toMatchObject({ hidden: true });
	});

	test("a custom endpoint speaks Anthropic or OpenAI, sends its headers, explains failures, and can be added anyway", async () => {
		const { createServer } = await import("node:http");
		const requests: Record<string, string | string[] | undefined>[] = [];
		const server = createServer((req, res) => {
			requests.push(req.headers);
			if (req.url === "/v1/models") return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ data: [{ id: "claude-local" }, { id: "nomic-embed-text" }] }));
			res.writeHead(404).end();
		});
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
		const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
		const a = await start();
		const check = await a.client.call("endpoints.check", { baseUrl: url, key: "k1", format: "anthropic", headers: { "x-team": "piopio" } });
		expect(check).toMatchObject({ ok: true, baseUrl: `${url}/v1`, models: [{ id: "claude-local" }, { id: "nomic-embed-text", embedding: true }], latencyMs: expect.any(Number) });
		expect(requests.at(-1)).toMatchObject({ "x-api-key": "k1", "x-team": "piopio" });
		const { id } = await a.client.call("endpoints.save", { name: "Gateway", baseUrl: url, key: "k1", format: "anthropic", headers: { "x-team": "piopio" }, contextWindow: 200000 });
		const provider = ((await a.client.call("providers.list", {})).providers as { id: string; endpoint?: unknown; models: number }[]).find((p) => p.id === id);
		expect(provider).toMatchObject({ models: 1, endpoint: { format: "anthropic", headers: { "x-team": "piopio" }, contextWindow: 200000 } });
		const models = (await a.client.call("models.list", {})).models.filter((m: { provider: string }) => m.provider === id);
		expect(models.map((m: { id: string; contextWindow: number }) => [m.id, m.contextWindow])).toEqual([["claude-local", 200000]]);
		expect(a.engine.hub.models.getProvider(id)?.getModels()[0]).toMatchObject({ api: "anthropic-messages" });

		server.close();
		const refused = await a.client.call("endpoints.check", { baseUrl: "http://127.0.0.1:9/v1" });
		expect(refused).toMatchObject({ ok: false, error: "refused" });
		const { id: later } = await a.client.call("endpoints.save", { name: "Studio", baseUrl: "http://127.0.0.1:9/v1", force: true });
		expect(((await a.client.call("providers.list", {})).providers as { id: string; status: string }[]).find((p) => p.id === later)).toMatchObject({ status: "needs_attention" });
	});
});
