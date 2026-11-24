/**
 * The side-conversation replay (docs/spec/24 SD3): each message of test/replay/side-offers.json, after what came just
 * before it, against the rule the engine gives the model (`sidePrompt`, "Ask" setting). A first action of side_offer
 * (or side_start) is an offer; anything else stays. Real model, so opt-in and paid (a few cents a run):
 *
 *   PIOPIO_REPLAY=side OPENROUTER_API_KEY=… pnpm vitest run test/side-replay.test.ts
 *
 * scripts/side-replay.sh does the same and asks for the key. The set isn't in git (it's the owner's real messages);
 * without it, both tests skip. PIOPIO_REPLAY_MODELS picks OpenRouter models (comma-separated; default: the default chat model). Results go to
 * test/replay/results/side-<date>-<model>.json; the acceptance is 24 §10's.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Api, AssistantMessage, Model, Tool } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { describe, expect, test } from "vitest";
import { DEFAULT_MODEL } from "../src/models.js";
import { sidePrompt } from "../src/tools/side.js";

type Case = { id: string; previous: string; answer: string; message: string; expect: "offer" | "stay"; note?: string };

// The set is the owner's real messages, kept out of git (docs/spec/24 §11): without it, both tests skip.
const file = join(__dirname, "replay", "side-offers.json");
const set = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as { cases: Case[] }) : undefined;
const on = Boolean(set) && process.env.PIOPIO_REPLAY === "side" && Boolean(process.env.OPENROUTER_API_KEY);

/** A Build session's preamble, cut to what bears on the choice, then the side-conversation rules as sessions get them. */
export const SYSTEM = `You are Piopio, an AI assistant working with the user in their project on their Mac, a native app for building software, chatting and running agents. You read and change the project's files, run commands, and search the web, and you keep the user informed in short, plain messages.

# Side conversations
${sidePrompt([], { onUnrelated: "ask", propose: false })}`;

const tool = (name: string, description: string, parameters: object): Tool => ({ name, description, parameters });
export const TOOLS: Tool[] = [
	tool("side_offer", "Offer to give a new task its own conversation: shows a card where the user chooses New conversation or Do it here. Call it first, before any work; then end your turn. The card asks: don't restate its choices or add questions of your own.", Type.Object({ title: Type.String({ description: "A few words: the new task" }), brief: Type.Optional(Type.String({ description: "The part of the user's words that is the new task; default their whole message" })) })),
	tool("side_start", "Start a side conversation: its own conversation, linked to this one, for a task of its own.", Type.Object({ title: Type.String(), brief: Type.String() })),
	tool("read", "Read a file of the project.", Type.Object({ path: Type.String() })),
	tool("bash", "Run a shell command in the project.", Type.Object({ command: Type.String() })),
	tool("edit", "Replace text in a file.", Type.Object({ path: Type.String(), oldText: Type.String(), newText: Type.String() })),
	tool("web_search", "Search the web.", Type.Object({ query: Type.String() })),
	tool("ask_user", "Ask the user a question with options.", Type.Object({ question: Type.String() })),
];

const prior = (model: Model<Api>, text: string): AssistantMessage =>
	({ role: "assistant", content: [{ type: "text", text }], api: model.api, provider: model.provider, model: model.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() }) as AssistantMessage;

/** What the model did first: offered (side_offer / side_start), or stayed (anything else). */
export function decision(reply: AssistantMessage): { got: "offer" | "stay"; first: string; said: string } {
	const call = reply.content.find((b) => b.type === "toolCall") as { name: string; arguments?: unknown } | undefined;
	const text = reply.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join(" ").trim();
	const said = `${text.slice(0, 240)}${call ? ` [${call.name} ${JSON.stringify(call.arguments ?? {}).slice(0, 160)}]` : ""}`;
	return { got: call && (call.name === "side_offer" || call.name === "side_start") ? "offer" : "stay", first: call?.name ?? "text", said };
}

