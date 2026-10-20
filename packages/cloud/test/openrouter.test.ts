/**
 * Opt-in: a real OpenRouter answer from inside workerd. Runs only with a key:
 *   OPENROUTER_API_KEY=sk-or-… corepack pnpm --filter @piopio/cloud test openrouter
 * PIOPIO_DEFAULT_MODEL (provider/model) picks the model; default: DEFAULT_MODEL in src/models.ts.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Snapshot } from "@piopio/protocol";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { expect, test } from "vitest";
import { WsClient } from "./client.js";

const key = process.env.OPENROUTER_API_KEY;
const config = JSON.parse(readFileSync(new URL("../wrangler.json", import.meta.url), "utf8")) as { name: string; compatibility_date: string; compatibility_flags: string[] };

test.skipIf(!key)(
	"streams a real OpenRouter answer with usage and cost",
	async () => {
		const mf = new Miniflare(
			convertV4MiniflareOptions({
				name: config.name,
				modules: true,
				scriptPath: fileURLToPath(new URL("../dist/index.js", import.meta.url)),
				compatibilityDate: config.compatibility_date,
				compatibilityFlags: config.compatibility_flags,
				durableObjects: { AGENT: { className: "AgentDO", useSQLite: true } },
				bindings: { OWNER_TOKEN: "t", OPENROUTER_API_KEY: key!, ...(process.env.PIOPIO_DEFAULT_MODEL ? { PIOPIO_DEFAULT_MODEL: process.env.PIOPIO_DEFAULT_MODEL } : {}) },
			}),
		);
		try {
			const base = await mf.ready;
			const ref = { kind: "agent", id: "openrouter" };
			const c = await WsClient.connect(`${base.href.replace(/^http/, "ws")}v1/ws?agent=openrouter`);
			await c.call("engine.hello", { token: "t", client: "test", protocolVersion: "1.0" });
			const sub = await c.call("sessions.subscribe", { ref });
			await c.call("sessions.submit", { ref, input: { text: "Reply with the single word: pong" } });
			await c.waitFor((n) => n.subscriptionId === sub.subscriptionId && n.seq > 1 && n.events.some((e) => e.type === "state" && e.state.status === "idle"), 60_000);
			const snap: Snapshot = (await c.call("sessions.subscribe", { ref })).snapshot;
			const answer = snap.items.find((i) => i.kind === "assistant");
			expect(answer).toMatchObject({ kind: "assistant", status: "done" });
			expect(answer?.kind === "assistant" && answer.parts.map((p) => p.text).join("").toLowerCase()).toContain("pong");
			expect(snap.state.usage.outputTokens).toBeGreaterThan(0);
			expect(snap.state.usage.costUsd).toBeGreaterThan(0);
			c.close();
		} finally {
			await mf.dispose();
		}
	},
	90_000,
);
