/**
 * Models for the cloud engine: OpenRouter through pi-ai (key from the `OPENROUTER_API_KEY` secret),
 * or pi-ai's faux provider when `PIOPIO_FAUX_MODEL` is set (local dev and tests, no key needed).
 */
import { createModels, fauxAssistantMessage, fauxProvider, fauxText, InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import type { ModelRef } from "@piopio/protocol";
import type { Env } from "./env.js";

export const DEFAULT_MODEL: ModelRef = { provider: "openrouter", id: "anthropic/claude-haiku-5.5" };

export const FAUX_MODEL: ModelRef = { provider: "faux", id: "echo" };

/** The model new sessions start with. Synchronous, because PiHarness takes it before pi opens. */
export function defaultModel(env: Env): ModelRef {
	if (env.PIOPIO_FAUX_MODEL) return FAUX_MODEL;
	return env.PIOPIO_DEFAULT_MODEL ? parseModel(env.PIOPIO_DEFAULT_MODEL) : DEFAULT_MODEL;
}

export async function createCloudModels(env: Env): Promise<ReturnType<typeof createModels>> {
	const credentials = new InMemoryCredentialStore();
	const models = createModels({ credentials });
	models.setProvider(openrouterProvider());
	if (env.OPENROUTER_API_KEY) await credentials.modify("openrouter", async () => ({ type: "api_key", key: env.OPENROUTER_API_KEY! }));
	if (env.PIOPIO_FAUX_MODEL) {
		const tokensPerSecond = Number(env.PIOPIO_FAUX_TPS ?? "40");
		const faux = fauxProvider({ provider: FAUX_MODEL.provider, models: [{ id: FAUX_MODEL.id }], tokensPerSecond, tokenSize: { min: 4, max: 4 } });
		installEcho(faux);
		models.setProvider(faux.provider);
	}
	return models;
}

/** `provider/model-id` (the model id may itself contain slashes). */
function parseModel(value: string): ModelRef {
	const slash = value.indexOf("/");
	return { provider: value.slice(0, slash), id: value.slice(slash + 1) };
}

/** Faux model that answers "Echo: <last user text>" forever, as in packages/engine. */
function installEcho(faux: ReturnType<typeof fauxProvider>): void {
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		faux.appendResponses([step]);
		const last = [...context.messages].reverse().find((m) => m.role === "user");
		const text = typeof last?.content === "string" ? last.content : Array.isArray(last?.content) ? (last.content as { type: string; text?: string }[]).map((b) => b.text ?? "").join("") : "";
		return fauxAssistantMessage([fauxText(`Echo: ${text}`)]);
	};
	faux.setResponses([step]);
}
