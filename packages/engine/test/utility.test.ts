import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { ModelHub } from "../src/models.js";
import { OnDeviceModel } from "../src/on-device.js";
import { agentUtility } from "../src/runtimes/agent.js";
import { SecretBroker } from "../src/secrets.js";

/** A stand-in for piopio-fm: answers like the helper, and logs each request it got. */
function fakeHelper(mode: "available" | "unavailable" | "fails"): { path: string; requests: () => { instructions: string; prompt: string }[] } {
	const dir = mkdtempSync(join(tmpdir(), "piopio-fm-"));
	const log = join(dir, "requests.jsonl");
	const path = join(dir, "piopio-fm");
	writeFileSync(
		path,
		`#!/usr/bin/env node
const fs = require("node:fs");
const mode = ${JSON.stringify(mode)};
if (process.argv.includes("--status")) {
	console.log(JSON.stringify(mode === "unavailable" ? { available: false, reason: "Apple Intelligence is off." } : { available: true }));
	process.exit(0);
}
const input = fs.readFileSync(0, "utf8");
fs.appendFileSync(${JSON.stringify(log)}, input + "\\n");
if (mode === "fails") { console.log(JSON.stringify({ error: "guardrail" })); process.exit(1); }
const { prompt } = JSON.parse(input);
console.log(JSON.stringify({ text: " on-device: " + prompt.slice(0, 40) + " " }));
`,
	);
	chmodSync(path, 0o755);
	return { path, requests: () => { try { return readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } } };
}

/** A hub on a scratch home: `openrouter` connected (by its index entry), a local endpoint, and a fake piopio-fm. */
function hubWith(helper: string | undefined, connect: { openrouter?: boolean; local?: boolean } = {}) {
	const home = mkdtempSync(join(tmpdir(), "piopio-hub-"));
	if (connect.openrouter) writeFileSync(join(home, "credentials.json"), JSON.stringify({ openrouter: "api_key" }));
	const hub = new ModelHub(new SecretBroker({}), { home, onDevice: new OnDeviceModel(helper) });
	if (connect.local) hub.endpoints.save({ id: "lmstudio", name: "LM Studio", baseUrl: "http://127.0.0.1:1234/v1", keyless: true, models: [{ id: "qwen3-8b" }], addedAt: new Date().toISOString() });
	return hub;
}

test("automatic: the conversation's own provider, its small model when it has one", async () => {
	const hub = hubWith(undefined, { openrouter: true, local: true });
	// A chat on a local model keeps its background work on that model.
	expect(await hub.automaticUtility({ provider: "lmstudio", id: "qwen3-8b" })).toEqual({ provider: "lmstudio", id: "qwen3-8b" });
	// A chat on OpenRouter uses OpenRouter's small model.
	expect(await hub.automaticUtility({ provider: "openrouter", id: "openai/gpt-5.5" })).toEqual({ provider: "openrouter", id: "anthropic/claude-haiku-5.5" });
	// No conversation (commit messages), or one on a provider that's gone: the default model's provider.
	expect(await hub.automaticUtility()).toEqual({ provider: "openrouter", id: "anthropic/claude-haiku-5.5" });
	expect(await hub.automaticUtility({ provider: "anthropic", id: "claude-opus-5-5" })).toEqual({ provider: "openrouter", id: "anthropic/claude-haiku-5.5" });
	// Only a local model connected: that one.
	expect(await hubWith(undefined, { local: true }).automaticUtility()).toMatchObject({ provider: "lmstudio" });
	expect(await hubWith(undefined).automaticUtility()).toBeUndefined();
});

test("with nothing connected, automatic uses Apple's model when it's there; off and on-device are honored", async () => {
	const fm = fakeHelper("available");
	const hub = hubWith(fm.path);
	expect(await hub.utility("Summarize.", "the sink moves 40 cm", "thread-a")).toBe("on-device: the sink moves 40 cm");
	expect(hub.extraCosts.summary("thread-a")).toMatchObject({ calls: 1, knownUsd: 0, unknownCalls: 0 });
	hub.utilityChoice = () => "off";
	expect(await hub.utility("Summarize.", "x")).toBeUndefined();
	// An agent's own choice wins over the setting.
	expect(await hub.utility("Extract facts.", "y", "agent-a", agentUtility("on-device"))).toBe("on-device: y");
	expect(fm.requests()).toHaveLength(2);
	expect(await hubWith(fakeHelper("unavailable").path).utility("Summarize.", "x")).toBeUndefined();
});

test("a picked model whose provider isn't connected is skipped; the scripted model has no utility model", async () => {
	const hub = hubWith(undefined, { local: true });
	hub.utilityChoice = () => ({ provider: "openrouter", id: "anthropic/claude-haiku-5.5" });
	expect(await hub.utility("Summarize.", "x")).toBeUndefined();
	expect(await new ModelHub(new SecretBroker({}), { faux: true, onDevice: new OnDeviceModel(fakeHelper("available").path) }).utility("Summarize.", "x")).toBeUndefined();
});

test("Apple's model: status, failures, and input cut to fit its context", async () => {
	expect(await new OnDeviceModel(fakeHelper("unavailable").path).status()).toEqual({ available: false, reason: "Apple Intelligence is off." });
	expect(await new OnDeviceModel(undefined).status()).toMatchObject({ available: false, reason: expect.stringContaining("Piopio app") });
	await expect(hubWith(fakeHelper("fails").path).utility("Summarize.", "x")).rejects.toMatchObject({ code: "MODEL_ERROR" });
	const fm = fakeHelper("available");
	await hubWith(fm.path).utility("Summarize.", "a".repeat(20_000));
	expect(fm.requests()[0]!.prompt.length).toBeLessThan(9_100);
});

test("an agent's models.utility", () => {
	expect(agentUtility(undefined)).toEqual({});
	expect(agentUtility("auto")).toEqual({});
	expect(agentUtility("off")).toEqual({ choice: "off" });
	expect(agentUtility("on-device")).toEqual({ choice: "on_device" });
	expect(agentUtility("ollama:llama4")).toEqual({ choice: { provider: "ollama", id: "llama4" } });
});
