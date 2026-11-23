/** After the Mac sleeps, and across a flaky network (the operational review, sleep and connections). */
import { TelegramBot, TelegramError } from "@piopio/runtime";
import { afterEach, expect, test, vi } from "vitest";
import { AgentSocket } from "../src/cloud.js";
import { ConnectorHub, NeedsSignIn } from "../src/connectors/hub.js";
import { SecretBroker } from "../src/secrets.js";
import { WakeWatch } from "../src/wake.js";

afterEach(() => {
	vi.useRealTimers();
});

test("a wake is noticed when much more wall time passed than the timer waited, with about how long it slept", () => {
	let clock = 1_000_000;
	const watch = new WakeWatch(() => clock, 15_000, 45_000);
	const slept: number[] = [];
	watch.onWake((ms) => slept.push(ms));
	clock += 15_000;
	watch.check(); // on time
	clock += 15_000 + 30_000;
	watch.check(); // a bit late: a busy Mac, not a sleep
	clock += 15_000 + 3 * 3600_000;
	watch.check(); // three hours asleep
	expect(slept).toEqual([3 * 3600_000]);
});

test("Telegram gives up on a request that never answers, instead of waiting forever", async () => {
	vi.useFakeTimers();
	const hanging = ((_url: string, init: RequestInit) =>
		new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(init.signal!.reason)))) as unknown as typeof fetch;
	const bot = new TelegramBot("t", hanging);
	const updates = bot.getUpdates(0, 25);
	const rejected = expect(updates).rejects.toBeInstanceOf(TelegramError);
	await vi.advanceTimersByTimeAsync(40_000);
	await rejected;
	// Stopping the poll is still a stop, not a timeout.
	const stop = new AbortController();
	const stopped = bot.getUpdates(0, 25, stop.signal);
	stop.abort(new Error("stopped"));
	await expect(stopped).rejects.toThrow("stopped");
});

/** A socket the test drives: what was sent, and the events it fires. */
class FakeSocket extends EventTarget {
	readyState = 0;
	sent: { id: number; method: string }[] = [];
	send(data: string) {
		this.sent.push(JSON.parse(data));
	}
	close() {
		this.readyState = 3;
		this.dispatchEvent(new Event("close"));
	}
	open() {
		this.readyState = 1;
		this.dispatchEvent(new Event("open"));
	}
	answer(id: number, result: unknown) {
		this.dispatchEvent(Object.assign(new Event("message"), { data: JSON.stringify({ jsonrpc: "2.0", id, result }) }));
	}
}

test("the cloud socket: calls wait for engine.hello, a drop during it fails it, and a silent socket is closed", async () => {
	vi.useFakeTimers();
	const sockets: FakeSocket[] = [];
	const agent = new AgentSocket("wss://x", async () => "tok", () => {
		const s = new FakeSocket();
		sockets.push(s);
		return s as never;
	});
	// Dropped while saying hello: the call fails instead of waiting forever.
	const first = agent.call("agents.runs", {});
	await vi.advanceTimersByTimeAsync(0);
	sockets[0]!.open();
	await vi.advanceTimersByTimeAsync(0);
	expect(sockets[0]!.sent.map((m) => m.method)).toEqual(["engine.hello"]);
	sockets[0]!.close();
	await expect(first).rejects.toThrow(/dropped/);
	// Next time: nothing else goes out before the hello is answered.
	const second = agent.call("agents.runs", {});
	await vi.advanceTimersByTimeAsync(0);
	sockets[1]!.open();
	await vi.advanceTimersByTimeAsync(0);
	const third = agent.call("agents.status", {});
	await vi.advanceTimersByTimeAsync(0);
	expect(sockets[1]!.sent.map((m) => m.method)).toEqual(["engine.hello"]);
	sockets[1]!.answer(sockets[1]!.sent[0]!.id, { agentId: "a" });
	await vi.advanceTimersByTimeAsync(0);
	expect(sockets[1]!.sent.map((m) => m.method).sort()).toEqual(["agents.runs", "agents.status", "engine.hello"]);
	// No answer in a minute: the socket counts as dead and is closed.
	const late = Promise.all([second, third]).catch((e: Error) => e);
	await vi.advanceTimersByTimeAsync(61_000);
	expect(await late).toBeInstanceOf(Error);
	expect(sockets[1]!.readyState).toBe(3);
});

/** A hub with one Google account whose access token has expired; `token` answers the token endpoint. */
async function expiredAccount(token: (body: URLSearchParams) => Promise<Response>) {
	const calls: string[] = [];
	const fetchImpl = (async (url: string, init?: RequestInit) => {
		calls.push(String(url));
		if (String(url).includes("oauth2.googleapis.com/token")) return token(new URLSearchParams(String(init?.body)));
		return new Response("{}", { status: 200 });
	}) as unknown as typeof fetch;
	const secrets = new SecretBroker({});
	const hub = new ConnectorHub(secrets, { fetchImpl });
	const account = { id: "google-calendar:me", connector: "google-calendar", label: "me@example.com" };
	await secrets.set((hub as unknown as { secretName(id: string): string }).secretName(account.id), JSON.stringify({ access: "old", refresh: "r1", expires: 0 }));
	return { hub, account, calls, problems: (hub as unknown as { problems: Map<string, string> }).problems };
}

test("a renewal that can't reach the provider isn't 'sign in again'; one it refuses is", async () => {
	const offline = await expiredAccount(async () => {
		throw new TypeError("fetch failed");
	});
	const error = await offline.hub.authorized(offline.account as never)("/calendars").catch((e: Error) => e);
	expect(error).not.toBeInstanceOf(NeedsSignIn);
	expect(String(error)).toContain("Try again in a moment");
	expect(offline.problems.size).toBe(0);
	const refused = await expiredAccount(async () => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }));
	await expect(refused.hub.authorized(refused.account as never)("/calendars")).rejects.toBeInstanceOf(NeedsSignIn);
	expect(refused.problems.size).toBe(1);
});

test("two requests that need a renewal at once make one, shared by every fetch for the account", async () => {
	let release!: () => void;
	const gate = new Promise<void>((r) => (release = r));
	const a = await expiredAccount(async () => {
		await gate;
		return new Response(JSON.stringify({ access_token: "new", refresh_token: "r2", expires_in: 3600 }), { status: 200 });
	});
	const one = a.hub.authorized(a.account as never)("/calendars");
	const two = a.hub.authorized(a.account as never)("/events");
	await new Promise((r) => setTimeout(r, 10));
	release();
	await Promise.all([one, two]);
	expect(a.calls.filter((u) => u.includes("/token")).length).toBe(1);
});
