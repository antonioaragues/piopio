/**
 * One flag pi's catalog lacks for Claude through OpenRouter (docs/spec/38 §8 R2).
 *
 * A Claude model OpenRouter serves through the Anthropic Messages API takes system messages in the middle of a
 * conversation, and the cache holds across them (checked with real requests, test/openrouter-midconvo.test.ts). pi's
 * catalog for Anthropic's own API says so (`supportsMidConvoSystemMessages`); its OpenRouter entries don't, so pi
 * folded every prompt change into a new leading prompt. This gives each such model the flag its Anthropic entry has.
 *
 * It wraps pi's provider and changes nothing else: the models, their prices and their other flags are pi's (its
 * catalog, and the newer one it fetches from pi.dev). Goes away once pi's OpenRouter catalog carries the flag.
 */
import type { Api, Model, Provider } from "@earendil-works/pi-ai";

/** pi's OpenRouter provider with the flag added; `anthropic` is pi's catalog for Anthropic's own API. */
export function withClaudeFlags(base: Provider, anthropic: readonly Model<Api>[]): Provider {
	const { getAllModels, ...rest } = base;
	const midConvo = new Set(anthropic.filter((m) => (m.compat as { supportsMidConvoSystemMessages?: boolean } | undefined)?.supportsMidConvoSystemMessages).map((m) => m.id));
	if (!midConvo.size) return base;
	const patch = <M extends { id: string }>(models: readonly M[]): M[] => models.map((m) => withMidConvo(m, midConvo));
	return {
		...rest,
		getModels: () => patch(base.getModels()),
		...(getAllModels ? { getAllModels: () => patch(getAllModels.call(base)) } : {}),
	} as Provider;
}

/** "anthropic/claude-haiku-5.5" is Anthropic's "claude-haiku-5-5". */
export function anthropicId(openrouterId: string): string | undefined {
	return openrouterId.startsWith("anthropic/") ? openrouterId.slice("anthropic/".length).replaceAll(".", "-") : undefined;
}

/** A Claude chat model on the Anthropic Messages API, with the flag its Anthropic entry has; anything else as it is. */
function withMidConvo<M extends { id: string }>(model: M, midConvo: ReadonlySet<string>): M {
	const id = anthropicId(model.id);
	const { api, compat } = model as { api?: unknown; compat?: Record<string, unknown> };
	if (api !== "anthropic-messages" || !id || !midConvo.has(id) || compat?.supportsMidConvoSystemMessages !== undefined) return model;
	return { ...model, compat: { ...compat, supportsMidConvoSystemMessages: true } };
}
