import type { Api, Model } from "@earendil-works/pi-ai";
import { describe, expect, test } from "vitest";
import { withClaudeFlags } from "../src/openrouter-flags.js";

describe("Claude through OpenRouter takes system messages mid-conversation (docs/spec/38 §8 R2)", () => {
	const model = (id: string, api: string, compat?: object) => ({ id, api, provider: "openrouter", ...(compat ? { compat } : {}) }) as unknown as Model<Api>;
	const base = (models: Model<Api>[]) => ({ getModels: () => models, getAllModels: () => models }) as never;

	test("a model on the Anthropic Messages API gets the flag its Anthropic entry has; nothing else changes", () => {
		const anthropic = [model("claude-haiku-5-5", "anthropic-messages", { supportsMidConvoSystemMessages: true }), model("claude-haiku-4-5", "anthropic-messages")];
		const wrapped = withClaudeFlags(base([
			model("anthropic/claude-haiku-5.5", "anthropic-messages", { forceAdaptiveThinking: true }),
			model("anthropic/claude-haiku-5.5:batch", "openai-completions"),
			model("anthropic/claude-haiku-4.5", "anthropic-messages"),
			model("openai/gpt-6-sol", "openai-completions", { supportsMidConvoSystemMessages: true }),
		]), anthropic);
		const compat = Object.fromEntries((wrapped as { getModels: () => Model<Api>[] }).getModels().map((m) => [m.id, (m as { compat?: object }).compat]));
		expect(compat["anthropic/claude-haiku-5.5"]).toEqual({ forceAdaptiveThinking: true, supportsMidConvoSystemMessages: true });
		expect(compat["anthropic/claude-haiku-5.5:batch"]).toBeUndefined();
		expect(compat["anthropic/claude-haiku-4.5"]).toBeUndefined();
		expect(compat["openai/gpt-6-sol"]).toEqual({ supportsMidConvoSystemMessages: true });
	});

	test("pi's own catalogs still line up: OpenRouter's Claude Haiku 5.5 is Anthropic's claude-haiku-5-5, which takes them", async () => {
		const { ModelRuntime } = await import("@earendil-works/pi-coding-agent");
		const { InMemoryCredentialStore } = await import("@earendil-works/pi-ai");
		const rt = await ModelRuntime.create({ credentials: new InMemoryCredentialStore(), modelsPath: null, refreshOnCreate: false });
		const anthropic = rt.getProvider("anthropic")!;
		const all = (anthropic.getAllModels?.call(anthropic) ?? anthropic.getModels()) as Model<Api>[];
		const wrapped = withClaudeFlags(rt.getProvider("openrouter")!, all);
		const haiku = wrapped.getModels().find((m) => m.id === "anthropic/claude-haiku-5.5") as { api: string; compat?: { supportsMidConvoSystemMessages?: boolean } };
		expect(haiku.api).toBe("anthropic-messages");
		expect(haiku.compat?.supportsMidConvoSystemMessages).toBe(true);
	});
});
