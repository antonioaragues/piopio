/**
 * Model providers on top of pi's ModelRuntime (docs/spec/10-model-providers): which ones Piopio offers, how
 * each is connected and who bills for it, the OpenAI API alias, and sign-in flows driven from the app.
 */
import { randomUUID } from "node:crypto";
import type { AuthInteraction, AuthPrompt, Provider } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { ProviderAuthEvent, ProviderInfo } from "@piopio/protocol";

/**
 * OpenAI's API key as a provider of its own. pi keeps one credential per provider and `openai` takes either
 * ChatGPT sign-in or an API key, so the API key lives here and both can be connected at once.
 */
export const OPENAI_API = "openai-api";

export function openaiApiAlias(base: Provider): Provider {
	const remap = <T extends { provider: string }>(model: T): T => ({ ...model, provider: OPENAI_API });
	const { filterModels: _filter, filterAllModels: _filterAll, getAllModels, ...rest } = base;
	return {
		...rest,
		id: OPENAI_API,
		name: "OpenAI API",
		auth: { apiKey: { ...base.auth.apiKey!, name: "OpenAI API key" } },
		getModels: () => base.getModels().map(remap),
		...(getAllModels ? { getAllModels: () => getAllModels.call(base).map(remap) } : {}),
	} as Provider;
}

/** Shown first in Settings › Models, in this order. */
export const FEATURED = ["openrouter", "openai", OPENAI_API];

/** How a provider can be connected in Piopio: ChatGPT only by sign-in on `openai` (its key goes to the alias). */
export function connectMethods(provider: Provider): ProviderInfo["methods"] {
	const methods: ProviderInfo["methods"] = [];
	const { apiKey, oauth } = provider.auth;
	if (apiKey?.login && provider.id !== "openai") methods.push({ type: "api_key", label: apiKey.name });
	if (oauth && provider.id !== "openrouter") methods.push({ type: "oauth", label: oauth.loginLabel ?? oauth.name, ...(oauth.isSubscription ? { subscription: true } : {}) });
	return methods;
}

const SUBSCRIPTIONS: Record<string, string> = {
	openai: "ChatGPT subscription",
	"openai-codex": "ChatGPT subscription",
	anthropic: "Claude subscription",
	"github-copilot": "Copilot subscription",
	xai: "Grok subscription",
	"kimi-coding": "Kimi subscription",
	meta: "Muse subscription",
};

/** Who bills for requests through a provider connected this way (FR2: the billing route is explicit). */
export function billingLabel(provider: Provider, type: "api_key" | "oauth"): string {
	if (type === "oauth") return provider.auth.oauth?.isSubscription ? (SUBSCRIPTIONS[provider.id] ?? `${provider.name} subscription`) : `${provider.name} account`;
	if (provider.id === "openrouter") return "OpenRouter credits";
	if (provider.id === OPENAI_API) return "OpenAI API billing";
	return `${provider.name} API billing`;
}

/** The model new chats use when a provider is the only one connected; else its first model. */
export const PREFERRED_MODEL: Record<string, string> = {
	openrouter: "anthropic/claude-haiku-5.5",
	openai: "gpt-6-sol",
	[OPENAI_API]: "gpt-6-sol",
	anthropic: "claude-sonnet-5-5",
};

/** A cheap, fast model for titles and commit messages. */
export const UTILITY_MODEL: Record<string, string> = {
	openrouter: "anthropic/claude-haiku-5.5",
	openai: "gpt-5.4-nano",
	[OPENAI_API]: "gpt-5.4-nano",
	anthropic: "claude-haiku-5-5",
};

type Emit = (loginId: string, provider: string, event: ProviderAuthEvent) => void;

type Flow = {
	provider: string;
	abort: AbortController;
	prompts: Map<string, { resolve: (value: string) => void; reject: (error: Error) => void }>;
};

/** Sign-ins in progress: pi runs the flow, the app shows its steps and answers its prompts. */
export class LoginFlows {
	private readonly flows = new Map<string, Flow>();

	constructor(
		private readonly runtime: () => ModelRuntime,
		private readonly emit: Emit,
		private readonly options: { agentName: string; deviceId: () => string; finished: (provider: string, ok: boolean) => void },
	) {}

	connecting(provider: string): boolean {
		return [...this.flows.values()].some((f) => f.provider === provider);
	}

	start(provider: string, method: "api_key" | "oauth"): string {
		const loginId = randomUUID();
		const flow: Flow = { provider, abort: new AbortController(), prompts: new Map() };
		this.flows.set(loginId, flow);
		const interaction: AuthInteraction = {
			signal: flow.abort.signal,
			prompt: (prompt) => this.prompt(loginId, flow, prompt),
			notify: (event) => {
				if (event.type === "device_code") {
					this.emit(loginId, provider, { type: "device_code", userCode: event.userCode, verificationUri: event.verificationUri, ...(event.expiresInSeconds ? { expiresInSeconds: event.expiresInSeconds } : {}) });
				} else if (event.type === "auth_url") {
					this.emit(loginId, provider, { type: "auth_url", url: event.url, ...(event.instructions ? { instructions: event.instructions } : {}) });
				} else if (event.type === "info") {
					this.emit(loginId, provider, { type: "info", message: event.message, ...(event.links ? { links: event.links.map((l) => ({ url: l.url, ...(l.label ? { label: l.label } : {}) })) } : {}) });
				} else {
					this.emit(loginId, provider, { type: "progress", message: event.message });
				}
			},
		};
		void this.runtime()
			.login(provider, method, interaction, { agentName: this.options.agentName, getDeviceId: this.options.deviceId })
			.then(
				() => {
					this.emit(loginId, provider, { type: "done" });
					this.options.finished(provider, true);
				},
				(error: unknown) => {
					const message = flow.abort.signal.aborted ? "Cancelled." : error instanceof Error ? error.message : String(error);
					this.emit(loginId, provider, { type: "failed", message });
					this.options.finished(provider, false);
				},
			)
			.finally(() => this.flows.delete(loginId));
		return loginId;
	}

	answer(loginId: string, promptId: string, value: string | undefined): void {
		const pending = this.flows.get(loginId)?.prompts.get(promptId);
		if (!pending) return;
		if (value === undefined) pending.reject(new Error("Cancelled."));
		else pending.resolve(value);
	}

	cancel(loginId: string): void {
		const flow = this.flows.get(loginId);
		if (!flow) return;
		for (const p of flow.prompts.values()) p.reject(new Error("Cancelled."));
		flow.abort.abort();
	}

	private prompt(loginId: string, flow: Flow, prompt: AuthPrompt): Promise<string> {
		const promptId = randomUUID();
		return new Promise<string>((resolve, reject) => {
			const done = () => {
				flow.prompts.delete(promptId);
				prompt.signal?.removeEventListener("abort", closed);
			};
			const closed = () => {
				done();
				this.emit(loginId, flow.provider, { type: "prompt_closed", promptId });
				reject(new Error("Prompt closed."));
			};
			flow.prompts.set(promptId, {
				resolve: (value) => (done(), resolve(value)),
				reject: (error) => (done(), reject(error)),
			});
			prompt.signal?.addEventListener("abort", closed, { once: true });
			this.emit(loginId, flow.provider, {
				type: "prompt",
				promptId,
				kind: prompt.type,
				message: prompt.message,
				...("placeholder" in prompt && prompt.placeholder ? { placeholder: prompt.placeholder } : {}),
				...(prompt.type === "select" ? { options: prompt.options.map((o) => ({ id: o.id, label: o.label, ...(o.description ? { description: o.description } : {}) })) } : {}),
			});
		});
	}
}
