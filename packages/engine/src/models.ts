/**
 * Model access shared by every runtime: one credential store (filled on demand from the
 * client's Keychain via `secrets.get`), a pi-ai Models collection for pi-durable, and a
 * lazily created ModelRuntime for pi-coding-agent.
 */
import { createModels, fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall, InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SECRET_OPENROUTER, type ModelInfo, type ModelRef } from "@piopio/protocol";
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

	/** Chat models of the configured providers (OpenRouter's catalog; the faux model in dev). */
	async listModels(refresh = false): Promise<ModelInfo[]> {
		if (refresh) await this.models.refresh({ providers: ["openrouter"] }).catch(() => undefined);
		const providers = this.faux ? ["faux", "openrouter"] : ["openrouter"];
		return providers.flatMap((provider) =>
			this.models.getModels(provider).map((m) => ({
				provider,
				id: m.id,
				name: m.name,
				contextWindow: m.contextWindow,
				maxOutputTokens: m.maxTokens,
				pricing: { input: m.cost.input, output: m.cost.output, cacheRead: m.cost.cacheRead, cacheWrite: m.cost.cacheWrite },
				supports: { vision: m.input.includes("image"), reasoning: m.reasoning },
			})),
		);
	}

	/**
	 * One-off request to the utility model (commit messages, titles): cheap and fast.
	 * `PIOPIO_UTILITY_MODEL` picks another OpenRouter model. Returns undefined with the scripted model.
	 */
	async utility(systemPrompt: string, prompt: string): Promise<string | undefined> {
		if (this.faux) return undefined;
		const ref: ModelRef = process.env.PIOPIO_UTILITY_MODEL ? { provider: "openrouter", id: process.env.PIOPIO_UTILITY_MODEL } : DEFAULT_MODEL;
		await this.ensureCredential(ref.provider);
		const model = this.models.getModel(ref.provider, ref.id);
		if (!model) throw new EngineError("INVALID", `Unknown utility model ${ref.provider}/${ref.id}`);
		const reply = await this.models.completeSimple(model, { systemPrompt, messages: [{ role: "user", content: prompt, timestamp: Date.now() }] });
		if (reply.stopReason === "error" || reply.stopReason === "aborted") throw new EngineError("MODEL_ERROR", reply.errorMessage ?? "The utility model failed.");
		return reply.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("").trim();
	}

	/** Drops cached credentials after the client changed a secret. */
	async forgetSecret(name: string): Promise<void> {
		this.secrets.forget(name);
		for (const [provider, secret] of Object.entries(SECRET_BY_PROVIDER)) {
			if (secret === name) await this.credentials.delete(provider);
		}
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

/**
 * Faux model that answers "Echo: <last user text>" forever (dev and tests). Lines of the message can
 * script tool calls first, one per step, for Build demos:
 *   $ <command>                      bash
 *   read: <path>                     read
 *   write: <path> | <content>        write (\n in content for new lines)
 *   edit: <path> | <old> | <new>     edit
 *   ask: <question> | <option>…      ask_user
 */
function installEcho(faux: FauxHandle): void {
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		faux.appendResponses([step]);
		const lastUser = context.messages.map((m) => m.role).lastIndexOf("user");
		const last = context.messages[lastUser];
		const text = typeof last?.content === "string" ? last.content : Array.isArray(last?.content) ? (last.content as { type: string; text?: string }[]).map((b) => b.text ?? "").join("") : "";
		const script = scriptedTools(text);
		const done = context.messages.slice(lastUser + 1).filter((m) => m.role === "toolResult").length;
		const next = script[done];
		if (next) return fauxAssistantMessage([fauxToolCall(next.name, next.args as Parameters<typeof fauxToolCall>[1])], { stopReason: "toolUse" });
		return fauxAssistantMessage([fauxText(`Echo: ${text}`)]);
	};
	faux.setResponses([step]);
}

function scriptedTools(text: string): { name: string; args: Record<string, unknown> }[] {
	const calls: { name: string; args: Record<string, unknown> }[] = [];
	for (const line of text.split("\n").map((l) => l.trim())) {
		const parts = (rest: string) => rest.split("|").map((p) => p.trim().replaceAll("\\n", "\n"));
		if (line.startsWith("$ ")) calls.push({ name: "bash", args: { command: line.slice(2) } });
		else if (line.startsWith("read: ")) calls.push({ name: "read", args: { path: line.slice(6).trim() } });
		else if (line.startsWith("write: ")) {
			const [path, content = ""] = parts(line.slice(7));
			calls.push({ name: "write", args: { path, content } });
		} else if (line.startsWith("ask: ")) {
			const [question, ...options] = parts(line.slice(5));
			calls.push({ name: "ask_user", args: { question, ...(options.length ? { options } : {}) } });
		} else if (line.startsWith("edit: ")) {
			const [path, oldText = "", newText = ""] = parts(line.slice(6));
			calls.push({ name: "edit", args: { path, edits: [{ oldText, newText }] } });
		}
	}
	return calls;
}

export class EngineError extends Error {
	constructor(
		readonly code: "NOT_FOUND" | "BUSY" | "AUTH" | "INVALID" | "CONFLICT" | "MODEL_ERROR" | "INTERNAL" | "ENGINE_UNAVAILABLE",
		message: string,
	) {
		super(message);
	}
}

/** Checks an OpenRouter key against GET /api/v1/key (no completion, no cost). */
export async function verifyProviderKey(provider: string, key: string, fetchImpl: typeof fetch = fetch): Promise<{ ok: boolean; message?: string; label?: string; usageUsd?: number; limitUsd?: number | null }> {
	if (provider !== "openrouter") return { ok: false, message: `${provider} keys can't be checked yet.` };
	if (!key.trim()) return { ok: false, message: "Paste a key first." };
	try {
		const response = await fetchImpl("https://openrouter.ai/api/v1/key", { headers: { authorization: `Bearer ${key.trim()}` }, signal: AbortSignal.timeout(15_000) });
		if (response.status === 401 || response.status === 403) return { ok: false, message: "OpenRouter didn't accept this key." };
		if (!response.ok) return { ok: false, message: `OpenRouter answered ${response.status}. Try again in a moment.` };
		const data = ((await response.json()) as { data?: { label?: string; usage?: number; limit?: number | null } }).data ?? {};
		return { ok: true, ...(data.label ? { label: data.label } : {}), ...(typeof data.usage === "number" ? { usageUsd: data.usage } : {}), limitUsd: data.limit ?? null };
	} catch {
		return { ok: false, message: "Can't reach OpenRouter. Check your connection." };
	}
}