describe.skipIf(!on)("side-conversation replay (24 SD3)", () => {
	const models = (process.env.PIOPIO_REPLAY_MODELS ?? DEFAULT_MODEL.id).split(",").map((s) => s.trim()).filter(Boolean);
	for (const id of models) {
		test(`${id}: offers new tasks and keeps the rest`, async () => {
			const rt = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
			const model = rt.getModel("openrouter", id);
			if (!model) throw new Error(`No OpenRouter model ${id} in pi's catalog`);
			const results: (Case & { got: string; first: string; said: string; right: boolean; ms: number; costUsd: number })[] = [];
			const failed: { id: string; stopReason: string; error?: string }[] = [];
			const queue = [...set!.cases];
			// Four at a time: quick, and gentle with the provider.
			await Promise.all(
				Array.from({ length: 4 }, async () => {
					for (let c = queue.shift(); c; c = queue.shift()) {
						const started = Date.now();
						const reply = await rt.complete(model, {
							systemPrompt: SYSTEM,
							messages: [
								{ role: "user", content: c.previous, timestamp: started },
								prior(model, c.answer),
								{ role: "user", content: c.message, timestamp: started },
							],
							tools: TOOLS,
						}, { apiKey: process.env.OPENROUTER_API_KEY!, maxTokens: 1500 } as never);
						const { got, first, said } = decision(reply);
						// A failed or cut-off request isn't a decision: it's reported apart, not counted as staying.
						if (reply.stopReason === "error" || (first === "text" && !said)) {
							failed.push({ id: c.id, stopReason: reply.stopReason, error: (reply as { errorMessage?: string }).errorMessage });
							continue;
						}
						results.push({ ...c, got, first, said, right: got === c.expect, ms: Date.now() - started, costUsd: reply.usage?.cost?.total ?? 0 });
					}
				}),
			);
			const offers = results.filter((r) => r.expect === "offer");
			const stays = results.filter((r) => r.expect === "stay");
			const recall = offers.filter((r) => r.got === "offer").length / offers.length;
			const falseOffers = stays.filter((r) => r.got === "offer").length;
			const summary = {
				at: new Date().toISOString(),
				model: { provider: "openrouter", id },
				right: results.filter((r) => r.right).length,
				total: results.length,
				offeredNewTasks: `${offers.filter((r) => r.got === "offer").length}/${offers.length}`,
				falseOffers: `${falseOffers}/${stays.length}`,
				passes: recall >= 0.9 && falseOffers / stays.length <= 1 / 20,
				costUsd: Number(results.reduce((s, r) => s + r.costUsd, 0).toFixed(4)),
				failed,
				wrong: results.filter((r) => !r.right).map(({ id: cid, message, expect: want, got, first, said, note }) => ({ id: cid, expect: want, got, first, message: message.slice(0, 160), said, ...(note ? { note } : {}) })),
			};
			const dir = join(__dirname, "replay", "results");
			mkdirSync(dir, { recursive: true });
			const label = process.env.PIOPIO_REPLAY_LABEL ? `-${process.env.PIOPIO_REPLAY_LABEL}` : "";
			writeFileSync(join(dir, `side-${summary.at.slice(0, 10)}-${id.split("/").pop()}${label}.json`), `${JSON.stringify({ ...summary, results }, null, "\t")}\n`);
			expect(summary.total + failed.length).toBe(set!.cases.length);
		}, 600_000);
	}
});

test.skipIf(!set)("the replay set is balanced and labeled (24 SD3)", () => {
	const { cases } = set!;
	expect(cases.length).toBeGreaterThanOrEqual(50);
	expect(new Set(cases.map((c) => c.id)).size).toBe(cases.length);
	const offers = cases.filter((c) => c.expect === "offer").length;
	expect(offers).toBeGreaterThan(cases.length * 0.35);
	expect(offers).toBeLessThan(cases.length * 0.65);
	for (const c of cases) expect(c.message.trim().length).toBeGreaterThan(0);
});
