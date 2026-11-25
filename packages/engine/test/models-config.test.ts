/**
 * Models follow pi's own configuration (docs/spec/10 §14): the `models.json` in pi's folder, and pi's catalog on
 * pi.dev for models newer than the pi this build ships.
 */
import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { ModelHub } from "../src/models.js";
import { SecretBroker } from "../src/secrets.js";

const scratch = (name: string) => mkdtempSync(join(tmpdir(), `piopio-${name}-`));

/** A Keychain that holds an Anthropic key and nothing else. */
function keys(): SecretBroker {
	const broker = new SecretBroker({});
	broker.addRequester(async (name) => (name.includes("anthropic") ? JSON.stringify({ type: "api_key", key: "sk-test" }) : null));
	return broker;
}

test("pi's models.json applies: a provider it adds and a built-in model it overrides", async () => {
	const plain = await new ModelHub(new SecretBroker({}), { faux: true, home: scratch("models-plain") }).ready();
	const builtin = plain.getProvider("anthropic")!.getModels()[0]!;
	expect(plain.getModel("my-proxy", "m1")).toBeUndefined();

	const piAgentDir = scratch("models-pi");
	writeFileSync(
		join(piAgentDir, "models.json"),
		JSON.stringify({
			providers: {
				"my-proxy": { baseUrl: "http://127.0.0.1:9/v1", api: "openai-completions", apiKey: "k", models: [{ id: "m1", name: "Mine", contextWindow: 32_000 }] },
				anthropic: { modelOverrides: { [builtin.id]: { name: "Renamed by me" } } },
			},
		}),
	);
	const rt = await new ModelHub(new SecretBroker({}), { faux: true, home: scratch("models-home"), piAgentDir }).ready();
	expect(rt.getModel("my-proxy", "m1")).toMatchObject({ name: "Mine", contextWindow: 32_000 });
	expect(rt.getModel("anthropic", builtin.id)?.name).toBe("Renamed by me");
});

test("a model newer than this pi comes from pi's catalog, is kept for the next start, and only when the engine follows it", async () => {
	const base = await new ModelHub(new SecretBroker({}), { faux: true, home: scratch("catalog-base") }).ready();
	const known = base.getProvider("anthropic")!.getModels()[0]!;
	const fresh = { ...known, id: "claude-from-the-catalog", name: "From the catalog" };
	let asked = 0;
	const server = createServer((req, res) => {
		if (!req.url?.startsWith("/api/models/providers/anthropic")) return void res.writeHead(404).end();
		asked++;
		res.writeHead(200, { "content-type": "application/json", "last-modified": new Date(Date.now() + 86_400_000).toUTCString(), etag: '"v1"' }).end(JSON.stringify({ models: [fresh] }));
	});
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
	const catalogBaseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
	const connected = (home: string) => writeFileSync(join(home, "credentials.json"), JSON.stringify({ anthropic: "api_key" }));
	const ids = async (hub: ModelHub, refresh: boolean) => (await hub.listModels(refresh)).filter((m) => m.provider === "anthropic").map((m) => m.id);
	try {
		// Not following (tests, the scripted model): nothing is asked.
		const offHome = scratch("catalog-off");
		connected(offHome);
		const off = new ModelHub(keys(), { home: offHome, piAgentDir: scratch("catalog-pi"), catalogBaseUrl });
		const before = await ids(off, true);
		expect(before).toContain(known.id);
		expect(before).not.toContain(fresh.id);
		expect(asked).toBe(0);

		// Following: Refresh waits for the catalog, and the new model is listed.
		const home = scratch("catalog-on");
		connected(home);
		const piAgentDir = scratch("catalog-pi");
		const on = new ModelHub(keys(), { home, piAgentDir, remoteCatalog: true, catalogBaseUrl });
		expect(await ids(on, true)).toContain(fresh.id);
		expect(asked).toBe(1);

		// The next start has it at once from what was kept, without asking again.
		const again = new ModelHub(keys(), { home, piAgentDir, remoteCatalog: true, catalogBaseUrl });
		expect(await ids(again, false)).toContain(fresh.id);
	} finally {
		server.close();
	}
}, 30_000);

test("Claude through OpenRouter keeps its mid-conversation flag when pi refreshes that provider's catalog", async () => {
	const hub = new ModelHub(new SecretBroker({}), { home: scratch("flags-home"), piAgentDir: scratch("flags-pi") });
	const rt = await hub.ready();
	const flag = () => (rt.getModel("openrouter", "anthropic/claude-haiku-5.5") as { compat?: { supportsMidConvoSystemMessages?: boolean } } | undefined)?.compat?.supportsMidConvoSystemMessages;
	expect(flag()).toBe(true);
	await rt.refresh({ providers: ["openrouter"], allowNetwork: false });
	expect(flag()).toBe(true);
});
