/**
 * Connect your cloud with a Cloudflare API token (docs/spec/30 §3.3): Piopio deploys its Worker, makes the owner token
 * itself and gives the Worker the Mac's OpenRouter key. Against a fake Cloudflare API and a fake Worker; no network.
 */
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SECRET_OPENROUTER } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

const CF_TOKEN = "cf-token-123";

/** Cloudflare's API and the Worker it serves once deployed, as far as Piopio uses them. */
class FakeCloudflare {
	accounts = [{ id: "acc1", name: "Ana's account" }];
	subdomain: string | undefined = "acme";
	secrets: Record<string, string> = {};
	calls: string[] = [];
	/** The migration tag once the script was uploaded. */
	deployed?: string;
	readonly fetch: typeof fetch = (async (input: string | URL, init?: RequestInit) => {
		const url = String(input);
		const method = init?.method ?? "GET";
		const auth = new Headers(init?.headers).get("Authorization");
		const ok = (result: unknown) => Response.json({ success: true, errors: [], result });
		if (url.startsWith("https://api.cloudflare.com/client/v4/")) {
			const path = url.slice("https://api.cloudflare.com/client/v4".length).replace(/^\/accounts\/acc\d/, "");
			this.calls.push(`${method} ${path}`);
			if (auth !== `Bearer ${CF_TOKEN}`) return Response.json({ success: false, errors: [{ code: 10000, message: "Authentication error" }] }, { status: 403 });
			if (path.startsWith("/accounts?")) return ok(this.accounts);
			if (path === "/workers/services/piopio-cloud") return this.deployed ? ok({ default_environment: { script: { migration_tag: this.deployed } } }) : Response.json({ success: false, errors: [{ message: "not found" }] }, { status: 404 });
			if (path === "/workers/scripts/piopio-cloud" && method === "PUT") {
				this.deployed = "v2";
				return ok({});
			}
			if (path === "/workers/scripts/piopio-cloud/secrets") {
				const body = JSON.parse(String(init?.body)) as { name: string; text: string };
				this.secrets[body.name] = body.text;
				return ok({});
			}
			if (path === "/workers/subdomain" && method === "GET") return this.subdomain ? ok({ subdomain: this.subdomain }) : Response.json({ success: false, errors: [{ message: "no subdomain" }] }, { status: 404 });
			if (path === "/workers/subdomain" && method === "PUT") {
				this.subdomain = (JSON.parse(String(init?.body)) as { subdomain: string }).subdomain;
				return ok({ subdomain: this.subdomain });
			}
			return ok({});
		}
		// The Worker itself, at its workers.dev address.
		if (this.subdomain && url.startsWith(`https://piopio-cloud.${this.subdomain}.workers.dev/`)) {
			if (url.endsWith("/v1/health")) return Response.json({ ok: true, version: "0.0.0" });
			if (url.endsWith("/v1/agents")) return auth === `Bearer ${this.secrets.OWNER_TOKEN}` ? Response.json({ agents: [] }) : Response.json({ error: "Bad owner token." }, { status: 401 });
		}
		return new Response("Not found", { status: 404 });
	}) as typeof fetch;
}

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function start(fake: FakeCloudflare) {
	const home = mkdtempSync(join(tmpdir(), "piopio-cloud-setup-"));
	// A stand-in for Piopio's built Worker: what the deploy uploads.
	const worker = mkdtempSync(join(tmpdir(), "piopio-worker-"));
	writeFileSync(join(worker, "index.js"), "export default {}");
	writeFileSync(join(worker, "wrangler.json"), readFileSync(new URL("../../cloud/wrangler.json", import.meta.url)));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {}, cloud: { fetch: fake.fetch, workerDir: worker, healthRetryMs: 1 } });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	return client;
}

