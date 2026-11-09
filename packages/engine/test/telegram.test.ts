import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { splitMessage, toTelegramHtml } from "../src/channels/telegram.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

/** A Telegram Bot API stand-in: one bot, updates you push, messages it records. */
class FakeTelegram {
	sent: { chat_id: number | string; text: string; parse_mode?: string }[] = [];
	private queue: unknown[] = [];
	private nextId = 1;
	readonly fetch: typeof fetch = (async (url: string, init?: RequestInit) => {
		const method = url.split("/").pop()!;
		const body = JSON.parse(String(init?.body ?? "{}"));
		const ok = (result: unknown) => new Response(JSON.stringify({ ok: true, result }), { status: 200 });
		if (!url.includes("/bot123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/")) return new Response(JSON.stringify({ ok: false, description: "Unauthorized" }), { status: 401 });
		if (method === "getMe") return ok({ id: 1, username: "piopio_test_bot" });
		if (method === "sendMessage") {
			this.sent.push(body);
			return ok({ message_id: this.sent.length });
		}
		if (method === "sendChatAction") return ok(true);
		if (method === "getUpdates") {
			const ready = this.queue.filter((u) => (u as { update_id: number }).update_id >= body.offset);
			if (ready.length) return ok(ready);
			await new Promise((r) => setTimeout(r, 30));
			return ok([]);
		}
		return ok(null);
	}) as never;

	message(chatId: number, text: string, from = "Antonio"): void {
		this.queue.push({ update_id: this.nextId++, message: { message_id: this.nextId, chat: { id: chatId, type: "private" }, from: { id: chatId, first_name: from }, text } });
	}
}

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 8000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 400)}`);
		await new Promise((r) => setTimeout(r, 40));
	}
}

test("Markdown becomes Telegram's HTML; long answers are split", () => {
	expect(toTelegramHtml("**Done.** See `a<b>` and [the doc](https://x.y/z).\n\n```js\nif (a < b) {}\n```")).toBe(
		'<b>Done.</b> See <code>a&lt;b&gt;</code> and <a href="https://x.y/z">the doc</a>.\n\n<pre>if (a &lt; b) {}</pre>',
	);
	expect(toTelegramHtml("# Plan\n- *one*")).toBe("<b>Plan</b>\n- <i>one</i>");
	const parts = splitMessage(`${"a".repeat(3000)}\n\n${"b".repeat(3000)}`);
	expect(parts).toEqual(["a".repeat(3000), "b".repeat(3000)]);
});

test("Telegram from the Mac: paste the token, pair with the link, talk; the token never reaches the model (docs/spec/19 S4)", async () => {
	const fake = new FakeTelegram();
	const home = mkdtempSync(join(tmpdir(), "piopio-tg-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {}, telegram: { fetch: fake.fetch, pollSeconds: 0, retryMs: 50 } });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	const { ref } = await client.call("agents.create", { name: "Coach", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	await client.call("sessions.subscribe", { ref });

	// A bad token says so and changes nothing.
	await client.call("sessions.submit", { ref, input: { text: "999999999:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" } });
	// The real one connects: the secret is kept, the definition gets the channel, and the chat shows the pairing link.
	await client.call("sessions.submit", { ref, input: { text: "here: 123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } });
	const def = await until(() => client.call("agents.get", { ref }), (d: { definition: { channels?: { telegram?: unknown } } }) => Boolean(d.definition.channels?.telegram));
	expect(def.definition.channels.telegram).toEqual({ bot: "secret:TELEGRAM_" + ref.id.toUpperCase() });
	expect(client.secrets["TELEGRAM_" + ref.id.toUpperCase()]).toBe("123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
	const items = (await client.call("sessions.open", { ref })).items as { kind: string; text?: string }[];
	expect(JSON.stringify(items)).not.toContain("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
	expect(items.some((i) => i.kind === "user")).toBe(false); // neither message started a turn
	expect(JSON.stringify(items)).toContain("t.me/piopio_test_bot?start=");

	// A stranger gets the polite line; the owner's link pairs them.
	const code = JSON.parse(readFileSync(join(home, "channels", "telegram", `${ref.id}.json`), "utf8")).pairing.code as string;
	fake.message(5555555, "/start");
	fake.message(4242424, `/start ${code}`);
	await until(() => client.call("agents.get", { ref }), (d: { definition: { contacts: { role: string; channels?: { telegram?: string } }[] } }) => d.definition.contacts.find((c) => c.role === "owner")?.channels?.telegram === "4242424");
	await until(() => fake.sent, (s) => s.some((m) => m.chat_id === 4242424 && m.text.includes("I'm Coach")));
	expect(fake.sent.find((m) => m.chat_id === 5555555)?.text).toContain("I only talk with the people my owner adds");

	// A message from the owner on Telegram is a turn in their conversation; the answer goes back to Telegram.
	fake.message(4242424, "hello from my phone");
	await until(() => fake.sent, (s) => s.some((m) => m.chat_id === 4242424 && m.text.includes("Echo: hello from my phone")));
	const after = (await client.call("sessions.open", { ref })).items as { kind: string; text?: string }[];
	expect(after.some((i) => i.kind === "user" && i.text === "hello from my phone")).toBe(true);

	// Something said in the app stays in the app.
	const before = fake.sent.length;
	await client.call("sessions.submit", { ref, input: { text: "and this from the Mac" } });
	await until(() => client.call("sessions.open", { ref }), (s: { items: { kind: string; parts?: { text: string }[] }[] }) => s.items.some((i) => i.kind === "assistant" && JSON.stringify(i).includes("and this from the Mac")));
	await new Promise((r) => setTimeout(r, 200));
	expect(fake.sent.length).toBe(before);
}, 30_000);
