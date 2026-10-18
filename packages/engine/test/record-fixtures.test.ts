/**
 * Re-records the raw upstream event fixtures used by mappers.test.ts.
 *   RECORD_FIXTURES=1 pnpm test test/record-fixtures.test.ts             # faux model
 *   RECORD_FIXTURES=real OPENROUTER_API_KEY=… pnpm test test/record-fixtures.test.ts   # OpenRouter
 */
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

const mode = process.env.RECORD_FIXTURES;

/** Fixtures are committed: drop system prompts (they list local skills) and local paths. */
function sanitize(jsonl: string, tempHome: string): string {
	const repo = new URL("../../../", import.meta.url).pathname.replace(/\/$/, "");
	return jsonl
		.split("\n")
		.filter(Boolean)
		.map((line) => {
			const event = JSON.parse(line, (_key, value: { role?: string; timestamp?: number } | unknown) =>
				value && typeof value === "object" && (value as { role?: string }).role === "system"
					? { role: "system", timestamp: (value as { timestamp?: number }).timestamp, content: "[system prompt omitted]" }
					: value,
			);
			return JSON.stringify(event).replaceAll(tempHome, "<tmp>").replaceAll(repo, "<repo>").replaceAll(homedir(), "<home>");
		})
		.join("\n")
		.concat("\n");
}
const fixtures = new URL("./fixtures/", import.meta.url).pathname;

test.runIf(mode === "1" || mode === "real")("record fixtures", async () => {
	const real = mode === "real";
	const home = mkdtempSync(join(tmpdir(), "piopio-rec-"));
	const rawDir = join(home, "raw");
	process.env.PIOPIO_RECORD_DIR = rawDir;
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: !real, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	client.secrets["provider.openrouter.apiKey"] = process.env.OPENROUTER_API_KEY ?? "";
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "recorder", protocolVersion: "1.0" });

	const run = async (kind: "thread" | "build", text: string, name: string) => {
		const { ref } = await client.call("sessions.create", { kind, ...(kind === "build" ? { cwd: home } : {}) });
		const sub = await client.call("sessions.subscribe", { ref });
		await client.call("sessions.submit", { ref, input: { text } });
		await client.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.seq > 1 && n.events.some((e) => e.type === "state" && e.state.status === "idle"), 120_000);
		const raw = readdirSync(rawDir).find((f) => f.includes(ref.id))!;
		writeFileSync(join(fixtures, `${name}.jsonl`), sanitize(readFileSync(join(rawDir, raw), "utf8"), home));
	};

	const suffix = real ? "openrouter" : "faux";
	await run("thread", real ? "In one short sentence: why is the sky blue?" : "hello piopio", `pi-durable-chat-${suffix}`);
	await run("build", real ? "Reply with exactly: ok" : "hello piopio", `pi-sdk-chat-${suffix}`);
	if (!real) {
		engine.hub.faux!.setResponses([
			fauxAssistantMessage([fauxText("Let me check."), fauxToolCall("bash", { command: "echo from-tool" })], { stopReason: "toolUse" }),
			fauxAssistantMessage([fauxText("The tool said from-tool.")]),
		]);
	}
	await run("build", real ? "Run `echo from-tool` with bash, then tell me what it printed." : "run a tool", `pi-sdk-tools-${suffix}`);

	client.close();
	await engine.stop();
}, 300_000);
