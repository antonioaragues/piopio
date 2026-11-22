/**
 * Telegram from the cloud (docs/spec/13 §5.3): the built Worker in Miniflare with the faux model, and a fake Bot API
 * behind Miniflare's outbound service. Connecting by pasting the token, pairing the owner, a message and its answer,
 * Telegram's retries, strangers, and webhooks without the secret.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, expect, test } from "vitest";
import { WsClient } from "./client.js";

const TOKEN = "owner-token";
const BOT = "123456789:AAH-trial_bot-token-0123456789abcdefghij";
const API = "http://telegram.fake";
const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

type Call = { method: string; body: Record<string, unknown> };
const calls: Call[] = [];

let mf: Miniflare;
let base: URL;
const clients: WsClient[] = [];

beforeAll(async () => {
	mf = new Miniflare(
		convertV4MiniflareOptions({
			name: config.name,
			modules: true,
			scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
			compatibilityDate: config.compatibility_date,
			compatibilityFlags: config.compatibility_flags,
			durableObjects: { AGENT: { className: "AgentDO", useSQLite: true }, REGISTRY: { className: "RegistryDO", useSQLite: true } },
			bindings: { OWNER_TOKEN: TOKEN, PIOPIO_FAUX_MODEL: "1", PIOPIO_FAUX_TPS: "200", PIOPIO_TEST_HOOKS: "1", PIOPIO_TEST_TELEGRAM_API: API },
			// The Bot API, faked: what the Worker calls is recorded.
			outboundService: async (request: Request) => {
				const url = new URL(request.url);
				const method = url.pathname.split("/").pop()!;
				if (!url.pathname.startsWith(`/bot${BOT}/`)) return Response.json({ ok: false, description: "Unauthorized" }, { status: 401 });
				const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
				calls.push({ method, body });
				if (method === "getMe") return Response.json({ ok: true, result: { id: 123456789, first_name: "Trial", username: "trial_bot" } });
				return Response.json({ ok: true, result: true });
			},
		}),
	);
	base = await mf.ready;
});

afterAll(async () => {
	for (const c of clients) c.close();
	await mf?.dispose();
});

const agent = "tg";
const ref = { kind: "agent" as const, id: agent };
const owner = { headers: { Authorization: `Bearer ${TOKEN}` } };

async function until<T>(get: () => T | Promise<T>, ok: (v: T) => boolean, ms = 15_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 600)}`);
		await new Promise((r) => setTimeout(r, 100));
	}
}

const sent = (chat: number) => calls.filter((c) => c.method === "sendMessage" && c.body.chat_id === chat).map((c) => String(c.body.text));
let nextUpdate = 1;
const post = (secret: string | undefined, message: object, updateId = nextUpdate++) =>
	mf.dispatchFetch(`${base.href}v1/channels/telegram/${agent}`, { method: "POST", headers: { "content-type": "application/json", ...(secret ? { "X-Telegram-Bot-Api-Secret-Token": secret } : {}) }, body: JSON.stringify({ update_id: updateId, message }) });
const from = (chat: number, text: string) => ({ message_id: nextUpdate, chat: { id: chat, type: "private" }, from: { id: chat, first_name: "T" }, text });

test("pasting a bot token connects Telegram from the cloud; the owner pairs, writes, and gets the answer there", async () => {
	const c = await WsClient.connect(`${base.href.replace(/^http/, "ws")}v1/ws?agent=${agent}`, TOKEN);
	clients.push(c);
	await c.call("engine.hello", { token: TOKEN, client: "test", protocolVersion: "1.0" });
	const sub = await c.call("sessions.subscribe", { ref });
	await c.call("sessions.submit", { ref, input: { text: `here is my bot: ${BOT}` } });

	// Checked and the webhook set to this Worker, with a secret; the token never reaches the transcript.
	const hook = await until(() => calls.find((x) => x.method === "setWebhook"), Boolean);
	expect(calls.map((x) => x.method).slice(0, 2)).toEqual(["getMe", "setWebhook"]);
	expect(hook!.body).toMatchObject({ url: `${base.origin}/v1/channels/telegram/${agent}`, allowed_updates: ["message"] });
	const secret = String(hook!.body.secret_token);
	expect(secret).toMatch(/^[0-9a-f]{64}$/);
	const note = await c.waitFor((n) => n.subscriptionId === sub.subscriptionId && JSON.stringify(n.events).includes("Connected to @trial_bot"));
	const link = /https:\/\/t\.me\/trial_bot\?start=([0-9a-f]+)/.exec(JSON.stringify(note.events))!;
	expect(link).toBeTruthy();
	const all = await c.call("sessions.subscribe", { ref });
	expect(JSON.stringify(all.snapshot)).not.toContain(BOT);

	// Without the secret, or with a wrong one, nothing happens.
	expect((await post(undefined, from(4242, "hi"))).status).toBe(401);
	expect((await post("nope", from(4242, "hi"))).status).toBe(401);
	// Nor for an agent with no webhook: the Worker turns it away without starting that agent (any name would start one).
	const stranger = await mf.dispatchFetch(`${base.href}v1/channels/telegram/nobody-here`, { method: "POST", headers: { "content-type": "application/json", "X-Telegram-Bot-Api-Secret-Token": secret }, body: "{}" });
	expect(stranger.status).toBe(401);

	// A stranger gets nothing but the canned line on /start; the owner pairs with the link's code.
	expect((await post(secret, from(999, "/start"))).status).toBe(200);
	await until(() => sent(999), (s) => s.length === 1);
	// Telegram opened the chat without the link's code: the bot asks for it, and the owner sends it on its own.
	expect((await post(secret, from(4242, "/start"))).status).toBe(200);
	const hint = await until(() => sent(4242), (s) => s.length === 1);
	expect(hint[0]).toMatch(/send me the code/);
	expect(hint[0]).not.toContain(link[1]);
	expect((await post(secret, from(4242, link[1]!))).status).toBe(200);
	const hello = await until(() => sent(4242), (s) => s.length === 2);
	expect(hello[1]).toMatch(/running in the cloud/);

	// The owner writes on Telegram: the turn is the owner's conversation, and the answer goes back to the chat.
	const update = nextUpdate;
	expect((await post(secret, from(4242, "hello from my phone"), update)).status).toBe(200);
	const answers = await until(() => sent(4242), (s) => s.length === 3);
	expect(answers[2]).toBe("Echo: hello from my phone");
	expect(calls.some((x) => x.method === "sendChatAction" && x.body.chat_id === 4242)).toBe(true);
	const mine = (await c.call("sessions.subscribe", { ref })).snapshot;
	expect(JSON.stringify(mine.items)).toContain("hello from my phone");

	// Telegram retries an update it thinks failed: it's answered once.
	expect((await post(secret, from(4242, "hello from my phone"), update)).status).toBe(200);
	await new Promise((r) => setTimeout(r, 1500));
	expect(sent(4242)).toHaveLength(3);
}, 60_000);
