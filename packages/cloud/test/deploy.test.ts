/** The token deploy script against a fake Cloudflare API (no network, no account). */
import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";
import { CloudflareApi, deploy, pendingMigrations, readBundle, type WranglerConfig } from "../scripts/deploy.ts";

const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as WranglerConfig;

describe("pendingMigrations", () => {
	const cfg = { ...config, migrations: [{ tag: "v1", new_sqlite_classes: ["AgentDO"] }, { tag: "v2", new_sqlite_classes: ["RegistryDO"] }] };
	test("first deploy applies everything", () => {
		expect(pendingMigrations(cfg, undefined)).toEqual({ new_tag: "v2", steps: [{ new_sqlite_classes: ["AgentDO"] }, { new_sqlite_classes: ["RegistryDO"] }] });
	});
	test("applies only what is newer than the deployed tag", () => {
		expect(pendingMigrations(cfg, "v1")).toEqual({ old_tag: "v1", new_tag: "v2", steps: [{ new_sqlite_classes: ["RegistryDO"] }] });
		expect(pendingMigrations(cfg, "v2")).toBeUndefined();
	});
});

type Call = { method: string; url: string; body?: unknown };

function fakeCloudflare(deployedTag?: string) {
	const calls: Call[] = [];
	const ok = (result: unknown) => Response.json({ success: true, errors: [], result });
	const fetchImpl = (async (input: string | URL, init?: RequestInit) => {
		const url = String(input);
		const method = init?.method ?? "GET";
		let body: unknown = init?.body;
		if (body instanceof FormData) {
			const parts: Record<string, unknown> = {};
			for (const [k, v] of body.entries()) parts[k] = v instanceof Blob ? { type: v.type, size: v.size, text: k === "metadata" ? JSON.parse(await v.text()) : undefined } : v;
			body = parts;
		}
		else if (typeof body === "string") body = JSON.parse(body);
		calls.push({ method, url, body });
		if (url.endsWith("/workers/services/piopio-cloud")) return deployedTag ? ok({ default_environment: { script: { migration_tag: deployedTag } } }) : Response.json({ success: false, errors: [{ code: 10090, message: "not found" }] }, { status: 404 });
		if (url.endsWith("/workers/subdomain")) return ok({ subdomain: "acme" });
		if (url.endsWith("/v1/health")) return Response.json({ ok: true });
		return ok({});
	}) as typeof fetch;
	return { calls, fetchImpl };
}

const bundle = { main: "index.js", modules: [{ name: "index.js", contentType: "application/javascript+module", body: new TextEncoder().encode("export default {}") }] };

test("first deploy: upload with DO migration, secrets, workers.dev, health check", async () => {
	const { calls, fetchImpl } = fakeCloudflare();
	const url = await deploy({ api: new CloudflareApi("tok", "acc", fetchImpl), config, bundle, secrets: { OWNER_TOKEN: "o", OPENROUTER_API_KEY: "k" }, vars: {}, fetchImpl });
	expect(url).toBe("https://piopio-cloud.acme.workers.dev");
	expect(calls.map((c) => `${c.method} ${c.url.replace("https://api.cloudflare.com/client/v4/accounts/acc", "")}`)).toEqual([
		"GET /workers/services/piopio-cloud",
		"PUT /workers/scripts/piopio-cloud",
		"PUT /workers/scripts/piopio-cloud/secrets",
		"PUT /workers/scripts/piopio-cloud/secrets",
		"POST /workers/scripts/piopio-cloud/subdomain",
		"GET /workers/subdomain",
		"GET https://piopio-cloud.acme.workers.dev/v1/health",
	]);
	const upload = calls[1]!.body as Record<string, { type: string; text?: any }>;
	expect(upload["index.js"]!.type).toBe("application/javascript+module");
	expect(upload.metadata!.text).toEqual({
		main_module: "index.js",
		compatibility_date: config.compatibility_date,
		compatibility_flags: config.compatibility_flags,
		bindings: [{ type: "durable_object_namespace", name: "AGENT", class_name: "AgentDO" }],
		keep_bindings: ["secret_text"],
		migrations: { new_tag: "v1", steps: [{ new_sqlite_classes: ["AgentDO"] }] },
		observability: { enabled: true },
	});
	expect(calls[2]!.body).toEqual({ name: "OWNER_TOKEN", text: "o", type: "secret_text" });
});

test("redeploy at the same migration tag sends no migrations", async () => {
	const { calls, fetchImpl } = fakeCloudflare("v1");
	await deploy({ api: new CloudflareApi("tok", "acc", fetchImpl), config, bundle, secrets: {}, vars: { PIOPIO_DEFAULT_MODEL: "openrouter/x" }, fetchImpl });
	const metadata = (calls[1]!.body as Record<string, { text?: any }>).metadata!.text;
	expect(metadata.migrations).toBeUndefined();
	expect(metadata.bindings).toContainEqual({ type: "plain_text", name: "PIOPIO_DEFAULT_MODEL", text: "openrouter/x" });
	expect(calls.some((c) => c.url.endsWith("/secrets"))).toBe(false);
});

test("API errors surface Cloudflare's messages", async () => {
	const fetchImpl = (async () => Response.json({ success: false, errors: [{ code: 10000, message: "Authentication error" }] }, { status: 403 })) as unknown as typeof fetch;
	await expect(deploy({ api: new CloudflareApi("bad", "acc", fetchImpl), config, bundle, secrets: {}, vars: {}, fetchImpl })).rejects.toThrow(/403\): 10000: Authentication error/);
});

test("reads the wrangler bundle", () => {
	const b = readBundle(new URL("../dist", import.meta.url).pathname);
	expect(b.main).toBe("index.js");
	expect(b.modules.map((m) => m.name)).toContain("index.js");
});
