/**
 * Model access shared by every runtime: one credential store (filled on demand from the
 * client's Keychain via `secrets.get`), a pi-ai Models collection for pi-durable, and a
 * lazily created ModelRuntime for pi-coding-agent.
 */
import { createModels, fauxAssistantMessage, fauxProvider, fauxText, InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SECRET_OPENROUTER, type ModelRef } from "@piopio/protocol";
import type { SecretBroker } from "./secrets.js";

export const DEFAULT_MODEL: ModelRef = { provider: "openrouter", id: "anthropic/claude-haiku-5.5" };

const SECRET_BY_PROVIDER: Record<string, string> = { openrouter: SECRET_OPENROUTER };

type FauxHandle = ReturnType<typeof fauxProvider>;

export class ModelHub {
	readonly credentials = new InMemoryCredentialStore();
	readonly models: ReturnType<typeof createModels>;
	readonly faux?: FauxHandle;
	readonly defaultModel: ModelRef;
	private runtime?: Promise<ModelRuntime>;

	constructor(
		private readonly secrets: SecretBroker,
		options: { faux?: boolean } = {},
	) {
		this.models = createModels({ credentials: this.credentials });
		this.models.setProvider(openrouterProvider());
		if (options.faux) {
			this.faux = fauxProvider({ provider: "faux", tokensPerSecond: 40 });
			installEcho(this.faux);
			this.models.setProvider(this.faux.provider);
			this.defaultModel = { provider: "faux", id: this.faux.getModel().id };
		} else {
			this.defaultModel = DEFAULT_MODEL;
		}
	}

	/** Makes sure the provider has a credential, asking the client for it the first time. */
	async ensureCredential(provider: string): Promise<void> {
		const secretName = SECRET_BY_PROVIDER[provider];
		if (!secretName) return; // faux and keyless providers
		if (await this.credentials.read(provider)) return;
		const key = await this.secrets.get(secretName, `Model requests to ${provider}`);
		if (!key) throw new EngineError("AUTH", `No API key for ${provider}. Add one in Settings › Models.`);
		await this.credentials.modify(provider, async () => ({ type: "api_key", key }));
	}

	/** ModelRuntime for pi-coding-agent sessions, sharing the same credentials. */
	buildRuntime(): Promise<ModelRuntime> {
		this.runtime ??= ModelRuntime.create({ credentials: this.credentials, modelsPath: null, refreshOnCreate: false }).then((rt) => {
			if (this.faux) rt.registerNativeProvider(this.faux.provider);
			return rt;
		});
		return this.runtime;
	}
}

/** Faux model that answers "Echo: <last user text>" forever (dev and tests). */
function installEcho(faux: FauxHandle): void {
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		faux.appendResponses([step]);
		const last = [...context.messages].reverse().find((m) => m.role === "user");
		const text = typeof last?.content === "string" ? last.content : Array.isArray(last?.content) ? (last.content as { type: string; text?: string }[]).map((b) => b.text ?? "").join("") : "";
		return fauxAssistantMessage([fauxText(`Echo: ${text}`)]);
	};
	faux.setResponses([step]);
}

export class EngineError extends Error {
	constructor(
		readonly code: "NOT_FOUND" | "BUSY" | "AUTH" | "INVALID" | "MODEL_ERROR" | "INTERNAL" | "ENGINE_UNAVAILABLE",
		message: string,
	) {
		super(message);
	}
}