test("one Cloudflare token: Piopio deploys its Worker, makes the owner token, and gives it the Mac's model key", async () => {
	const fake = new FakeCloudflare();
	fake.accounts.push({ id: "acc2", name: "Work" });
	const client = await start(fake);

	// Cloud agents need a model: without the Mac's OpenRouter key, it says what to do first.
	await expect(client.call("cloud.setup", { apiToken: CF_TOKEN, accountId: "acc1" })).rejects.toThrow(/Add your OpenRouter key in Settings › Models/);
	client.secrets[SECRET_OPENROUTER] = "sk-or-mac";
	await expect(client.call("cloud.setup", { apiToken: "wrong" })).rejects.toThrow(/Cloudflare refused that token/);

	// Two accounts: pick one.
	expect(await client.call("cloud.setup", { apiToken: CF_TOKEN })).toEqual({ accounts: [{ id: "acc1", name: "Ana's account" }, { id: "acc2", name: "Work" }] });
	const { status } = await client.call("cloud.setup", { apiToken: CF_TOKEN, accountId: "acc1" });
	expect(status).toMatchObject({ connected: true, reachable: true, managed: true, url: "https://piopio-cloud.acme.workers.dev", agents: [] });
	expect(fake.secrets.OPENROUTER_API_KEY).toBe("sk-or-mac");
	expect(fake.secrets.OWNER_TOKEN).toMatch(/^[0-9a-f]{64}$/);
	// The owner token went to the Keychain only; the Cloudflare token too, to update later.
	expect(client.secrets.CLOUD_OWNER_TOKEN).toBe(fake.secrets.OWNER_TOKEN);
	expect(client.secrets.CLOUD_CLOUDFLARE_TOKEN).toBe(CF_TOKEN);

	// Update: the Worker again with the key the Mac has now; the owner token stays.
	const owner = fake.secrets.OWNER_TOKEN;
	client.secrets[SECRET_OPENROUTER] = "sk-or-new";
	fake.calls = [];
	expect(await client.call("cloud.update")).toMatchObject({ connected: true, reachable: true, managed: true });
	expect(fake.secrets).toEqual({ OWNER_TOKEN: owner, OPENROUTER_API_KEY: "sk-or-new" });
	expect(fake.calls.filter((c) => c.endsWith("/secrets"))).toHaveLength(1);

	// The Keychain lost the owner token (the Worker keeps a write-only copy): Update makes a new one, on both sides.
	delete client.secrets.CLOUD_OWNER_TOKEN;
	expect(await client.call("cloud.update")).toMatchObject({ connected: true, reachable: true, managed: true });
	expect(fake.secrets.OWNER_TOKEN).toMatch(/^[0-9a-f]{64}$/);
	expect(fake.secrets.OWNER_TOKEN).not.toBe(owner);
	expect(client.secrets.CLOUD_OWNER_TOKEN).toBe(fake.secrets.OWNER_TOKEN);

	// Disconnecting forgets both tokens.
	await client.call("cloud.disconnect");
	expect(client.secrets.CLOUD_OWNER_TOKEN).toBeUndefined();
	expect(client.secrets.CLOUD_CLOUDFLARE_TOKEN).toBeUndefined();
}, 30_000);

test("a new account without a workers.dev name gets one", async () => {
	const fake = new FakeCloudflare();
	fake.subdomain = undefined;
	const client = await start(fake);
	client.secrets[SECRET_OPENROUTER] = "sk-or-mac";
	const { status } = await client.call("cloud.setup", { apiToken: CF_TOKEN });
	expect(fake.subdomain).toMatch(/^piopio-[0-9a-f]{6}$/);
	expect(status.url).toBe(`https://piopio-cloud.${fake.subdomain}.workers.dev`);
}, 30_000);

test("a cloud connected by address and owner token can't be updated from here", async () => {
	const fake = new FakeCloudflare();
	const client = await start(fake);
	client.secrets[SECRET_OPENROUTER] = "sk-or-mac";
	fake.secrets.OWNER_TOKEN = "by-hand";
	await client.call("cloud.connect", { url: "https://piopio-cloud.acme.workers.dev", token: "by-hand" });
	await expect(client.call("cloud.update")).rejects.toThrow(/Connect it with a Cloudflare token instead/);
}, 30_000);
