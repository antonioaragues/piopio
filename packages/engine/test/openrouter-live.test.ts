import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";
import { describe, expect, test } from "vitest";
import { addedModels, type LiveEntry, liveModel, OpenRouterLive } from "../src/openrouter-live.js";

/** Two catalog models, as pi ships them. */
const catalog = [
	{
		type: "chat", id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek: DeepSeek V4.1 Flash", api: "openai-completions", baseUrl: "https://openrouter.ai/api/v1", provider: "openrouter",
		reasoning: true, thinkingLevelMap: { off: "none", low: "low", high: "high" }, input: ["text", "image"], cost: { input: 0.03, output: 0.13, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 1_048_576, maxTokens: 393_216, compat: { supportsDeveloperRole: false, thinkingFormat: "openrouter", requiresReasoningContentOnAssistantMessages: true }, inputLimits: { images: { resize: { maxWidth: 2000 } } },
	},
	{ type: "chat", id: "openai/gpt-6", name: "OpenAI: GPT-6", api: "openai-completions", baseUrl: "https://openrouter.ai/api/v1", provider: "openrouter", reasoning: false, input: ["text"], cost: { input: 1, output: 4, cacheRead: 0, cacheWrite: 0 }, contextWindow: 400_000, maxTokens: 64_000, compat: { supportsDeveloperRole: true } },
] as unknown as Model<Api>[];

const newDeepseek: LiveEntry = {
	id: "deepseek/deepseek-v4.1-flash-1017",
	name: "DeepSeek: DeepSeek V4.1 Flash 1017",
	context_length: 1_048_576,
	architecture: { input_modalities: ["text", "image"], output_modalities: ["text"] },
	pricing: { prompt: "0.00000015", completion: "0.0000006", input_cache_read: "0.000000003" },
	top_provider: { context_length: 1_048_576, max_completion_tokens: null },
	supported_parameters: ["tools", "reasoning", "temperature"],
};

describe("OpenRouter models newer than pi's catalog", () => {
	test("a new model takes prices and limits from OpenRouter, and request details from its closest sibling", () => {
		const model = liveModel(newDeepseek, catalog) as unknown as Record<string, unknown>;
		expect(model).toMatchObject({
			id: "deepseek/deepseek-v4.1-flash-1017",
			name: "DeepSeek: DeepSeek V4.1 Flash 1017",
			api: "openai-completions",
			provider: "openrouter",
			reasoning: true,
			thinkingLevelMap: { off: "none", low: "low", high: "high" },
			input: ["text", "image"],
			cost: { input: 0.15, output: 0.6, cacheRead: 0.003, cacheWrite: 0 },
			contextWindow: 1_048_576,
			maxTokens: 393_216,
			compat: { requiresReasoningContentOnAssistantMessages: true },
		});
		// A maker the catalog doesn't know: plain OpenRouter defaults, no reasoning levels.
		const other = liveModel({ id: "newlab/model-1", supported_parameters: ["tools"], context_length: 64_000 }, catalog) as unknown as Record<string, unknown>;
		expect(other).toMatchObject({ reasoning: false, input: ["text"], contextWindow: 64_000, maxTokens: 32_768, compat: { supportsDeveloperRole: false, thinkingFormat: "openrouter" } });
		expect(other.thinkingLevelMap).toBeUndefined();
	});

	test("only chat models with tool calling that the catalog lacks are added", () => {
		const entries: LiveEntry[] = [
			newDeepseek,
			{ id: "deepseek/deepseek-v4.1-flash", supported_parameters: ["tools"] }, // already in the catalog
			{ id: "acme/no-tools", supported_parameters: ["temperature"] },
			{ id: "acme/image-maker", supported_parameters: ["tools"], architecture: { output_modalities: ["image", "text"] } },
		];
		expect(addedModels(entries, catalog).map((m) => m.id)).toEqual(["deepseek/deepseek-v4.1-flash-1017"]);
	});

	test("the list is cached for six hours; a failed fetch keeps the cache; force asks again", async () => {
		const file = join(mkdtempSync(join(tmpdir(), "piopio-or-")), "openrouter-models.json");
		let clock = 1_000_000;
		let calls = 0;
		let fail = false;
		const fetchList = async () => {
			calls++;
			if (fail) throw new Error("offline");
			return [newDeepseek];
		};
		const live = new OpenRouterLive(file, fetchList, () => clock);
		expect(await live.update(catalog)).toBe(true);
		expect(live.models.map((m) => m.id)).toEqual(["deepseek/deepseek-v4.1-flash-1017"]);
		expect(await live.update(catalog)).toBe(false);
		expect(calls).toBe(1);
		clock += 7 * 3600_000;
		fail = true;
		expect(await live.update(catalog)).toBe(false); // offline: the cached list stays
		expect(live.models).toHaveLength(1);
		fail = false;
		await live.update(catalog, { force: true });
		expect(calls).toBe(3);
		// A new engine reads the cache without the network.
		const again = new OpenRouterLive(file, async () => {
			throw new Error("no network in this test");
		}, () => clock);
		again.recompute(catalog);
		expect(again.models.map((m) => m.id)).toEqual(["deepseek/deepseek-v4.1-flash-1017"]);
		// The wrapped provider lists the catalog and the added models.
		const base = { id: "openrouter", name: "OpenRouter", auth: {}, getModels: () => catalog } as never;
		expect(again.wrap(base).getModels().map((m) => m.id)).toEqual(["deepseek/deepseek-v4.1-flash", "openai/gpt-6", "deepseek/deepseek-v4.1-flash-1017"]);
	});
});
