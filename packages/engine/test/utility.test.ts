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

const hubWith = (helper: string | undefined) => new ModelHub(new SecretBroker({}), { faux: true, onDevice: new OnDeviceModel(helper) });

test("general utility work runs on this Mac by default; learned facts run nowhere until chosen", async () => {
	const fm = fakeHelper("available");
	const hub = hubWith(fm.path);
	expect(await hub.utility("Summarize.", "the sink moves 40 cm", "thread-a")).toBe("on-device: the sink moves 40 cm");
	expect(await hub.utility("Extract facts.", "Alex lives in Valencia", "agent-a", { task: "learning" })).toBeUndefined();
	expect(fm.requests()).toHaveLength(1);
	expect(hub.extraCosts.summary("thread-a")).toMatchObject({ calls: 1, knownUsd: 0, unknownCalls: 0 });

	hub.utilityChoices = () => ({ learning: "on_device" });
	expect(await hub.utility("Extract facts.", "Alex lives in Valencia", "agent-a", { task: "learning" })).toBe("on-device: Alex lives in Valencia");
	hub.utilityChoices = () => ({ utility: "off" });
	expect(await hub.utility("Summarize.", "x")).toBeUndefined();
	// An agent's own choice wins over the setting.
	expect(await hub.utility("Extract facts.", "y", "agent-a", { task: "learning", ...agentUtility("on-device") })).toBe("on-device: y");
	expect(fm.requests()).toHaveLength(3);
});

test("nothing falls back to another provider when the choice can't run", async () => {
	const off = fakeHelper("unavailable");
	const hub = hubWith(off.path);
	expect(await hub.utility("Summarize.", "x")).toBeUndefined();
	expect(off.requests()).toHaveLength(0);
	expect(await hub.onDevice.status()).toEqual({ available: false, reason: "Apple Intelligence is off." });
	expect(await hubWith(undefined).onDevice.status()).toMatchObject({ available: false, reason: expect.stringContaining("Piopio app") });
	// A picked model whose provider isn't connected: skipped too, not sent elsewhere.
	hub.utilityChoices = () => ({ utility: { provider: "openrouter", id: "anthropic/claude-haiku-5.5" } });
	expect(await hub.utility("Summarize.", "x")).toBeUndefined();
	await expect(hubWith(fakeHelper("fails").path).utility("Summarize.", "x")).rejects.toMatchObject({ code: "MODEL_ERROR" });
});

test("long input is cut to fit the on-device model's context", async () => {
	const fm = fakeHelper("available");
	await hubWith(fm.path).utility("Summarize.", "a".repeat(20_000));
	expect(fm.requests()[0]!.prompt.length).toBeLessThan(9_100);
});

test("an agent's models.utility", () => {
	expect(agentUtility(undefined)).toEqual({});
	expect(agentUtility("off")).toEqual({ choice: "off" });
	expect(agentUtility("on-device")).toEqual({ choice: "on_device" });
	expect(agentUtility("ollama:llama4")).toEqual({ choice: { provider: "ollama", id: "llama4" } });
});
