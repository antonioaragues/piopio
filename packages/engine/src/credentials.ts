/**
 * pi's credential store, backed by the app's Keychain (docs/spec/10-model-providers §10). One item per provider,
 * `provider.<id>.credential`, holds its credential as JSON. OpenRouter's API key stays in its original item
 * (`provider.openrouter.apiKey`, the bare key) so existing setups keep working without signing in again.
 * A small non-secret index (`credentials.json`: provider → credential type) answers `list()` and tells which
 * providers to ask the Keychain about, so availability checks never touch it for providers you haven't connected.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { SECRET_OPENROUTER } from "@piopio/protocol";
import type { SecretBroker } from "./secrets.js";

export const credentialSecret = (providerId: string) => `provider.${providerId}.credential`;

export class KeychainCredentialStore implements CredentialStore {
	private readonly cache = new Map<string, Credential>();
	private readonly locks = new Map<string, Promise<unknown>>();
	private index: Record<string, Credential["type"]>;

	constructor(
		private readonly secrets: SecretBroker,
		private readonly indexPath?: string,
	) {
		this.index = {};
		if (indexPath && existsSync(indexPath)) {
			try {
				this.index = JSON.parse(readFileSync(indexPath, "utf8")) as Record<string, Credential["type"]>;
			} catch {
				// a damaged index only loses the list; the Keychain items stay
			}
		}
	}

	async read(providerId: string): Promise<Credential | undefined> {
		const cached = this.cache.get(providerId);
		if (cached) return cached;
		if (providerId === "openrouter" && this.index.openrouter !== "oauth") {
			const key = await this.secrets.get(SECRET_OPENROUTER, "Model requests to OpenRouter");
			if (!key) return undefined;
			const credential: Credential = { type: "api_key", key };
			this.cache.set(providerId, credential);
			this.remember(providerId, "api_key");
			return credential;
		}
		if (!this.index[providerId]) return undefined;
		const raw = await this.secrets.get(credentialSecret(providerId), `Model requests to ${providerId}`);
		if (!raw) return undefined;
		try {
			const credential = JSON.parse(raw) as Credential;
			this.cache.set(providerId, credential);
			return credential;
		} catch {
			return undefined;
		}
	}

	async list(): Promise<readonly CredentialInfo[]> {
		// The original OpenRouter key isn't in the index until first read.
		if (!this.index.openrouter) await this.read("openrouter").catch(() => undefined);
		return Object.entries(this.index).map(([providerId, type]) => ({ providerId, type }));
	}

	/** Whether a credential is stored for the provider, without reading the Keychain beyond OpenRouter's key. */
	async has(providerId: string): Promise<boolean> {
		if (this.cache.has(providerId)) return true;
		if (providerId === "openrouter") return Boolean(await this.read(providerId).catch(() => undefined));
		return Boolean(this.index[providerId]);
	}

	modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>): Promise<Credential | undefined> {
		return this.serialize(providerId, async () => {
			const current = await this.read(providerId);
			const next = await fn(current);
			if (next === undefined) return current;
			await this.write(providerId, next);
			return next;
		});
	}

	delete(providerId: string): Promise<void> {
		return this.serialize(providerId, async () => {
			this.cache.delete(providerId);
			delete this.index[providerId];
			this.save();
			await this.secrets.delete(credentialSecret(providerId));
			if (providerId === "openrouter") await this.secrets.delete(SECRET_OPENROUTER);
		});
	}

	/** Drops cached copies (the app changed a secret itself). */
	forget(providerId?: string): void {
		if (providerId) this.cache.delete(providerId);
		else this.cache.clear();
	}

	private async write(providerId: string, credential: Credential): Promise<void> {
		this.cache.set(providerId, credential);
		this.remember(providerId, credential.type);
		if (providerId === "openrouter" && credential.type === "api_key" && credential.key && !credential.env) {
			await this.secrets.set(SECRET_OPENROUTER, credential.key);
		} else {
			await this.secrets.set(credentialSecret(providerId), JSON.stringify(credential));
		}
	}

	private remember(providerId: string, type: Credential["type"]): void {
		if (this.index[providerId] === type) return;
		this.index[providerId] = type;
		this.save();
	}

	private save(): void {
		if (this.indexPath) writeFileSync(this.indexPath, `${JSON.stringify(this.index, null, "\t")}\n`, { mode: 0o600 });
	}

	/** One operation at a time per provider (pi refreshes OAuth tokens inside `modify`). */
	private serialize<T>(providerId: string, run: () => Promise<T>): Promise<T> {
		const previous = this.locks.get(providerId) ?? Promise.resolve();
		const next = previous.catch(() => undefined).then(run);
		this.locks.set(providerId, next);
		return next;
	}
}
