/**
 * Models follow pi's own configuration (docs/spec/10 §14): the `models.json` in pi's folder, and pi's catalog on
 * pi.dev for models newer than the pi this build ships.
 */
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

test("a custom endpoint is a provider in pi's models.json: its models' abilities from the server or pi's catalog, your edits kept", async () => {
	const base = await new ModelHub(new SecretBroker({}), { faux: true, home: scratch("endpoint-base") }).ready();
	// A model pi knows, as a gateway would name it.
	const known = base.getProvider("anthropic")!.getModels().find((m) => m.reasoning && m.input.includes("image"))!;
	const gateway = `Anthropic/${known.id.toUpperCase()}`;
	const served = [{ id: gateway }, { id: "llava-local", architecture: { input_modalities: ["text", "image"] }, supported_parameters: ["tools"] }, { id: "plain-local" }, { id: "bge-embed" }];
	const server = createServer((req, res) => (req.url === "/v1/models" ? res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ data: served })) : res.writeHead(404).end()));
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
	const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
	const piAgentDir = scratch("endpoint-pi");
	const file = join(piAgentDir, "models.json");
	// The file is yours: a comment, and a provider of your own.
	writeFileSync(file, `{\n\t// my own servers\n\t"providers": {\n\t\t"mine": { "baseUrl": "http://127.0.0.1:9/v1", "api": "openai-completions", "apiKey": "k", "models": [{ "id": "m1" }] }\n\t}\n}\n`);
	try {
		const hub = new ModelHub(new SecretBroker({}), { faux: true, home: scratch("endpoint-home"), piAgentDir });
		const endpoint = await hub.saveEndpoint({ name: "Gateway", baseUrl });
		expect(endpoint.id).toBe("custom-gateway");
		const rt = await hub.ready();
		const model = (id: string) => {
			const m = rt.getModel(endpoint.id, id)!;
			return { images: m.input.includes("image"), thinks: m.reasoning };
		};
		// From pi's catalog, by the same id whatever its case or prefix; its output limit too.
		expect(model(gateway)).toEqual({ images: true, thinks: true });
		expect(rt.getModel(endpoint.id, gateway)!.maxTokens).toBeGreaterThan(16_384);
		// From the server's own list.
		expect(model("llava-local")).toEqual({ images: true, thinks: false });
		// Unknown to both: text only. Embedding models aren't chat models.
		expect(model("plain-local")).toEqual({ images: false, thinks: false });
		expect(rt.getModel(endpoint.id, "bge-embed")).toBeUndefined();

		// Written into the file beside what was there, which stays as it was. The one you wrote by hand is listed too.
		const text = readFileSync(file, "utf8");
		expect(text).toContain("// my own servers");
		expect(text).toContain('"mine": { "baseUrl": "http://127.0.0.1:9/v1"');
		expect((await hub.listProviders(() => false)).filter((p) => p.kind === "custom").map((p) => p.id).sort()).toEqual(["custom-gateway", "mine"]);

		// You correct a model by hand; the server gains one. Saving again keeps your correction and adds the new one.
		writeFileSync(file, readFileSync(file, "utf8").replace(/("id": "plain-local",[^}]*?"reasoning": )false/s, "$1true"));
		served.push({ id: "new-local" });
		await hub.saveEndpoint({ id: endpoint.id, name: "Gateway (work)", baseUrl });
		expect(model("plain-local")).toEqual({ images: false, thinks: true });
		expect(model("new-local")).toEqual({ images: false, thinks: false });
		expect(rt.getProvider(endpoint.id)?.name).toBe("Gateway (work)");
		expect(readFileSync(file, "utf8")).toContain("// my own servers");

		// Removed: only its own entry goes.
		await hub.removeEndpoint(endpoint.id);
		expect(rt.getProvider(endpoint.id)).toBeUndefined();
		expect(readFileSync(file, "utf8")).toContain('"mine"');
		expect(readFileSync(file, "utf8")).not.toContain("custom-gateway");
	} finally {
		server.close();
	}
});

