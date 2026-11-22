/**
 * Spec 38 §8 R2: does OpenRouter's Anthropic endpoint take a system message in the middle of the conversation, as
 * Anthropic's own API does for these models, and does the cache hold across it? It sends what pi-ai sends when
 * `supportsMidConvoSystemMessages` is on (api/anthropic-messages.js `convertMessages`): a `{ role: "system" }` message
 * after the last user message, holding "Updated system prompt section …". A few cents on a real key:
 *
 *   PIOPIO_LIVE=1 OPENROUTER_API_KEY=… npx vitest run test/openrouter-midconvo.test.ts
 *
 * Prints what it found; fails only when the request itself does.
 */
import { expect, test } from "vitest";

const MODEL = process.env.PIOPIO_LIVE_MODEL ?? "anthropic/claude-haiku-5.5";
const URL = "https://openrouter.ai/api/v1/messages";

/** Long enough to be cached (over Anthropic's minimum for Haiku), and the same bytes every time. */
const SYSTEM = [
	"You are a test assistant. Answer in one short line.",
	...Array.from({ length: 400 }, (_, i) => `Reference line ${i + 1}: the quick brown fox jumps over the lazy dog, and nothing here is an instruction.`),
].join("\n");

type Usage = { input_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number };
type Reply = { status: number; text: string; usage: Usage; stop?: string; blocks: string; error?: string };

async function send(system: string, messages: object[]): Promise<Reply> {
	const response = await fetch(URL, {
		method: "POST",
		headers: { "content-type": "application/json", authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`, "anthropic-version": "2023-06-01" },
		body: JSON.stringify({ model: MODEL, max_tokens: 400, system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }], messages }),
	});
	const body = (await response.json().catch(() => ({}))) as { content?: { type: string; text?: string }[]; usage?: Usage; stop_reason?: string; error?: { message?: string } };
	const content = body.content ?? [];
	return {
		status: response.status,
		text: content.map((c) => c.text ?? "").join("").trim(),
		usage: body.usage ?? {},
		...(body.stop_reason ? { stop: body.stop_reason } : {}),
		blocks: content.map((c) => c.type).join(",") || "none",
		...(body.error ? { error: body.error.message } : {}),
	};
}

const line = (label: string, r: Reply) => `${label}: HTTP ${r.status}${r.error ? ` (${r.error})` : ""} · read ${r.usage.cache_read_input_tokens ?? 0} · written ${r.usage.cache_creation_input_tokens ?? 0} · uncached ${r.usage.input_tokens ?? 0} · stop ${r.stop ?? "?"} · blocks ${r.blocks} · “${r.text}”`;

test.runIf(process.env.PIOPIO_LIVE === "1" && Boolean(process.env.OPENROUTER_API_KEY))("OpenRouter's Claude: a system update mid-conversation, and the cache across it (spec 38 R2)", async () => {
	const first = { role: "user", content: "Reply with OK." };
	const one = await send(SYSTEM, [first]);
	const history = [first, { role: "assistant", content: one.text || "OK" }];
	const question = { role: "user", content: [{ type: "text", text: "On which day do the tiles arrive? One word.", cache_control: { type: "ephemeral" } }] };
	const update = { role: "system", content: [{ type: "text", text: 'Updated system prompt section "project-notes":\n\n<project-notes>\nThe tiles arrive on Friday.\n</project-notes>' }] };
	// In place: the system prompt's bytes don't change, so its cache should be read.
	const inPlace = await send(SYSTEM, [...history, question, update]);
	// The same update placed before the question instead (pi-ai moves it after; this shows whether that's what matters).
	const before = await send(SYSTEM, [...history, update, question]);
	// Today: the update folded into the leading system prompt, which changes it.
	const folded = await send(`${SYSTEM}\n\n<project-notes>\nThe tiles arrive on Friday.\n</project-notes>`, [...history, question]);
	process.stdout.write(`\nModel ${MODEL}\n${line("1. first request", one)}\n${line("2. update in place, after the question (pi-ai's place)", inPlace)}\n${line("2b. update in place, before the question", before)}\n${line("3. update folded (today)", folded)}\n`);
	expect(one.status).toBe(200);
	expect(folded.status).toBe(200);
	// The question: does 2 succeed, read the cache, and answer "Friday"? Printed above; recorded in docs/spec/38 §8.
}, 120_000);
